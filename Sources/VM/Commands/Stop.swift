import ArgumentParser
import Foundation
import VMCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop a running virtual machine",
        discussion: """
            Stops a running virtual machine by sending a shutdown signal.
            
            By default, a graceful shutdown is attempted via ACPI power button.
            Use --force to immediately terminate the VM process.
            
            Examples:
              vm stop ubuntu
              vm stop ubuntu --force
            """
    )
    
    @Argument(help: "Name of the virtual machine to stop")
    var name: String
    
    @Flag(name: .shortAndLong, help: "Force stop the VM immediately")
    var force: Bool = false
    
    mutating func run() async throws {
        let vmManager = Manager.shared
        
        // Check if VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }
        
        // Get running PID
        guard let pid = vmManager.getRunningPID(for: name) else {
            print("VM '\(name)' is not running.")
            return
        }
        
        if force {
            print("Force stopping VM '\(name)' (PID: \(pid))...")
            
            // Send SIGKILL
            if kill(pid, SIGKILL) == 0 {
                // Wait a moment for process to terminate
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                
                // Clean up PID file
                try? vmManager.clearRuntimeInfo(for: name)
                
                print("✓ VM '\(name)' force stopped.")
            } else {
                let errno_value = errno
                if errno_value == ESRCH {
                    // Process doesn't exist, clean up
                    try? vmManager.clearRuntimeInfo(for: name)
                    print("VM '\(name)' was not running (stale PID file cleaned up).")
                } else {
                    throw RunnerError.runtimeError("Failed to kill process: \(String(cString: strerror(errno_value)))")
                }
            }
        } else {
            print("Stopping VM '\(name)' (PID: \(pid))...")
            
            // Send SIGTERM for graceful shutdown
            if kill(pid, SIGTERM) == 0 {
                print("Sent shutdown signal. Waiting for VM to stop...")
                
                // Wait for process to terminate (with timeout)
                let timeout: UInt64 = 30 // seconds
                let startTime = Date()
                
                while Date().timeIntervalSince(startTime) < Double(timeout) {
                    // Check if process is still running
                    if kill(pid, 0) != 0 {
                        // Process terminated
                        try? vmManager.clearRuntimeInfo(for: name)
                        print("✓ VM '\(name)' stopped gracefully.")
                        return
                    }
                    
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                }
                
                // Timeout - suggest force stop
                print("VM did not stop within \(timeout) seconds.")
                print("Use 'vm stop \(name) --force' to force stop.")
            } else {
                let errno_value = errno
                if errno_value == ESRCH {
                    // Process doesn't exist, clean up
                    try? vmManager.clearRuntimeInfo(for: name)
                    print("VM '\(name)' was not running (stale PID file cleaned up).")
                } else {
                    throw RunnerError.runtimeError("Failed to send signal: \(String(cString: strerror(errno_value)))")
                }
            }
        }
    }
}

