# vm

A fast, native command-line virtual machine manager for Linux guests.

Built with Swift and Apple's Virtualization.framework — no emulation, just native performance.

## Features

- **Native Performance** — Runs Linux VMs at near-native speed using Apple's hypervisor
- **Simple CLI** — Intuitive commands for creating, starting, stopping, and managing VMs
- **Cloud-init Support** — Automatic VM provisioning with SSH keys and user configuration
- **Background or Interactive** — Run VMs headless as daemons or attach to the console
- **Sparse Disk Images** — Disk images only consume space as needed
- **APFS Snapshots** — Point-in-time disk and NVRAM snapshots using copy-on-write clones
- **Guest Agent** — Automatic network info reporting when `qemu-guest-agent` is present in the guest

## Requirements

- macOS 15.0 (Sequoia) or later
- **Swift 6.0+** — only if you build from source; the release `.pkg` ships a prebuilt binary

## Installation

### GitHub Releases (recommended)

Download the latest **`vm-<version>.pkg`** from the [releases](https://github.com/subpop/VM/releases) page, open it, and run the installer. It installs the `vm` binary to **`/usr/local/bin`**.

### Build from Source

Requires a Swift 6 toolchain and a **Developer ID Application** identity in your keychain if you use the Makefile (the `build` target signs the binary).

```bash
git clone https://github.com/subpop/VM.git
cd VM
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make build-release
```

Install to your PATH (or run from `.build/release/`):

```bash
install -m755 .build/release/vm /usr/local/bin/
```

To compile without signing via Make, use **`swift build -c release`** and copy `.build/release/vm` yourself.

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
| `vm snapshot create <name> [snapshot]` | Create a snapshot (VM must be stopped) |
| `vm snapshot list <name>` | List snapshots for a VM |
| `vm snapshot restore <name> <snapshot>` | Restore a VM from a snapshot |
| `vm snapshot delete <name> <snapshot>` | Delete a snapshot |

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

### Snapshots

Snapshots capture the VM's disk and EFI/NVRAM state. On APFS volumes, snapshots use copy-on-write clones for space efficiency — only changed blocks consume additional space.

The VM must be stopped before creating, restoring, or deleting snapshots.

```bash
# Create a snapshot (name defaults to timestamp)
vm snapshot create ubuntu
vm snapshot create ubuntu before-upgrade --description "Before dist-upgrade"

# List snapshots
vm snapshot list ubuntu

# Restore (creates a pre-restore backup by default)
vm snapshot restore ubuntu before-upgrade

# Delete a snapshot
vm snapshot delete ubuntu before-upgrade
```

For best results, keep `~/.vm` on an APFS volume (the default on internal Mac storage). On non-APFS volumes, snapshots still work but use full file copies.

### Rescue Mode

Boot a VM into a rescue environment for recovery operations:

```bash
vm rescue ubuntu
```

This boots a Fedora Cloud rescue system with the target VM's disk attached as `/dev/vdb`. Useful for filesystem repairs, password resets, or data recovery.

On first run, a rescue image is downloaded and set up (~500MB download). The `rescue` use is logged in automatically, however both the `rescue` and `root` user have their passwords set to `rescue`.

## Shell completion

`vm` supports tab-completion for subcommands, options, and VM names. Generate a completion script for your shell and source it (or install it in your shell’s completion directory).

### Generate the script

```bash
# Auto-detect shell
vm --generate-completion-script

# Or specify the shell explicitly
vm --generate-completion-script bash
vm --generate-completion-script zsh
vm --generate-completion-script fish
```

### Bash

Append the generated script to your `~/.bashrc` or load it once:

```bash
vm --generate-completion-script bash >> ~/.bashrc
# then start a new shell, or:
source ~/.bashrc
```

Or install to a completions directory (e.g. on macOS with Homebrew bash):

```bash
vm --generate-completion-script bash > $(brew --prefix)/etc/bash_completion.d/vm
```

### Zsh

Load the script from your `.zshrc`:

```bash
# Add to ~/.zshrc
source <(vm --generate-completion-script zsh)
```

Or install for all users (e.g. into a site-functions directory):

```bash
vm --generate-completion-script zsh > /usr/local/share/zsh/site-functions/_vm
```

With oh-my-zsh, put the script in your completions folder:

```bash
vm --generate-completion-script zsh > ~/.oh-my-zsh/completions/_vm
```

### Fish

Save the script to Fish’s completions directory:

```bash
vm --generate-completion-script fish > ~/.config/fish/completions/vm.fish
```

Start a new shell or run `fish_update_completions` so Fish picks it up.

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
- **Guest Agent** — Enabled when `qemu-guest-agent` is present; on mutable roots it may be installed on first boot if missing. Bootc/OSTree guests should ship it in the image (cloud-init does not use `packages:` for it, avoiding `dnf` on read-only systems).
- **Home Directory** - Automatically mounted into guest using virtiofsd

You can also augment the generated cloud-init `user-data` with your own user-data file:

```bash
vm create ubuntu --cloud-init-user-data ~/my-cloud-init.yaml
vm import ubuntu --disk ~/VMs/ubuntu.img --cloud-init-user-data ~/my-cloud-init.yaml
```

Fragment merge rules:

- The default generated user is always kept as the first user.
- `users`, `bootcmd`, `packages`, `runcmd`, and `write_files` are appended from your user-data.
- Other top-level keys are rejected to keep required VM defaults intact.

If you update your user-data after VM creation, copy it into `~/.vm/<name>/cloud-init.user-data.yaml` and
regenerate the ISO:

```bash
vm regen-cloud-init-iso ubuntu
```

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

