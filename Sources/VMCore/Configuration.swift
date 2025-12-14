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
        isoPath: String? = nil
    ) -> VMConfiguration {
        let now = Date()
        return VMConfiguration(
            name: name,
            cpuCount: cpuCount,
            memorySize: memorySize,
            diskImagePath: "disk.img",
            diskSize: diskSize,
            isoPath: isoPath,
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
        public let sudo: [String]
        public let shell: String
        public let sshAuthorizedKeys: [String]

        public init(name: String, sshAuthorizedKeys: [String] = []) {
            self.name = name
            self.sudo = ["ALL=(ALL) NOPASSWD:ALL"]
            self.shell = "/bin/bash"
            self.sshAuthorizedKeys = sshAuthorizedKeys
        }

        public enum CodingKeys: String, CodingKey {
            case name
            case sudo
            case shell
            case sshAuthorizedKeys = "ssh_authorized_keys"
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

    public let users: [User]
    public let hostname: String
    public let packageUpdate: Bool
    public let packageUpgrade: Bool
    public let packages: [String]
    public let runcmd: [String]
    public let writeFiles: [FileInfo]

    public init(
        users: [User],
        hostname: String,
        packageUpdate: Bool = false,
        packageUpgrade: Bool = false,
        packages: [String] = [],
        runcmd: [String] = [],
        writeFiles: [FileInfo] = []
    ) {
        self.users = users
        self.hostname = hostname
        self.packageUpdate = packageUpdate
        self.packageUpgrade = packageUpgrade
        self.packages = packages
        self.runcmd = runcmd
        self.writeFiles = writeFiles
    }

    public enum CodingKeys: String, CodingKey {
        case users
        case hostname
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
        sshKeys: [String] = []
    ) throws -> CloudInitConfiguration {
        let metadata = Metadata(localHostname: hostname, instanceID: instanceID)
        let homeDir = "/Users/\(username)"
        let userdata = CloudConfig(
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
}
