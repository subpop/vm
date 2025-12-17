import ArgumentParser
import Foundation
import Synchronization
import VMCore

/// Thread-safe progress state for download tracking
private final class ProgressState: @unchecked Sendable {
    private let mutex = Mutex<State>(State())

    private struct State {
        var lastUpdateTime: Date = Date()
        var lastBytes: Int64 = 0
    }

    func update(downloaded: Int64, total: Int64?) {
        mutex.withLock { state in
            let now = Date()
            let elapsed = now.timeIntervalSince(state.lastUpdateTime)

            // Update progress every 0.5 seconds
            guard elapsed >= 0.5 else { return }

            let bytesPerSecond = Double(downloaded - state.lastBytes) / elapsed
            let downloadedMB = Double(downloaded) / 1024 / 1024

            if let total = total {
                let totalMB = Double(total) / 1024 / 1024
                let percent = (Double(downloaded) / Double(total)) * 100
                let remaining = Double(total - downloaded) / bytesPerSecond
                let eta =
                    remaining.isFinite && remaining > 0
                    ? Self.formatTimeStatic(remaining) : "--:--"

                print(
                    "\r  \(String(format: "%.1f", downloadedMB))/\(String(format: "%.1f", totalMB)) MB (\(String(format: "%.1f", percent))%) - \(Self.formatSpeedStatic(bytesPerSecond)) - ETA: \(eta)    ",
                    terminator: "")
            } else {
                print(
                    "\r  \(String(format: "%.1f", downloadedMB)) MB - \(Self.formatSpeedStatic(bytesPerSecond))    ",
                    terminator: "")
            }
            fflush(stdout)

            state.lastUpdateTime = now
            state.lastBytes = downloaded
        }
    }

    private static func formatSpeedStatic(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1024 / 1024)
        } else if bytesPerSecond >= 1024 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
    }

    private static func formatTimeStatic(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

struct Rescue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a VM into a rescue environment",
        discussion: """
            Boots a virtual machine into a Fedora Cloud rescue environment.

            The target VM's disk is attached as a secondary device (/dev/vdb) so you
            can perform recovery operations like filesystem repairs, password resets,
            or data recovery.

            On first run, a Fedora Cloud image is downloaded, converted to raw format,
            and set up as a permanent rescue VM (~500MB download, ~2GB disk).
            Subsequent runs reuse this rescue VM, preserving any tools you install.

            The rescue environment provides a Fedora system with network access for
            downloading additional tools if needed. Login: rescue/rescue or root/rescue

            Examples:
              vm rescue ubuntu
              vm rescue debian --force-download
            """
    )

    @Argument(help: "Name of the virtual machine to rescue")
    var name: String

    @Flag(name: .long, help: "Force re-download and setup of rescue VM")
    var forceDownload: Bool = false

    @Flag(name: .long, help: "Use existing rescue VM without checking for updates")
    var offline: Bool = false

    @MainActor
    mutating func run() async throws {
        let vmManager = Manager.shared
        let rescueCache = RescueCache(manager: vmManager)

        // Check if target VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }

        // Check if target VM is already running
        if vmManager.getRunningPID(for: name) != nil {
            throw RunnerError.configurationError(
                "VM '\(name)' is currently running. Stop it first with 'vm stop \(name)'")
        }

        // Check if rescue VM is already running
        if vmManager.isRescueVMRunning() {
            if let currentTarget = vmManager.getRescueTarget() {
                throw RunnerError.configurationError(
                    "Rescue VM is already running (rescuing '\(currentTarget)'). Stop it first.")
            } else {
                throw RunnerError.configurationError(
                    "Rescue VM is already running. Stop it first with 'vm stop \(Manager.rescueVMName)'"
                )
            }
        }

        // Ensure rescue VM is set up
        try await ensureRescueVM(
            cache: rescueCache,
            forceDownload: forceDownload,
            offline: offline
        )

        // Record which VM we're rescuing
        try vmManager.setRescueTarget(name)

        print("\nStarting rescue environment for VM '\(name)'...")
        print("Target disk will be available at /dev/vdb in the rescue system")
        print("Login: rescue/rescue or root/rescue")
        print("Press Ctrl-] to detach from console\n")

        // Spawn daemon and attach
        let targetDisk = vmManager.diskPath(for: name)
        try await spawnRescueDaemonAndAttach(
            targetDisk: targetDisk,
            manager: vmManager
        )
    }

    /// Ensures the rescue VM is set up and ready
    @MainActor
    private func ensureRescueVM(
        cache: RescueCache,
        forceDownload: Bool,
        offline: Bool
    ) async throws {
        let isReady = cache.isReady()

        // If force download, always re-setup
        if forceDownload {
            print("Setting up rescue VM (force download)...")
            let info = try await cache.fetchLatestImageInfo()
            try await setupRescueVM(cache: cache, info: info)
            return
        }

        // If offline mode, require existing rescue VM
        if offline {
            guard isReady else {
                throw RescueCacheError.fileSystemError(
                    "Rescue VM not set up. Run without --offline to download and configure.")
            }
            if let metadata = try? cache.loadCachedMetadata() {
                print("Using rescue VM (version \(metadata.version))")
            }
            return
        }

        // Check if rescue VM is ready
        if isReady {
            // Check for updates
            print("Checking for rescue image updates...")
            let (hasUpdate, latest) = try await cache.checkForUpdate()

            if hasUpdate {
                // Prompt user
                let cachedMeta = try cache.loadCachedMetadata()
                print(
                    "A newer rescue image is available: \(latest.version) (current: \(cachedMeta?.version ?? "unknown"))"
                )
                print("Would you like to update? [y/N] ", terminator: "")
                fflush(stdout)

                if let response = readLine()?.lowercased(), response == "y" || response == "yes" {
                    try await setupRescueVM(cache: cache, info: latest)
                } else {
                    print("Using current rescue VM")
                }
            } else {
                if let metadata = try? cache.loadCachedMetadata() {
                    print("Rescue VM is up to date (version \(metadata.version))")
                }
            }
        } else {
            // No rescue VM, must set it up
            print("Rescue VM not found. Setting up...")
            let info = try await cache.fetchLatestImageInfo()
            print("This is a one-time setup (~500MB download, ~2GB disk)\n")
            try await setupRescueVM(cache: cache, info: info)
        }
    }

    /// Downloads and sets up the rescue VM
    @MainActor
    private func setupRescueVM(cache: RescueCache, info: RescueImageInfo) async throws {
        let startTime = Date()
        let progressState = ProgressState()

        try await cache.downloadAndSetup(
            info,
            progressHandler: { downloaded, total in
                progressState.update(downloaded: downloaded, total: total)
            },
            statusHandler: { status in
                print("\n\(status)")
            }
        )

        let totalTime = Date().timeIntervalSince(startTime)
        print("✓ Rescue VM ready (setup took \(formatTime(totalTime)))")
    }

    /// Formats seconds as MM:SS or HH:MM:SS
    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// Spawns the rescue daemon and attaches to its console
    @MainActor
    private func spawnRescueDaemonAndAttach(
        targetDisk: URL,
        manager: Manager
    ) async throws {
        let terminal = TerminalController.shared

        // Check if we have a terminal
        guard terminal.isTerminal else {
            throw RunnerError.configurationError(
                "Rescue mode requires an interactive terminal")
        }

        let args = DaemonSpawnArgs(
            vmName: Manager.rescueVMName,
            rescueMode: true,
            targetDisk: targetDisk
        )

        let result = try await DaemonSpawner.spawnAndWaitForSocket(
            args: args,
            manager: manager,
            timeoutSeconds: 15,
            checkCrash: true
        )

        // Connect to the console
        try await DaemonSpawner.attachToConsole(
            vmName: Manager.rescueVMName,
            socketPath: result.socketPath,
            messageHandler: nil
        )

        // Gracefully stop the rescue VM after detaching
        await stopRescueVM(process: result.process, manager: manager)
    }

    /// Gracefully stops the rescue VM daemon after detaching from console
    @MainActor
    private func stopRescueVM(process: Process, manager: Manager) async {
        guard process.isRunning else {
            // Already stopped, just clean up
            try? manager.clearRuntimeInfo(for: Manager.rescueVMName)
            try? manager.clearRescueTarget()
            return
        }

        print("Stopping rescue environment...")

        await DaemonSpawner.stopDaemon(process: process, timeoutSeconds: 15)

        // Clean up
        try? manager.clearRuntimeInfo(for: Manager.rescueVMName)
        try? manager.clearRescueTarget()
        print("✓ Rescue environment stopped")
    }
}
