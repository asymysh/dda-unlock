# Hyper-V DDA on Windows 11 Client â†’ NVIDIA GPU to a Fedora VM

> A complete, reproducible recipe for passing a discrete NVIDIA GPU through
> Hyper-V to a Fedora Linux virtual machine on a **Windows 11 client SKU**
> (Pro / Enterprise / LTSC), not Windows Server.

Microsoft's official line is that **Discrete Device Assignment (DDA) is only
supported on Windows Server**. On Windows 11 client, every attempt fails with
`HV_STATUS_ACCESS_DENIED (0xC035001E)` at "Virtual PCI Express Port: Failed to
Power on." This guide documents the full configuration â€” including the one
single registry value that's actually responsible for the gate â€” that makes
real, full passthrough work on Windows 11 Enterprise.

The result: an NVIDIA GTX 1080 Ti inside a Fedora 44 VM running the
proprietary `580.159.04` driver, with `nvidia-smi` and CUDA 13 fully
functional, while the Windows host continues to use a separate AMD GPU for
gaming with kernel-level anti-cheat.

## Architecture

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚  Windows 11 Enterprise (host)                                  â”‚
â”‚                                                                â”‚
â”‚   AMD Radeon RX 6800 XT  â”€â”€â–º  Display, gaming, anti-cheat      â”‚
â”‚                                                                â”‚
â”‚   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”             â”‚
â”‚   â”‚  Hyper-V hypervisor (Classic scheduler)      â”‚             â”‚
â”‚   â”‚  hypervisoriommupolicy = Enable              â”‚             â”‚
â”‚   â”‚  ProductType = ServerNT (DDA unlock)         â”‚             â”‚
â”‚   â”‚  VBS / Credential Guard = OFF                â”‚             â”‚
â”‚   â”‚                                              â”‚             â”‚
â”‚   â”‚   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”      â”‚             â”‚
â”‚   â”‚   â”‚  Fedora 44 VM (Gen 2)             â”‚      â”‚             â”‚
â”‚   â”‚   â”‚  Secure Boot OFF                  â”‚      â”‚             â”‚
â”‚   â”‚   â”‚  16 GB RAM, 8 vCPU, 256 GB VHDX   â”‚      â”‚             â”‚
â”‚   â”‚   â”‚                                   â”‚â—„â”€â”€â”€â”€â”€â”¼â”€â”€â”€ DDA â”€â”€â”€â”€â”€â”¼â”€â”€â”€ NVIDIA GTX 1080 Ti
â”‚   â”‚   â”‚  NVIDIA driver 580.159.04         â”‚      â”‚             â”‚     + HDMI Audio Fn
â”‚   â”‚   â”‚  CUDA 13.0                        â”‚      â”‚             â”‚
â”‚   â”‚   â”‚  nvidia-smi: working              â”‚      â”‚             â”‚
â”‚   â”‚   â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜      â”‚             â”‚
â”‚   â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜             â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

## What you'll need

| Requirement | Tested with |
|---|---|
| CPU with IOMMU (Intel VT-d / AMD-Vi) | AMD Ryzen 9 5900X |
| Motherboard exposing **ACS** in BIOS | ASUS Pro WS X570-ACE (workstation board) |
| Two GPUs (one for host, one to pass through) | AMD RX 6800 XT (host) + NVIDIA GTX 1080 Ti (guest) |
| Windows 11 Pro / Enterprise / LTSC | 25H2, build 26200 |
| â‰¥ 32 GB RAM | 32 GB |
| Hyper-V role enabled | â€” |
| Fedora ISO | Fedora Workstation 44 |

## Guide

| # | Section | What it covers |
|---|---|---|
| 01 | [Overview](docs/01-overview.md) | The problem, the solution, what to expect |
| 02 | [Prerequisites](docs/02-prerequisites.md) | Hardware, software, time, and risk |
| 03 | [BIOS configuration](docs/03-bios-configuration.md) | IOMMU, ACS, Above-4G, SVM |
| 04 | [Windows host setup](docs/04-windows-host-setup.md) | VBS off, scheduler, IOMMU policy, **ProductType flip** |
| 05 | [VM creation](docs/05-vm-creation.md) | Gen 2 VM, MMIO, Secure Boot, all the DDA constraints |
| 06 | [GPU passthrough](docs/06-gpu-passthrough.md) | Dismount, assign, first boot with GPU |
| 07 | [Fedora guest setup](docs/07-fedora-guest-setup.md) | SSH, autologin, NVIDIA legacy driver branch |
| 08 | [Verification](docs/08-verification.md) | `nvidia-smi`, sanity checks, CUDA test |
| 09 | [Reversal](docs/09-reversal.md) | Putting everything back |
| â˜… | [Troubleshooting](docs/troubleshooting.md) | The actual common errors and what they mean |

## Quick start (for the impatient)

If you've done DDA before and just want the cheat sheet for Win11 client:

1. Enable IOMMU + **ACS Enable** in BIOS (`AcsCompatibleUpHierarchy: 3` in PowerShell verifies success).
2. Run [`scripts/guide/01-host-prep.ps1`](scripts/guide/01-host-prep.ps1) â€” disables VBS / VMP / WHP, sets Classic scheduler, enables `hypervisoriommupolicy`.
3. Reboot, then flip `ProductType = ServerNT` offline in WinRE (see [Windows host setup Â§4](docs/04-windows-host-setup.md#41-productype-flip)).
4. Run [`scripts/guide/02-create-vm.ps1`](scripts/guide/02-create-vm.ps1), install Fedora normally.
5. Run [`scripts/guide/03-attach-gpu.ps1`](scripts/guide/03-attach-gpu.ps1) to dismount + assign the GPU.
6. SSH into the VM, run [`scripts/guide/06-guest-install-nvidia.sh`](scripts/guide/06-guest-install-nvidia.sh).
7. Reboot the VM, `nvidia-smi` works.

If anything fails, **read [the troubleshooting guide](docs/troubleshooting.md)
first** â€” it covers all the errors we hit during development.

## Scripts

All operational steps are scripted under [`scripts/`](scripts/):

| Script | Purpose |
|---|---|
| [`01-host-prep.ps1`](scripts/guide/01-host-prep.ps1) | Disable VBS/VMP/WHP, scheduler, IOMMU policy, HyperV policy keys |
| [`02-create-vm.ps1`](scripts/guide/02-create-vm.ps1) | Create the Gen 2 VM with all DDA-required settings |
| [`03-attach-gpu.ps1`](scripts/guide/03-attach-gpu.ps1) | Dismount the GPU and audio companion, attach to VM |
| [`04-detach-gpu.ps1`](scripts/guide/04-detach-gpu.ps1) | Detach the GPU and return it to the host |
| [`05-health-check.ps1`](scripts/guide/05-health-check.ps1) | Verify host + VM + guest state at a glance |
| [`06-guest-install-nvidia.sh`](scripts/guide/06-guest-install-nvidia.sh) | Install the right NVIDIA driver branch inside Fedora |

Read the parameter blocks at the top of each script â€” they're commented and
have sensible defaults but adapt to your hardware.

## What this is NOT

- **Not officially supported by Microsoft.** Microsoft will not help you if
  something breaks. Treat this as a community workaround.
- **Not a Windows licensing change.** The `ProductType` flip is reverted by
  Windows licensing service at runtime â€” the hypervisor only reads it at
  boot, so the flip survives long enough to enable DDA but does not alter
  your Windows edition, activation, or eligibility for updates in any
  observed way.
- **Not GPU partitioning.** A single VM gets the whole GPU. If you want to
  share a GPU across multiple VMs simultaneously, look at **GPU-P**
  (paravirtualization) instead â€” that's a different mechanism with its own
  guide (not covered here).
- **Not anti-cheat friendly inside the VM.** Anything inside the Fedora VM is
  a virtual machine and will be detected as such. This is for Linux
  workflows on the *guest* side; gaming with anti-cheat continues on the
  Windows *host*.

## Hardware support matrix

The recipe should generalize to most modern AMD/Intel platforms with proper
ACS support, but here's what was actually tested:

| Component | Status |
|---|---|
| AMD Ryzen 9 5900X + ASUS Pro WS X570-ACE | âœ… Works |
| NVIDIA GTX 1080 Ti (Pascal / GP102) | âœ… Works with `akmod-nvidia-580xx` (Pascal dropped from 590+) |
| Windows 11 Enterprise 25H2 (build 26200) | âœ… Works |
| Fedora Workstation 44 (kernel 7.0.12) | âœ… Works |

For other Pascal cards (1080, 1070, 1060, etc.) and Maxwell/Volta, use the
same `580xx` legacy driver branch. For Turing and newer, you can use the
mainline `akmod-nvidia`.

## License

This documentation is provided as-is for personal and educational use. The
underlying technology (Hyper-V, DDA) belongs to Microsoft; NVIDIA drivers
belong to NVIDIA. The `ProductType` workaround is a community discovery
documented in several public places â€” see [credits](docs/troubleshooting.md#credits--references).

## Disclaimer

This is **not officially supported by Microsoft, NVIDIA, or Red Hat**. It
modifies system-level configuration including the boot configuration data
(BCD), Virtualization-Based Security state, and the offline Windows registry.
**Back up your data and your BCD before proceeding** (the host-prep script
does the BCD export for you). If you have a corporate machine joined to an
AD/MDM, ask your IT department first â€” disabling Credential Guard is a real
security posture change.
