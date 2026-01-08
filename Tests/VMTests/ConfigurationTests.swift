import Foundation
import Testing
import Yams

@testable import VMCore

@Suite("CloudInitConfiguration Tests")
struct CloudInitConfigurationTests {

    @Test("basicSetup creates valid cloud-config with user and metadata")
    func basicSetupEncodesCorrectly() throws {
        let config = try CloudInitConfiguration.basicSetup(
            instanceID: "test-instance-123",
            hostname: "test-host",
            username: "testuser",
            sshKeys: ["ssh-rsa AAAAB3... user@host"]
        )

        // Verify userData has #cloud-config header
        #expect(config.userData.hasPrefix("#cloud-config\n"))

        // Parse userData YAML (skip the #cloud-config header line)
        let userDataYaml = String(config.userData.dropFirst("#cloud-config\n".count))
        let userData = try Yams.load(yaml: userDataYaml) as! [String: Any]

        // Verify hostname
        #expect(userData["hostname"] as? String == "test-host")

        // Verify users array with correct key mappings
        let users = userData["users"] as! [[String: Any]]
        #expect(users.count == 1)
        let user = users[0]
        #expect(user["name"] as? String == "testuser")
        #expect(user["shell"] as? String == "/bin/bash")
        #expect(user["sudo"] as? [String] == ["ALL=(ALL) NOPASSWD:ALL"])

        // Verify ssh_authorized_keys (snake_case key)
        let sshKeys = user["ssh_authorized_keys"] as? [String]
        #expect(sshKeys == ["ssh-rsa AAAAB3... user@host"])

        // Parse and verify metaData
        let metaData = try Yams.load(yaml: config.metaData) as! [String: Any]

        // Verify kebab-case keys in metadata
        #expect(metaData["local-hostname"] as? String == "test-host")
        #expect(metaData["instance-id"] as? String == "test-instance-123")
    }

    @Test("withPackagesAndCommands encodes packages and runcmd correctly")
    func withPackagesAndCommandsEncodesCorrectly() throws {
        let config = try CloudInitConfiguration.withPackagesAndCommands(
            instanceID: "pkg-instance",
            hostname: "pkg-host",
            username: "pkguser",
            sshKeys: [],
            packages: ["nginx", "curl", "htop"],
            runCommands: ["systemctl start nginx", "echo 'done'"]
        )

        // Parse userData
        let userDataYaml = String(config.userData.dropFirst("#cloud-config\n".count))
        let userData = try Yams.load(yaml: userDataYaml) as! [String: Any]

        // Verify packages array
        #expect(userData["packages"] as? [String] == ["nginx", "curl", "htop"])

        // Verify runcmd array
        #expect(userData["runcmd"] as? [String] == ["systemctl start nginx", "echo 'done'"])

        // Verify package_update and package_upgrade are true when packages are provided
        #expect(userData["package_update"] as? Bool == true)
        #expect(userData["package_upgrade"] as? Bool == true)
    }

    @Test("withDefaultPackagesAndCommands encodes write_files correctly")
    func withDefaultPackagesAndCommandsEncodesCorrectly() throws {
        let config = try CloudInitConfiguration.withDefaultPackagesAndCommands(
            instanceID: "default-instance",
            hostname: "default-host",
            username: "defaultuser",
            sshKeys: ["ssh-ed25519 AAAA... admin@server"]
        )

        // Parse userData
        let userDataYaml = String(config.userData.dropFirst("#cloud-config\n".count))
        let userData = try Yams.load(yaml: userDataYaml) as! [String: Any]

        // Verify packages include qemu-guest-agent (checkpolicy installed conditionally)
        #expect(userData["packages"] as? [String] == ["qemu-guest-agent"])

        // Verify runcmd includes conditional SELinux policy setup, service enable, and mount
        let runcmd = userData["runcmd"] as? [String]
        #expect(runcmd?.count == 3)
        // First command handles SELinux conditionally
        #expect(runcmd?[0].contains("semodule") == true)
        #expect(runcmd?[0].contains("checkmodule") == true)
        // Second command handles service startup with systemd
        #expect(runcmd?[1].contains("systemctl") == true)
        #expect(runcmd?[1].contains("daemon-reload") == true)
        // Third command creates mount point and mounts
        #expect(runcmd?[2].contains("mkdir -p") == true)
        #expect(runcmd?[2].contains("mount -a") == true)

        // Verify write_files array (snake_case key)
        let writeFiles = userData["write_files"] as! [[String: Any]]
        #expect(writeFiles.count == 3)

        // Find SELinux policy file
        let selinuxFile = writeFiles.first { $0["path"] as? String == "/etc/selinux/qemu-vsock.te" }
        #expect(selinuxFile != nil)
        #expect((selinuxFile?["content"] as? String)?.contains("virt_qemu_ga_t") == true)

        // Find systemd service file
        let serviceFile = writeFiles.first {
            $0["path"] as? String == "/etc/systemd/system/qemu-guest-agent.service"
        }
        #expect(serviceFile != nil)
        #expect(
            serviceFile?["content"] as? String == """
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
                """)

        // Find fstab entry file
        let fstabFile = writeFiles.first { $0["path"] as? String == "/etc/fstab" }
        #expect(fstabFile != nil)
        #expect((fstabFile?["content"] as? String)?.contains("hostHome") == true)
        #expect((fstabFile?["content"] as? String)?.contains("virtiofs") == true)
        #expect(fstabFile?["append"] as? Bool == true)
    }
}
