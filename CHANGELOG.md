## 0.1.1 (2026-04-29)

- ✨ Add support for custom cloud-init user-data on create/import that merges with the base cloud-config.
- 📦 Better support for building with Makefile (removing the SPM plugin).

## 0.1.0 (2026-03-11)

- 🚀 Initial release! `vm` is a command line application for macOS that hosts Linux guests using Virtualization.framework.
  Commands include `create`, `start`, `import`, `rescue`, `resize`, `edit`. It supports cloud-init for boot-time configuration, and opens SSH and VSOCK ports for guest ↔ host interaction.
