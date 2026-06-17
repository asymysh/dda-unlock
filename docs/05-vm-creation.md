# 05 Â· VM creation

[â† Windows host setup](04-windows-host-setup.md) Â· [GPU passthrough â†’](06-gpu-passthrough.md)

This chapter creates the Fedora VM with all the constraints DDA requires.
A DDA-compatible VM has a specific set of configuration requirements that
differ from a "normal" Hyper-V VM. Get any of them wrong and the VM will
either refuse to start or refuse to accept the assigned device.

The full automation is in
[`scripts/guide/02-create-vm.ps1`](../scripts/guide/02-create-vm.ps1). This chapter
documents *why* each setting is the way it is.

## 5.1 Layout

We use a clean directory structure under `C:\HyperV`:

```
C:\HyperV\
â”œâ”€â”€ ISO\
â”‚   â””â”€â”€ Fedora-Workstation-Live-44-1.7.x86_64.iso
â””â”€â”€ Fedora\
    â””â”€â”€ Fedora\              â† auto-created by Hyper-V
        â”œâ”€â”€ Virtual Machines\
        â”‚   â””â”€â”€ ...vmgs
        â””â”€â”€ Fedora.vhdx
```

Create it:

```powershell
New-Item -ItemType Directory -Path "C:\HyperV\ISO" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\HyperV\Fedora" -Force | Out-Null
```

## 5.2 Download Fedora

Get the latest Fedora Workstation ISO and verify the checksum:

```powershell
$base = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso"
$iso  = "Fedora-Workstation-Live-44-1.7.x86_64.iso"
$dst  = "C:\HyperV\ISO\$iso"

# Download (curl handles HTTPS redirects to the chosen mirror)
& curl.exe -L --retry 5 --retry-delay 5 -C - -o $dst "$base/$iso"

# Verify
$expectedSum  = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/Fedora-Workstation-44-1.7-x86_64-CHECKSUM"
Invoke-WebRequest -Uri $expectedSum -OutFile "$dst.CHECKSUM" -UseBasicParsing
$expected = (Get-Content "$dst.CHECKSUM" | Select-String $iso | Select-Object -First 1) -replace '.*= '
$got      = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
"Expected : $($expected.ToLower())"
"Got      : $got"
"Match    : $($got -eq $expected.ToLower())"
```

If the download stalls or the chosen mirror dies (this happens â€” Fedora's
redirector sometimes picks a slow mirror), kill curl and try a stable
mirror directly:

```powershell
& curl.exe -L --retry 3 -C - -o $dst "https://mirrors.kernel.org/fedora/releases/44/Workstation/x86_64/iso/$iso"
```

If you already have the ISO from elsewhere, just put it at
`C:\HyperV\ISO\` with the matching filename and verify the checksum.

## 5.3 Create the VM

The constraints DDA imposes on the VM configuration are:

| Constraint | Setting | Why |
|---|---|---|
| Generation 2 | `-Generation 2` | UEFI, required for modern PCIe devices |
| Static memory only | `DynamicMemoryEnabled = $false` | Dynamic memory balloons can't co-exist with passed-through DMA |
| No checkpoints | `CheckpointType = Disabled` and `AutomaticCheckpointsEnabled = $false` | Checkpoints can't snapshot a passed-through device |
| AutomaticStopAction = TurnOff (or ShutDown) | `-AutomaticStopAction TurnOff` | "Save" is incompatible with passed-through devices |
| Write-Combining for the assigned device | `-GuestControlledCacheTypes $true` | The GPU uses write-combined memory regions; the guest needs to control cache types |
| Low MMIO window | `-LowMemoryMappedIoSpace 3GB` | Where the GPU's 32-bit BARs land |
| High MMIO window | `-HighMemoryMappedIoSpace 33280MB` (32.5 GB) | The 1080 Ti's 11 GB VRAM + headroom for >32 GB region |
| Secure Boot **OFF** for Linux | `-EnableSecureBoot Off` | Otherwise the unsigned NVIDIA out-of-tree kmod can't load in the guest |

PowerShell:

```powershell
$vm     = "Fedora"
$path   = "C:\HyperV\Fedora"
$vhd    = "$path\Fedora.vhdx"
$iso    = "C:\HyperV\ISO\Fedora-Workstation-Live-44-1.7.x86_64.iso"
$switch = "Default Switch"   # NAT'd switch built into Hyper-V; change if you want bridged

# Create the VM (Gen 2, 16 GB RAM, 256 GB dynamic VHDX)
New-VM -Name $vm `
       -Path $path `
       -MemoryStartupBytes 16GB `
       -Generation 2 `
       -NewVHDPath $vhd `
       -NewVHDSizeBytes 256GB `
       -SwitchName $switch

# CPU + memory
Set-VMProcessor -VMName $vm -Count 8
Set-VMMemory    -VMName $vm -DynamicMemoryEnabled $false -StartupBytes 16GB

# DDA-required: no checkpoints, no save, write-combining, MMIO sizing
Set-VM -Name $vm `
       -AutomaticStopAction TurnOff `
       -AutomaticCheckpointsEnabled $false `
       -CheckpointType Disabled `
       -GuestControlledCacheTypes $true `
       -LowMemoryMappedIoSpace 3GB `
       -HighMemoryMappedIoSpace 33280MB

# Secure Boot OFF (Linux + unsigned NVIDIA kmod)
Set-VMFirmware -VMName $vm -EnableSecureBoot Off

# Attach install ISO and boot from it
Add-VMDvdDrive -VMName $vm -Path $iso
$dvd = Get-VMDvdDrive -VMName $vm
Set-VMFirmware -VMName $vm -FirstBootDevice $dvd
```

Verify:

```powershell
Get-VM -Name $vm | Format-List Name, Generation, MemoryStartup, ProcessorCount, `
                               AutomaticStopAction, CheckpointType, AutomaticCheckpointsEnabled, `
                               LowMemoryMappedIoSpace, HighMemoryMappedIoSpace
Get-VMFirmware -VMName $vm | Format-List SecureBoot, BootOrder
```

## 5.4 MMIO sizing â€” the detail that often gets wrong

The MMIO settings are the most frequently misconfigured aspect of DDA
because the official documentation gives values that aren't quite right
for modern GPUs:

- **`LowMemoryMappedIoSpace`** is the 32-bit MMIO window for legacy BARs.
  3 GB is a safe default.
- **`HighMemoryMappedIoSpace`** is the >32-bit window. The default of 512
  MB is **far too small** for any modern GPU. Even a 6 GB card needs ~8 GB
  here; the 1080 Ti's 11 GB needs ~32 GB.

Rule of thumb: **set `HighMemoryMappedIoSpace` to at least 3Ã— your GPU's
VRAM, rounded up**. For:

- 6 GB GPU â†’ 18 GB high MMIO (round up to 24 GB)
- 8 GB GPU â†’ 24 GB high MMIO
- 11 GB GPU (1080 Ti) â†’ 33 GB
- 12 GB GPU â†’ 36 GB
- 24 GB GPU â†’ 72 GB

If you under-size the high MMIO window, the VM will start but the GPU
will fail to enumerate with error -1 in `dmesg`, or the VPCI port itself
will fail to power on.

## 5.5 Install Fedora interactively

Start the VM and connect via Hyper-V Manager / VMConnect:

```powershell
Start-VM -Name "Fedora"
Start-Process vmconnect.exe -ArgumentList "$env:COMPUTERNAME","Fedora"
```

The Fedora live ISO will boot. Walk through the installer:

1. Pick **Start Fedora-Workstation-Live 44** at the GRUB menu (or wait).
2. Wait for the GNOME live desktop.
3. Click **Install Fedora...**.
4. Storage: pick the whole 256 GB disk, automatic partitioning (Btrfs is fine).
5. Set timezone, create your user account (we use `aseem`), set a password.
6. Begin Installation (~5-10 min).
7. Reboot from the installer when done.
8. Finish the GNOME first-run wizard.

> **Note on the install user**: subsequent chapters assume the username is
> `aseem`. Substitute your own everywhere.

## 5.6 Post-install: update + SSH

In the Fedora terminal, run:

```bash
sudo dnf upgrade --refresh -y
sudo dnf install -y openssh-server
sudo systemctl enable --now sshd
ip -4 addr show | grep -E 'inet ' | grep -v 127.0.0.1
```

Note the IP â€” it'll be in the `172.21.x.x` range from the Hyper-V Default
Switch. We'll need it in the next chapter.

Reboot the VM once so the latest kernel is loaded:

```bash
sudo reboot
```

Verify the VM came back up and you can SSH in from the Windows host:

```powershell
ssh aseem@<vm-ip>
```

## 5.7 Configure SSH key + autologin (optional but recommended)

To avoid typing passwords for every subsequent command, set up SSH key
authentication and GDM autologin. From the Windows host:

```powershell
# Generate a key if you don't have one
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519.pub")) {
    & ssh-keygen -t ed25519 -N '""' -f "$env:USERPROFILE\.ssh\id_ed25519" -C "win-host->fedora-vm" -q
}

# Push it (one-time password use; uses Posh-SSH from the prep script)
$ip = "<vm-ip>"
$pubKey = (Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw).Trim()
ssh aseem@$ip "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

GDM autologin (inside the VM):

```bash
sudo tee /etc/gdm/custom.conf >/dev/null <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=aseem

[security]

[xdmcp]

[chooser]

[debug]
EOF
```

These are all repeatable by the guest-side script in
[`scripts/guide/06-guest-install-nvidia.sh`](../scripts/guide/06-guest-install-nvidia.sh).

## 5.8 Pre-flight before GPU attach

Before we attach the GPU, the VM should be:

- Created (Gen 2, Secure Boot off)
- Fedora 44 installed and updated
- SSH reachable
- Static-memory, no checkpoints, AutomaticStopAction = TurnOff
- MMIO windows: low 3 GB, high 33 GB
- Write-combining enabled

Quick check:

```powershell
$vm = "Fedora"
Get-VM -Name $vm | Format-List `
    Name, State, Generation, ProcessorCount, MemoryStartup, DynamicMemoryEnabled, `
    AutomaticStopAction, CheckpointType, AutomaticCheckpointsEnabled, `
    LowMemoryMappedIoSpace, HighMemoryMappedIoSpace
(Get-VM -Name $vm).GuestControlledCacheTypes
Get-VMFirmware -VMName $vm | Format-List SecureBoot
```

If anything's off, fix it before continuing. The GPU attach in
[chapter 06](06-gpu-passthrough.md) assumes a clean DDA-ready VM.

[â† Windows host setup](04-windows-host-setup.md) Â· [GPU passthrough â†’](06-gpu-passthrough.md)
