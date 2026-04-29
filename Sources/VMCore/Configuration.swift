import Foundation
import Yams

/// Represents the configuration and state of a virtual machine
public struct VMConfiguration: Codable, Sendable {
    /// Unique name identifier for the VM
    public var name: String

    /// Number of CPU cores allocated to the VM
    public var cpuCount: Int

    /// Memory size in bytes
    public var memorySize: UInt64

    /// Path to the main disk image (relative to VM directory)
    public var diskImagePath: String

    /// Size of the disk in bytes
    public var diskSize: UInt64

    /// Optional path to ISO for installation (relative or absolute)
    public var isoPath: String?

    /// Optional path to a cloud-init user-data file (relative or absolute)
    public var cloudInitUserDataPath: String?

    /// MAC address for the network interface
    public var macAddress: String

    /// Creation date
    public var createdAt: Date

    /// Last modified date
    public var modifiedAt: Date

    public enum CodingKeys: String, CodingKey {
        case name
        case cpuCount = "cpu_count"
        case memorySize = "memory_size"
        case diskImagePath = "disk_image_path"
        case diskSize = "disk_size"
        case isoPath = "iso_path"
        case cloudInitUserDataPath = "cloud_init_user_data_path"
        case macAddress = "mac_address"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }

    /// Creates a new VM configuration with default settings
    public static func create(
        name: String,
        cpuCount: Int = 2,
        memorySize: UInt64 = 4 * 1024 * 1024 * 1024,  // 4GB
        diskSize: UInt64 = 64 * 1024 * 1024 * 1024,  // 64GB
        isoPath: String? = nil,
        cloudInitUserDataPath: String? = nil
    ) -> VMConfiguration {
        let now = Date()
        return VMConfiguration(
            name: name,
            cpuCount: cpuCount,
            memorySize: memorySize,
            diskImagePath: "disk.img",
            diskSize: diskSize,
            isoPath: isoPath,
            cloudInitUserDataPath: cloudInitUserDataPath,
            macAddress: VMConfiguration.generateMACAddress(),
            createdAt: now,
            modifiedAt: now
        )
    }

    /// Generates a random MAC address with a locally administered prefix
    public static func generateMACAddress() -> String {
        // Use locally administered, unicast MAC address (second nibble is 2, 6, A, or E)
        var bytes = [UInt8](repeating: 0, count: 6)
        for i in 0..<6 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        // Set locally administered bit and clear multicast bit
        bytes[0] = (bytes[0] | 0x02) & 0xFE

        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// Represents the runtime state of a VM
public enum VMState: String, Codable, Sendable {
    case stopped
    case running
    case paused
}

/// Runtime information for a VM (stored in vm.pid file)
public struct VMRuntimeInfo: Codable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    public enum CodingKeys: String, CodingKey {
        case pid
        case startedAt = "started_at"
    }

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// Network information from guest agent (stored in network-info.json)
public struct VMNetworkInfo: Codable, Sendable {
    public var interfaces: [NetworkInterface]
    public var queriedAt: Date

    public struct NetworkInterface: Codable, Sendable {
        public let name: String
        public let hwaddr: String?
        public let ipAddresses: [IPAddress]?

        public struct IPAddress: Codable, Sendable {
            public let ipAddressType: String
            public let ipAddress: String
            public let prefix: Int?

            public enum CodingKeys: String, CodingKey {
                case ipAddressType = "ip-address-type"
                case ipAddress = "ip-address"
                case prefix
            }

            public init(ipAddressType: String, ipAddress: String, prefix: Int?) {
                self.ipAddressType = ipAddressType
                self.ipAddress = ipAddress
                self.prefix = prefix
            }
        }

        public enum CodingKeys: String, CodingKey {
            case name
            case hwaddr = "hardware-address"
            case ipAddresses = "ip-addresses"
        }

        public init(name: String, hwaddr: String?, ipAddresses: [IPAddress]?) {
            self.name = name
            self.hwaddr = hwaddr
            self.ipAddresses = ipAddresses
        }
    }

    public enum CodingKeys: String, CodingKey {
        case interfaces
        case queriedAt = "queried_at"
    }

    public init(interfaces: [NetworkInterface], queriedAt: Date) {
        self.interfaces = interfaces
        self.queriedAt = queriedAt
    }
}

public struct CloudConfig: Codable, Sendable {
    public struct User: Codable, Sendable {
        public let name: String
        public let groups: String?
        public let sudo: [String]
        public let shell: String
        public let sshAuthorizedKeys: [String]?
        public let lockPasswd: Bool?
        public let passwd: String?

        public init(
            name: String,
            groups: String? = nil,
            sshAuthorizedKeys: [String] = [],
            lockPasswd: Bool? = nil,
            passwd: String? = nil
        ) {
            self.name = name
            self.groups = groups
            self.sudo = ["ALL=(ALL) NOPASSWD:ALL"]
            self.shell = "/bin/bash"
            self.sshAuthorizedKeys = sshAuthorizedKeys.isEmpty ? nil : sshAuthorizedKeys
            self.lockPasswd = lockPasswd
            self.passwd = passwd
        }

        public enum CodingKeys: String, CodingKey {
            case name
            case groups
            case sudo
            case shell
            case sshAuthorizedKeys = "ssh_authorized_keys"
            case lockPasswd = "lock_passwd"
            case passwd
        }
    }

    public struct FileInfo: Codable, Sendable {
        public var encoding: String = "text/plain"
        public var content: String
        public var owner: String = "root:root"
        public var path: String
        public var permissions: String = "0o644"
        public var append: Bool = false
    }

    public struct Chpasswd: Codable, Sendable {
        public let expire: Bool
        public let users: [UserPassword]

        public struct UserPassword: Codable, Sendable {
            public let name: String
            public let password: String
            public let type: String

            public init(name: String, password: String, type: String = "text") {
                self.name = name
                self.password = password
                self.type = type
            }
        }

        public init(expire: Bool = false, users: [UserPassword]) {
            self.expire = expire
            self.users = users
        }
    }

    public let users: [User]
    public let hostname: String
    public let chpasswd: Chpasswd?
    public let sshPwauth: Bool?
    public let bootcmd: [String]?
    public let packageUpdate: Bool
    public let packageUpgrade: Bool
    public let packages: [String]
    public let runcmd: [String]
    public let writeFiles: [FileInfo]

    public init(
        users: [User],
        hostname: String,
        chpasswd: Chpasswd? = nil,
        sshPwauth: Bool? = nil,
        bootcmd: [String]? = nil,
        packageUpdate: Bool = false,
        packageUpgrade: Bool = false,
        packages: [String] = [],
        runcmd: [String] = [],
        writeFiles: [FileInfo] = []
    ) {
        self.users = users
        self.hostname = hostname
        self.chpasswd = chpasswd
        self.sshPwauth = sshPwauth
        self.bootcmd = bootcmd
        self.packageUpdate = packageUpdate
        self.packageUpgrade = packageUpgrade
        self.packages = packages
        self.runcmd = runcmd
        self.writeFiles = writeFiles
    }

    public enum CodingKeys: String, CodingKey {
        case users
        case hostname
        case chpasswd
        case sshPwauth = "ssh_pwauth"
        case bootcmd
        case packageUpdate = "package_update"
        case packageUpgrade = "package_upgrade"
        case packages
        case runcmd
        case writeFiles = "write_files"
    }
}

public struct Metadata: Codable, Sendable {
    public let localHostname: String
    public let instanceID: String

    public enum CodingKeys: String, CodingKey {
        case localHostname = "local-hostname"
        case instanceID = "instance-id"
    }

    public init(localHostname: String, instanceID: String) {
        self.localHostname = localHostname
        self.instanceID = instanceID
    }
}

/// Cloud-init configuration for automated VM provisioning.
public struct CloudInitConfiguration: Sendable, Codable, Equatable {
    /// User data as a YAML string.
    public var userData: String

    /// Instance metadata as a YAML string.
    public var metaData: String

    /// Network configuration (optional).
    public var networkConfig: String?

    /// Creates a new cloud-init configuration.
    ///
    /// - Parameters:
    ///   - userData: User data as a YAML string (cloud-config format).
    ///   - metaData: Instance metadata dictionary.
    ///   - networkConfig: Optional network configuration YAML.
    public init(
        userData: String,
        metaData: String = "",
        networkConfig: String? = nil
    ) {
        self.userData = userData
        self.metaData = metaData
        self.networkConfig = networkConfig
    }
}

/// Errors that can occur while merging user-supplied cloud-init user-data.
public enum CloudInitConfigurationError: LocalizedError, Sendable {
    case unsupportedKey(String)
    case invalidFragment(String)
    case primaryUserConflict(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedKey(let key):
            return "Unsupported cloud-init key in user-data: \(key)"
        case .invalidFragment(let message):
            return "Invalid cloud-init user-data: \(message)"
        case .primaryUserConflict(let username):
            return
                "Cloud-init user-data cannot redefine primary user '\(username)'; add different users only"
        }
    }
}

// MARK: - CloudInitConfiguration Factory Methods

extension CloudInitConfiguration {
    /// Creates a cloud-init configuration for basic VM setup with a user account.
    ///
    /// - Parameters:
    ///   - instanceId: The instance ID (should be unique per VM instance).
    ///   - hostname: The hostname to set.
    ///   - username: The username to create. Defaults to "ubuntu".
    ///   - sshKeys: SSH public keys to authorize for the user.
    /// - Returns: A configured CloudInitConfiguration instance.
    public static func basicSetup(
        instanceID: String,
        hostname: String,
        username: String = "ubuntu",
        sshKeys: [String] = []
    ) throws -> CloudInitConfiguration {
        let metadata = Metadata(localHostname: hostname, instanceID: instanceID)
        let userdata = CloudConfig(
            users: [CloudConfig.User(name: username, sshAuthorizedKeys: sshKeys)],
            hostname: hostname)

        return try createCloudInitConfiguration(metadata: metadata, userdata: userdata)
    }

    /// Creates a cloud-init configuration with custom packages and commands.
    ///
    /// - Parameters:
    ///   - instanceId: The instance ID (should be unique per VM instance).
    ///   - hostname: The hostname to set.
    ///   - sshKeys: SSH public keys to authorize.
    ///   - packages: Packages to install on first boot.
    ///   - runCommands: Commands to run on first boot.
    /// - Returns: A configured CloudInitConfiguration instance.
    public static func withPackagesAndCommands(
        instanceID: String,
        hostname: String,
        username: String,
        sshKeys: [String] = [],
        packages: [String] = [],
        runCommands: [String] = []
    ) throws -> CloudInitConfiguration {
        let metadata = Metadata(localHostname: hostname, instanceID: instanceID)
        let userdata = CloudConfig(
            users: [CloudConfig.User(name: username, sshAuthorizedKeys: sshKeys)],
            hostname: hostname, packageUpdate: !packages.isEmpty, packageUpgrade: !packages.isEmpty,
            packages: packages, runcmd: runCommands)

        return try createCloudInitConfiguration(metadata: metadata, userdata: userdata)
    }

    public static func withDefaultPackagesAndCommands(
        instanceID: String,
        hostname: String,
        username: String,
        sshKeys: [String] = [],
        userDataFragment: String? = nil
    ) throws -> CloudInitConfiguration {
        let metadata = Metadata(localHostname: hostname, instanceID: instanceID)
        let homeDir = "/Users/\(username)"
        let baseUserData = CloudConfig(
            users: [CloudConfig.User(name: username, sshAuthorizedKeys: sshKeys)],
            hostname: hostname,
            packages: ["qemu-guest-agent"],
            runcmd: [
                // Install SELinux policy tools and compile policy (only if SELinux is present)
                """
                if command -v semodule >/dev/null 2>&1 && [ -f /etc/selinux/qemu-vsock.te ]; then
                  if command -v dnf >/dev/null 2>&1; then dnf install -y checkpolicy 2>/dev/null || true
                  elif command -v yum >/dev/null 2>&1; then yum install -y checkpolicy 2>/dev/null || true
                  elif command -v apt-get >/dev/null 2>&1; then apt-get install -y checkpolicy 2>/dev/null || true
                  fi
                  if command -v checkmodule >/dev/null 2>&1; then
                    checkmodule -M -m -o /tmp/qemu-vsock.mod /etc/selinux/qemu-vsock.te && \
                    semodule_package -o /tmp/qemu-vsock.pp -m /tmp/qemu-vsock.mod && \
                    semodule -i /tmp/qemu-vsock.pp
                  fi
                fi
                """,
                // Enable and start guest agent
                """
                if command -v systemctl >/dev/null 2>&1; then
                  systemctl daemon-reload
                  systemctl enable --now qemu-guest-agent
                fi
                """,
                // Create mount point and mount host home directory
                "mkdir -p \(homeDir) && mount -a",
            ],
            writeFiles: [
                // SELinux policy to allow qemu-ga to use vsock (ignored on non-SELinux systems)
                CloudConfig.FileInfo(
                    content: """
                        module qemu-vsock 1.0;

                        require {
                                type virt_qemu_ga_t;
                                class vsock_socket { accept listen };
                        }

                        #============= virt_qemu_ga_t ==============
                        allow virt_qemu_ga_t self:vsock_socket { accept listen };
                        """,
                    path: "/etc/selinux/qemu-vsock.te"),
                // Custom systemd service for qemu-guest-agent with vsock
                CloudConfig.FileInfo(
                    content: """
                        [Unit]
                        Description=QEMU Guest Agent
                        IgnoreOnIsolate=True

                        [Service]
                        UMask=0077
                        EnvironmentFile=-/etc/sysconfig/qemu-ga
                        ExecStart=/usr/bin/qemu-ga \
                          --method=vsock-listen \
                          --path=3:9001
                        Restart=always
                        RestartSec=0

                        [Install]
                        WantedBy=multi-user.target
                        """,
                    path: "/etc/systemd/system/qemu-guest-agent.service"),
                // fstab entry to mount host home directory via virtiofs
                CloudConfig.FileInfo(
                    content: "hostHome \(homeDir) virtiofs rw,nofail 0 0\n",
                    path: "/etc/fstab",
                    append: true),
            ])

        let mergedUserData = try mergeUserDataFragmentIfProvided(
            base: baseUserData,
            fragmentYAML: userDataFragment
        )

        return try createCloudInitConfiguration(metadata: metadata, userdata: mergedUserData)
    }

    /// Creates a cloud-init configuration for rescue VM setup.
    /// Configures auto-login on serial console and creates rescue user with password.
    ///
    /// - Returns: A configured CloudInitConfiguration instance for rescue mode.
    public static func rescueSetup() throws -> CloudInitConfiguration {
        let metadata = Metadata(localHostname: "rescue", instanceID: "rescue-vm")

        let userdata = CloudConfig(
            users: [
                CloudConfig.User(
                    name: "rescue",
                    groups: "wheel",
                    lockPasswd: false,
                    passwd: "rescue"
                )
            ],
            hostname: "rescue",
            chpasswd: CloudConfig.Chpasswd(
                expire: false,
                users: [
                    CloudConfig.Chpasswd.UserPassword(name: "root", password: "rescue")
                ]
            ),
            sshPwauth: true,
            bootcmd: [
                "mkdir -p /etc/systemd/system/serial-getty@hvc0.service.d"
            ],
            runcmd: [
                "systemctl daemon-reload",
                "systemctl enable serial-getty@hvc0.service",
                "systemctl restart serial-getty@hvc0.service",
                "touch /etc/cloud/cloud-init.disabled",
            ],
            writeFiles: [
                CloudConfig.FileInfo(
                    content: """
                        [Service]
                        ExecStart=
                        ExecStart=-/sbin/agetty --autologin rescue --noclear %I $TERM
                        """,
                    path: "/etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf",
                    permissions: "0644"),
                CloudConfig.FileInfo(
                    content: """

                        ========================================
                        VM Rescue Environment (Fedora Cloud)
                        ========================================

                        Target disk is available at /dev/vdb

                        Useful commands:
                          lsblk                    - List block devices
                          mount /dev/vdb1 /mnt     - Mount a partition
                          fsck /dev/vdb1           - Check filesystem
                          fdisk -l /dev/vdb        - List partitions

                        Login: rescue / rescue (or root / rescue)
                        Press Ctrl-] to detach from console.
                        ========================================

                        """,
                    path: "/etc/motd",
                    permissions: "0644"),
            ])

        return try createCloudInitConfiguration(metadata: metadata, userdata: userdata)
    }

    private static func createCloudInitConfiguration(metadata: Metadata, userdata: CloudConfig)
        throws -> CloudInitConfiguration
    {
        let encoder = YAMLEncoder()
        return CloudInitConfiguration(
            userData: "#cloud-config\n\(try encoder.encode(userdata))",
            metaData: try encoder.encode(metadata))
    }

    private static let supportedFragmentKeys: Set<String> = [
        "users",
        "bootcmd",
        "packages",
        "runcmd",
        "write_files",
    ]

    private struct CloudConfigFragment: Decodable {
        struct FragmentUser: Decodable {
            let name: String
            let groups: String?
            let sshAuthorizedKeys: [String]?
            let lockPasswd: Bool?
            let passwd: String?

            enum CodingKeys: String, CodingKey {
                case name
                case groups
                case sshAuthorizedKeys = "ssh_authorized_keys"
                case lockPasswd = "lock_passwd"
                case passwd
            }

            var asCloudConfigUser: CloudConfig.User {
                CloudConfig.User(
                    name: name,
                    groups: groups,
                    sshAuthorizedKeys: sshAuthorizedKeys ?? [],
                    lockPasswd: lockPasswd,
                    passwd: passwd
                )
            }
        }

        struct FragmentFileInfo: Decodable {
            let encoding: String?
            let content: String
            let owner: String?
            let path: String
            let permissions: String?
            let append: Bool?

            enum CodingKeys: String, CodingKey {
                case encoding
                case content
                case owner
                case path
                case permissions
                case append
            }

            var asCloudConfigFileInfo: CloudConfig.FileInfo {
                var fileInfo = CloudConfig.FileInfo(content: content, path: path)
                if let encoding {
                    fileInfo.encoding = encoding
                }
                if let owner {
                    fileInfo.owner = owner
                }
                if let permissions {
                    fileInfo.permissions = permissions
                }
                if let append {
                    fileInfo.append = append
                }
                return fileInfo
            }
        }

        let users: [FragmentUser]?
        let bootcmd: [String]?
        let packages: [String]?
        let runcmd: [String]?
        let writeFiles: [FragmentFileInfo]?

        enum CodingKeys: String, CodingKey {
            case users
            case bootcmd
            case packages
            case runcmd
            case writeFiles = "write_files"
        }
    }

    private static func mergeUserDataFragmentIfProvided(base: CloudConfig, fragmentYAML: String?)
        throws -> CloudConfig
    {
        guard let fragmentYAML,
            !fragmentYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return base
        }

        let normalizedFragment = stripCloudConfigHeader(from: fragmentYAML)
        try validateFragmentKeys(in: normalizedFragment)

        let decoder = YAMLDecoder()
        let fragment: CloudConfigFragment
        do {
            fragment = try decoder.decode(CloudConfigFragment.self, from: normalizedFragment)
        } catch {
            throw CloudInitConfigurationError.invalidFragment(error.localizedDescription)
        }

        let primaryUser = base.users.first?.name
        if let primaryUser,
            let fragmentUsers = fragment.users,
            fragmentUsers.contains(where: { $0.name == primaryUser })
        {
            throw CloudInitConfigurationError.primaryUserConflict(primaryUser)
        }

        let mergedUsers = base.users + (fragment.users?.map(\.asCloudConfigUser) ?? [])
        let mergedWriteFiles =
            base.writeFiles + (fragment.writeFiles?.map(\.asCloudConfigFileInfo) ?? [])

        return CloudConfig(
            users: mergedUsers,
            hostname: base.hostname,
            chpasswd: base.chpasswd,
            sshPwauth: base.sshPwauth,
            bootcmd: mergeOptionalArrays(base.bootcmd, fragment.bootcmd),
            packageUpdate: base.packageUpdate,
            packageUpgrade: base.packageUpgrade,
            packages: base.packages + (fragment.packages ?? []),
            runcmd: base.runcmd + (fragment.runcmd ?? []),
            writeFiles: mergedWriteFiles
        )
    }

    private static func validateFragmentKeys(in yaml: String) throws {
        guard let raw = try Yams.load(yaml: yaml) else {
            return
        }
        guard let dictionary = raw as? [String: Any] else {
            throw CloudInitConfigurationError.invalidFragment(
                "user-data must be a YAML mapping (cloud-config object)"
            )
        }

        for key in dictionary.keys where !supportedFragmentKeys.contains(key) {
            throw CloudInitConfigurationError.unsupportedKey(key)
        }
    }

    private static func stripCloudConfigHeader(from yaml: String) -> String {
        var lines = yaml.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "#cloud-config" {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private static func mergeOptionalArrays<T>(_ base: [T]?, _ extra: [T]?) -> [T]? {
        switch (base, extra) {
        case (nil, nil):
            return nil
        case (let lhs?, nil):
            return lhs
        case (nil, let rhs?):
            return rhs
        case (let lhs?, let rhs?):
            return lhs + rhs
        }
    }
}
