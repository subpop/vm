# vm

A fast, native command-line virtual machine manager for Linux guests.

Built with Swift and Apple's Virtualization.framework — no emulation, just native performance.

## Features

- **Native Performance** — Runs Linux VMs at near-native speed using Apple's hypervisor
- **Simple CLI** — Intuitive commands for creating, starting, stopping, and managing VMs
- **Cloud-init Support** — Automatic VM provisioning with SSH keys and user configuration
- **Background or Interactive** — Run VMs headless as daemons or attach to the console
- **Sparse Disk Images** — Disk images only consume space as needed
- **Guest Agent** — Automatic network info reporting via vsock

## Requirements

- macOS 15.0 (Sequoia) or later
- Swift 6.0+

## Installation

### Build from Source

```bash
git clone https://github.com/yourusername/VM.git
cd VM
swift build -c release
```

The executable requires virtualization entitlements. Sign it using the included plugin:

```bash
swift package plugin sign
```

Then copy to your PATH:

```bash
cp .build/release/vm /usr/local/bin/
```

## Quick Start

**1. Download a Linux ISO**

Grab an cloud image or server ISO for your architecture — Ubuntu, Debian, Fedora, Arch, etc.

**2. Create a VM**

```bash
vm create ubuntu --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso
```

**3. Start and Install**

```bash
vm start ubuntu --interactive --iso
```

This boots from the ISO for installation. Press `Ctrl-]` to detach from the console.

**4. Boot Normally**

After installation, start without the ISO flag:

```bash
vm start ubuntu --interactive
```

Or run headless:

```bash
vm start ubuntu
```

## Commands

| Command | Description |
|---------|-------------|
| `vm list` | List all VMs and their status |
| `vm create <name>` | Create a new VM |
| `vm import <name>` | Import an existing disk image |
| `vm start <name>` | Start a VM (background) |
| `vm start <name> -i` | Start a VM (interactive) |
| `vm stop <name>` | Stop a running VM |
| `vm attach <name>` | Attach to a running VM's console |
| `vm ssh <name>` | SSH into a running VM |
| `vm info <name>` | Show detailed VM information |
| `vm rescue <name>` | Boot into rescue environment |
| `vm delete <name>` | Delete a VM and its files |

### Create Options

```bash
vm create myvm \
  --iso ~/path/to/installer.iso \
  --disk-size 64G \
  --cpus 4 \
  --memory 8G \
  --interactive  # Start immediately after creation
```

### Import Existing Disk

```bash
# Use disk in-place (creates symlink)
vm import myvm --disk ~/existing.img

# Copy disk to VM directory
vm import myvm --disk ~/existing.img --copy

# Copy and resize
vm import myvm --disk ~/existing.img --copy --size 128G
```

### Rescue Mode

Boot a VM into a rescue environment for recovery operations:

```bash
vm rescue ubuntu
```

This boots a Fedora Cloud rescue system with the target VM's disk attached as `/dev/vdb`. Useful for filesystem repairs, password resets, or data recovery.

On first run, a rescue image is downloaded and set up (~500MB download). The `rescue` use is logged in automatically, however both the `rescue` and `root` user have their passwords set to `rescue`.

## VM Storage

VMs are stored in `~/.vm/` with each VM in its own directory:

```
~/.vm/
└── ubuntu/
    ├── config.json      # VM configuration
    ├── disk.img         # Disk image
    ├── nvram.bin        # EFI variable store
    ├── cloud-init.iso   # Cloud-init configuration
    ├── ssh_config       # SSH config for this VM
    ├── console.sock     # Console socket (when running)
    └── vm.pid           # PID file (when running)
```

## Cloud-init

VMs are automatically provisioned with cloud-init:

- **SSH Keys** — Your `~/.ssh/*.pub` keys are injected for passwordless login
- **Username** — Matches your macOS username
- **Hostname** — Set to the VM name
- **Guest Agent** — Installed automatically for network info reporting
- **Home Directory** - Automatically mounted into guest using virtiofsd

After the VM boots with cloud-init support, you can SSH directly:

```bash
vm ssh ubuntu
```

Or with options:

```bash
vm ssh ubuntu --user root
vm ssh ubuntu -- -v -L 8080:localhost:80
```

### SSH Config Integration

Each VM includes an `ssh_config` file that allows you to SSH using just the VM name. To enable this, add the following line to the **top** of your `~/.ssh/config`:

```
Include ~/.vm/*/ssh_config
```

Then you can SSH directly using the VM name as the host:

```bash
ssh ubuntu
scp file.txt ubuntu:~/
rsync -av ./project ubuntu:~/project
```

This works by using a ProxyCommand that resolves the VM's IP address dynamically via `vm ip`.

## Console

When attached to a VM console:

- **Ctrl-]** — Detach from console (VM keeps running)

The console provides a serial connection to the VM. For graphical desktop VMs, you'll want to use VNC or another remote desktop solution.

## Architecture

```
vm (CLI)
├── create    → Creates VM config + disk + cloud-init ISO
├── start     → Spawns daemon process
├── stop      → Signals daemon to gracefully shutdown
├── attach    → Connects to console socket
├── ssh       → Connects via SSH using VM's IP
└── ...

vm run-daemon (internal)
├── Configures Virtualization.framework
├── Creates console socket listener
├── Runs guest agent (vsock) for network info
└── Manages VM lifecycle
```

## License

Apache 2.0 License — see [LICENSE](LICENSE) for details.

