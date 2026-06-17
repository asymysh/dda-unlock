# 01 · Overview

[← Back to README](../README.md)

## The problem

You want to use Hyper-V to run a Linux virtual machine on Windows 11, and you
want that VM to have **real access to a physical NVIDIA GPU** — not a
synthetic video adapter, not a paravirtualized share, but the actual PCIe
device. The card should appear in `lspci`, the proprietary NVIDIA driver
should bind to it, and `nvidia-smi` should report the full VRAM, temperature,
and CUDA compute capability.

The right tool for this job is **Discrete Device Assignment (DDA)**. DDA is
Hyper-V's PCIe passthrough mechanism — analogous to VFIO/KVM on Linux. It
takes a host PCIe device, dismounts it from the Windows kernel, and projects
it into a guest VM as a real PCIe endpoint.

There's just one problem.

> **Microsoft says DDA is only supported on Windows Server.**

If you follow the [official Microsoft documentation][ms-dda] on a Windows 11
Pro or Enterprise host, you will dismount your GPU, attach it to a VM,
attempt to start the VM, and be greeted with:

```
'YourVM' failed to start.
Virtual Pci Express Port (Instance ID ...): Failed to Power on with Error
'A hypervisor feature is not available to the user'. (0xC035001E).
```

You will then waste several hours doing what the entire community before you
has wasted hours doing — disabling VBS, disabling Credential Guard,
disabling HVCI, disabling Memory Integrity, disabling VMP, disabling WHP,
switching the hypervisor scheduler from Root to Classic, removing
UEFI-locked Credential Guard via `SecConfig.efi`, tweaking BIOS settings —
and you will hit `0xC035001E` every single time.

None of that is the cause. The cause is that the Hyper-V hypervisor reads a
single registry value at boot:

```
HKLM\SYSTEM\ControlSet001\Control\ProductOptions
ProductType = WinNT
```

`WinNT` means "this is desktop Windows." `ServerNT` means "this is Server."
**The hypervisor refuses to expose the DDA Virtual PCIe Port feature to the
root partition when `ProductType = WinNT`.** That is the whole gate.

## The solution

Flip `ProductType` from `WinNT` to `ServerNT`. The hypervisor unlocks DDA.
Everything works.

Because Windows protects this value at runtime, you can't just edit the
running registry. You boot into the Windows Recovery Environment, load the
offline `SYSTEM` hive, change the value, unload the hive, and continue to
Windows. The hypervisor reads `ServerNT` at boot, exposes the DDA feature,
and your VM starts with the GPU attached. (The licensing service later
rewrites `ProductType` back to `WinNT` at runtime — that's fine, the
hypervisor already has what it needs for this session.)

## What you'll achieve

After working through this guide:

- The NVIDIA GPU shows up inside the Fedora VM as a real PCIe device:
  ```
  $ lspci -nn | grep NVIDIA
  48e0:00:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP102 [GeForce GTX 1080 Ti]
  b860:00:00.0 Audio device [0403]: NVIDIA Corporation GP102 HDMI Audio Controller
  ```
- The proprietary NVIDIA Linux driver loads cleanly:
  ```
  $ lspci -nnk -d 10de:1b06 | tail -1
        Kernel driver in use: nvidia
  ```
- `nvidia-smi` works with the full VRAM exposed:
  ```
  $ nvidia-smi
  NVIDIA-SMI 580.159.04             Driver Version: 580.159.04     CUDA Version: 13.0
  NVIDIA GeForce GTX 1080 Ti    | 0%   53C    P5    13W/280W | 3MiB / 11264MiB
  ```
- The Windows host continues to use a separate AMD GPU for normal display
  and anti-cheat-compatible gaming.

## What you give up

- **Credential Guard.** The default Windows 11 Enterprise security feature
  that protects credential material from kernel-mode attackers is disabled.
  On a personal dev machine this is a sensible tradeoff. On a corporate
  endpoint, **don't do this without IT approval**.
- **Hyper-V partition-sharing features.** Disabling Virtual Machine Platform
  (VMP) breaks WSL2 and Windows Sandbox. Disabling Windows Hypervisor
  Platform (WHP) breaks Docker Desktop's hypervisor backend, VirtualBox 6+,
  VMware Workstation 16+, and Android emulators. If you need those, this is
  the wrong approach for you — use [GPU-P paravirtualization][gpu-pv]
  instead.
- **The whole GPU.** DDA is exclusive — the GPU belongs to one VM. You
  cannot use it on the host or in other VMs simultaneously. To get it back
  on the host, you stop the VM, detach the device, and re-mount it.

## How it's structured

The rest of this guide walks you through the recipe end to end:

1. [Prerequisites](02-prerequisites.md) — what you need before starting
2. [BIOS configuration](03-bios-configuration.md) — the hardware-level enables
3. [Windows host setup](04-windows-host-setup.md) — VBS off, scheduler, ProductType flip
4. [VM creation](05-vm-creation.md) — building the Fedora VM correctly
5. [GPU passthrough](06-gpu-passthrough.md) — the actual DDA mechanics
6. [Fedora guest setup](07-fedora-guest-setup.md) — NVIDIA driver inside the VM
7. [Verification](08-verification.md) — proving it works
8. [Reversal](09-reversal.md) — putting everything back
9. [Troubleshooting](troubleshooting.md) — when something goes wrong

Each chapter is self-contained. If you've already done part of the work,
skip ahead.

[← Back to README](../README.md) · [Prerequisites →](02-prerequisites.md)

[ms-dda]: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/deploying-graphics-devices-using-dda
[gpu-pv]: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/gpu-partitioning
