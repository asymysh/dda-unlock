# Troubleshooting

[← Reversal](09-reversal.md) · [Back to README](../README.md)

Failures we hit during development, what they mean, and how to fix them.

If you're reading this because the VM won't start, **the answer is almost
certainly in §1 (the ProductType flip)**.

## 1. `0xC035001E` — "A hypervisor feature is not available to the user"

```
'Fedora' failed to start.
Virtual Pci Express Port (Instance ID ...): Failed to Power on with Error
'A hypervisor feature is not available to the user'. (0xC035001E).
```

**What it means**: The Hyper-V hypervisor's root partition asked for the
DDA "Virtual PCIe Port" capability. The hypervisor refused because it
believes it's running on a Windows client SKU.

**Cause** (almost always): `ProductType` is `WinNT` in the SYSTEM hive at
boot. The DDA SKU gate is the cause; everything else is a red herring.

**Fix**: Complete the ProductType flip from
[§4.6](04-windows-host-setup.md#46-the-productype-flip--this-is-the-dda-unlock).

**Other possible contributing causes**:

| Symptom | Check | Fix |
|---|---|---|
| `hypervisoriommupolicy` not set | `bcdedit /enum "{current}" \| Select-String 'hypervisoriommupolicy'` | `bcdedit /set hypervisoriommupolicy Enable` then reboot |
| `LsaIso.exe` still running | `Get-Process LsaIso` | UEFI-locked Credential Guard — use SecConfig.efi method from [§4.3](04-windows-host-setup.md#43-uefi-locked-credential-guard-if-applicable) |
| VMP / WHP still enabled | `Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform` | Disable per [§4.2](04-windows-host-setup.md#disable-vmp-and-whp) |

If `ProductType = ServerNT`, `hypervisoriommupolicy = Enable`, `LsaIso.exe`
is gone, VMP/WHP are off, and you still get `0xC035001E` — your BIOS
hasn't properly exposed ACS. See [§03](03-bios-configuration.md).

## 2. `dmesg` shows `probe with driver nvidia failed with error -1`

```
[   19.870736] NVRM: The NVIDIA GPU 48e0:00:00.0 (PCI ID: 10de:1b06)
               NVRM: nvidia.ko because it does not include the required GPU
[   19.871113] nvidia 48e0:00:00.0: probe with driver nvidia failed with error -1
```

**What it means**: The nvidia kernel module loaded but doesn't include
support for your specific GPU. **You installed the wrong driver branch.**

**Cause**: NVIDIA dropped support for older architectures (Pascal,
Maxwell, Kepler) from the mainline 590+ driver. RPM Fusion's plain
`akmod-nvidia` is currently the mainline branch.

**Fix**: Use the right legacy branch for your architecture. For Pascal
(GTX 10-series), use `akmod-nvidia-580xx`:

```bash
sudo dnf remove -y 'akmod-nvidia' 'xorg-x11-drv-nvidia*' 'kmod-nvidia*' nvidia-settings
sudo dnf install -y --skip-unavailable \
    akmod-nvidia-580xx \
    xorg-x11-drv-nvidia-580xx-cuda \
    xorg-x11-drv-nvidia-580xx-cuda-libs \
    nvidia-settings-580xx
sudo akmods --force --rebuild
sudo reboot
```

See [§7.1](07-fedora-guest-setup.md#71-picking-the-right-nvidia-driver-branch)
for the full GPU-architecture-to-branch table.

## 3. `nvidia-smi` says "couldn't communicate with the NVIDIA driver"

```
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.
Make sure that the latest NVIDIA driver is installed and running.
```

Several possible causes:

### 3a. nouveau is still loaded

```bash
lsmod | grep -E 'nvidia|nouveau'
```

If nouveau is listed, it hasn't been blacklisted properly.

```bash
# Check the blacklist files exist
ls /etc/modprobe.d/ /usr/lib/modprobe.d/ | grep -i nouveau
# Check the kernel cmdline
cat /proc/cmdline | tr ' ' '\n' | grep -i nouveau
# Regenerate initramfs
sudo dracut --force --regenerate-all
sudo reboot
```

### 3b. The wrong driver branch loaded (silent — `dmesg` will show error -1)

See §2 above.

### 3c. The module didn't actually build

```bash
ls /lib/modules/$(uname -r)/extra/nvidia*/
# If empty: akmod build failed
sudo akmods --force --rebuild 2>&1 | tee /tmp/akmod.log
# Check the log for errors
```

## 4. VM starts, GPU not visible inside (`lspci` shows nothing NVIDIA)

**What it means**: DDA succeeded at the Hyper-V level, but the guest kernel
hasn't enumerated the device.

**Causes / fixes**:

- **`hv_pci` failed to probe**: check `dmesg | grep hv_pci`. If you see
  errors, the VPCI tunnel is broken — most often this is a Hyper-V
  integration services version mismatch. Make sure the VM is on a current
  Fedora kernel (`uname -r` should be at least 6.x).
- **Wrong VM Generation**: must be Gen 2 for modern PCIe pass-through.
- **High MMIO window too small**: re-check
  [§5.4](05-vm-creation.md#54-mmio-sizing--the-detail-that-often-gets-wrong).

## 5. Realtek NIC fails after BIOS changes (Code 31 / `CM_PROB_FAILED_ADD`)

Specifically affects Realtek 8168-family NICs when **PCIe ARI Support** is
enabled in BIOS. The Realtek silicon misenumerates with ARI on.

**Fix**: disable PCIe ARI in BIOS, or just live without that NIC if you
have another working one (Intel NICs are unaffected and arguably better
silicon anyway).

Full details in [`reference/realtek-nic-issue.md`](../reference/realtek-nic-issue.md).

## 6. VM gets a different IP after every reboot

The Hyper-V "Default Switch" uses dynamic NAT IPs and doesn't preserve
leases across host reboots. There are three workarounds:

### 6a. Look the IP up via integration services

```powershell
(Get-VMNetworkAdapter -VMName Fedora).IPAddresses | Where-Object { $_ -match '^172\.21' }
```

This works after the VM has fully booted and integration services have
reported in (~30 seconds after boot).

### 6b. Use an internal/external switch with a static IP

Create a custom switch:

```powershell
New-VMSwitch -Name "Internal-DDA" -SwitchType Internal
# Then in the VM, set a static IP on the new interface.
```

### 6c. Use a hostname via mDNS

Fedora 44 ships with `avahi-daemon` (mDNS responder), so you can
typically reach the VM at `fedora.local`:

```bash
ssh aseem@fedora.local
```

If that doesn't resolve, install/start avahi:

```bash
sudo dnf install -y avahi nss-mdns
sudo systemctl enable --now avahi-daemon
```

## 7. `bcdedit` settings revert / don't persist

`bcdedit` settings are stored in the BCD store on the EFI System
Partition. If they vanish across reboots, the most common causes are:

- You set them on a different BCD store (not `{current}`)
- You're on a system that has Group Policy overriding them
- Disk error / EFI partition damage

Verify which store you're modifying:

```powershell
bcdedit /enum all | Select-String 'identifier|description' | Select-Object -First 20
```

Make sure the `{current}` entry's description matches the OS you booted.

## 8. `nvidia-smi` reports right GPU but `lspci` shows it on weird bus IDs

Example:

```
48e0:00:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP102 [GeForce GTX 1080 Ti]
```

The `48e0:00` part is unusual. **This is fine.** Hyper-V's VPCI driver
assigns each passed-through device its own synthetic PCIe segment, with
the segment number derived from a per-device GUID. The kernel handles it
correctly. CUDA, OpenGL, NVENC all work normally.

## 9. SSH stops working after VM reboot

Most likely: sshd wasn't enabled at boot. Fix:

```bash
sudo systemctl enable --now sshd
systemctl is-enabled sshd  # should print: enabled
```

If you can't reach the VM to fix it, use VMConnect to log in at the
console.

## 10. Windows host won't boot after BIOS / VBS / BCD changes

The recovery procedure:

1. Boot from Windows installation media (USB) or use automatic Recovery
   Environment (try to boot Windows; after 2-3 failed boots, Windows
   triggers WinRE automatically).
2. Choose **Troubleshoot → Advanced options → Command Prompt**.
3. Restore your BCD backup:
   ```cmd
   bcdedit /import D:\HyperV\bcd-backup-<date>
   ```
   (Replace `D:` with whichever drive letter has your backup.)
4. Reboot.

If you don't have a BCD backup, the generic recovery:

```cmd
bootrec /fixmbr
bootrec /fixboot
bootrec /rebuildbcd
```

## Credits & references

The single piece of information that unlocked this whole guide came from:

- **<https://github.com/Kidades/dda-win11>** — the `ProductType` flip
  workaround. The README of that repo is the most useful single document
  on DDA-on-client-Windows in existence.

Other meaningful references:

- **<https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/deploying-graphics-devices-using-dda>**
  — Microsoft's official DDA documentation. It's technically correct for
  Windows Server and matches our procedure for the VM-side configuration.
- **<https://learn.microsoft.com/en-us/answers/questions/1347364/>** — the
  Microsoft Q&A thread that has the exact error code and Microsoft's
  Server-only statement. Useful as the "this is officially unsupported"
  citation.
- **<https://gist.github.com/ad1107/3cdb30b3e34d4099afb20446b162bb2e>** —
  a competing approach using GPU-PV paravirtualization for a Linux guest.
  Different mechanism than DDA; documented for completeness.
- **<https://forum.level1techs.com/t/2-gamers-1-gpu-with-hyper-v-gpu-p-gpu-partitioning-finally-made-possible-with-hyperv/172234>**
  — the original Level1Techs writeup for GPU-P, which is what spawned
  much of the consumer DDA / GPU virtualization community work.

If you've gone through this guide and hit a failure not documented here,
the most useful diagnostic is:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-Hyper-V-Worker-Admin' -MaxEvents 20 |
    Where-Object { $_.LevelDisplayName -in 'Error','Warning' } |
    Format-List TimeCreated, Id, LevelDisplayName, Message
```

The Hyper-V Worker Admin log captures every VM start failure with a
specific error code and event ID. Cross-reference with this troubleshooting
guide or look up the event ID on Microsoft Learn.

[← Reversal](09-reversal.md) · [Back to README](../README.md)
