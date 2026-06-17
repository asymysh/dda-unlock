# 02 · Prerequisites

[← Overview](01-overview.md) · [BIOS configuration →](03-bios-configuration.md)

## Hardware

### CPU

- **Must support IOMMU virtualization** — AMD-Vi (AMD) or VT-d (Intel).
- Reasonable core count for the VM. We use 8 of 12 cores.
- Tested: **AMD Ryzen 9 5900X** (12 cores / 24 threads, AM4).

### Motherboard

The motherboard has to expose **ACS (Access Control Services)** for the
PCIe slot your passthrough GPU sits in, otherwise the Hyper-V hypervisor
can't isolate the device cleanly and DDA fails its assignability check.

Most **consumer** AM4/AM5 boards (Asus TUF, Strix, Gigabyte Aorus Elite,
etc.) do **not** expose ACS controls in BIOS. The setting exists in AMD AGESA
but is hidden in consumer firmware.

**Prosumer / workstation boards do.** The board we tested on, the
**ASUS Pro WS X570-ACE**, exposes:

- `Advanced → AMD CBS → NBIO Common Options → ACS Enable`
- `Advanced → AMD CBS → NBIO Common Options → IOMMU` (sub-options)

If your board doesn't have ACS Enable in BIOS, search for:

- `PCIe ARI Support`
- `IOMMU Pre-Boot DMA Protection`
- vendor-specific virtualization toggle names

If none are present, this recipe will likely not work on your board. You can
verify with the steps in [§03 BIOS configuration](03-bios-configuration.md)
and the PowerShell health checks in [§08 Verification](08-verification.md).

### GPUs (two of them)

You need **two GPUs** — one for the Windows host, one to dedicate to the VM.
The reason is simple: DDA is exclusive. The moment the NVIDIA GPU is
dismounted from the host, the host has no display output on that card. If
that was your only GPU, you'd lose all display.

Recommended setups:

- **iGPU + dGPU**: Use the CPU's integrated graphics for the host, pass the
  discrete card. Requires a CPU with an iGPU (Intel iGPU, AMD G-series, or
  Ryzen 7000+ with built-in graphics).
- **Two dGPUs**: One for host, one for guest. This is what we did
  (AMD RX 6800 XT + NVIDIA GTX 1080 Ti).

The passed-through GPU should ideally have a monitor or dummy plug
connected, otherwise some applications inside the VM won't initialize
properly. We accessed the guest over SSH in this guide, but for a graphical
session you'll want a monitor or dummy plug on the assigned GPU.

#### GPU compatibility note

This guide was tested with an **NVIDIA GTX 1080 Ti (Pascal, GP102)**.

NVIDIA driver branches matter for older GPUs:

| Architecture | Cards | Last supported NVIDIA driver branch |
|---|---|---|
| Turing+ | RTX 20-series and newer | Current mainline (595+) |
| **Pascal** | **GTX 10-series, Titan Xp** | **580.x (`akmod-nvidia-580xx`)** ← what this guide uses |
| Maxwell | GTX 9-series | 470.x (`akmod-nvidia-470xx`) |
| Kepler | GTX 6-/7-series | 470.x (last) or 390.x |

Pick the right RPM Fusion akmod package — see
[§07 Fedora guest setup](07-fedora-guest-setup.md).

### Network

Any NIC will work. We used the Intel I211 onboard. The motherboard's Realtek
8168 BMC NIC broke after BIOS changes — that's a known sidequest documented
separately. If you have one and only one NIC and it's a Realtek, read
[`reference/realtek-nic-issue.md`](../reference/realtek-nic-issue.md)
before changing BIOS settings.

### RAM and storage

| Resource | Minimum | Recommended | Tested |
|---|---|---|---|
| Host RAM | 16 GB | 32 GB | 32 GB |
| Free disk for VM | 100 GB | 256 GB | 256 GB (dynamic VHDX) |
| VM RAM (static) | 8 GB | 16 GB | 16 GB |
| VM vCPUs | 4 | 8 | 8 |

Static RAM means no dynamic memory ballooning — required by DDA.

## Software

### Windows

| Item | Required version | Tested |
|---|---|---|
| Windows edition | **Pro** / **Enterprise** / **Pro for Workstations** / **LTSC** | Enterprise 25H2 |
| Windows build | Recent (22H2+) | Build 26200 |
| Hyper-V role | Enabled (`Microsoft-Hyper-V-All`) | — |
| PowerShell | 5.1+ | 5.1 |

**Windows Home will not work** — Hyper-V isn't available on Home SKU.

### Guest OS

Anything with proper Linux kernel support for `hv_pci` (Hyper-V VPCI virtual
bus) works. Tested with:

- **Fedora Workstation 44** (kernel 7.0.12-201.fc44)

The same recipe applies to other modern Linux distros with minor
adjustments (e.g., Ubuntu uses `apt` instead of `dnf`, has slightly
different NVIDIA driver packaging).

### Tooling

- **PowerShell** (built into Windows) for all host-side scripting.
- **`bcdedit`** (built into Windows) for boot configuration.
- **`reg.exe`** in Recovery Environment for the offline ProductType edit.
- **OpenSSH client** on Windows (built in since Windows 10 1809) for guest
  access.
- Optional: **Posh-SSH** PowerShell module if you want to script the guest
  from PowerShell. We use direct `ssh.exe` in this guide.

## Time and effort

Realistic time estimate for someone going through this for the first time,
with everything documented:

| Step | Time |
|---|---|
| BIOS configuration + boot back into Windows | 10 min |
| Windows host setup (registry, bcdedit, reboot) | 15 min |
| Download Fedora ISO + create VM | 10 min |
| Install Fedora interactively | 15 min |
| Dismount GPU + attach + VM first boot with GPU | 5 min |
| Inside Fedora: SSH + autologin + NVIDIA driver install | 30 min (mostly waiting for akmod build) |
| Reboot + verification | 5 min |
| **Total** | **~90 minutes** |

If you hit an unexpected issue, add an extra hour or two for diagnosis. The
[troubleshooting guide](troubleshooting.md) covers the failures we hit
during development.

## Risks and reversibility

Everything in this recipe is reversible. Specifically:

- **BCD changes** are backed up by the host-prep script before any
  modification. You can restore with `bcdedit /import <backup-path>`.
- **Registry changes** to disable VBS / Credential Guard / HVCI are simple
  DWORD values — set them back to default or delete to revert.
- **The ProductType flip** is done again with `/d WinNT` to revert.
- **DDA assignment** is undone with `Remove-VMAssignableDevice` +
  `Mount-VMHostAssignableDevice` + re-enabling the device.
- **BIOS changes** are revertable by reverting in BIOS.

The one thing you should NOT do casually is delete `/etc/gdm/custom.conf`
mid-setup, because the guest will lose autologin and need a console keyboard.

## Before you proceed

You should be comfortable with:

- PowerShell at an administrator prompt
- Booting into UEFI BIOS and changing settings
- Using the Windows Recovery Environment command prompt
- Editing the Linux kernel cmdline and running `dnf`/`apt`
- Reading systemd journal output

If any of those feel unfamiliar, work through them on a non-critical machine
first.

You should also **back up anything irreplaceable on the Windows host** — not
because this recipe is dangerous, but because the BIOS and recovery
environment work it requires means you're a few keystrokes away from
unbootable. We had no boot failures during this guide's development, but
the operations involved deserve respect.

Ready? On to the [BIOS configuration](03-bios-configuration.md).

[← Overview](01-overview.md) · [BIOS configuration →](03-bios-configuration.md)
