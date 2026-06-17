# 06 Â· GPU passthrough

[â† VM creation](05-vm-creation.md) Â· [Fedora guest setup â†’](07-fedora-guest-setup.md)

The host is configured, the VM exists. Now we actually transfer the GPU
from the host to the guest.

This chapter has three phases:

1. Identify the GPU's PCIe location path and PnP instance IDs
2. Disable + dismount the GPU (and its HDMI audio companion) from the host
3. Attach to the VM and start

> âš ï¸ **Point of no return**: once the GPU is dismounted, the Windows host
> can't use it for display until you reverse the process. Make sure your
> primary display is on a *different* GPU before continuing.

The automated version is
[`scripts/guide/03-attach-gpu.ps1`](../scripts/guide/03-attach-gpu.ps1).

## 6.1 Find your GPU

NVIDIA GPUs report themselves with PCI vendor ID `10DE` (Realtek 10DE is
not a thing; Realtek's NICs are `10EC` â€” don't get them confused). Find
the GPU and its sibling HDMI audio function:

```powershell
Get-PnpDevice -PresentOnly |
    Where-Object { $_.InstanceId -like "PCI\VEN_10DE*" } |
    ForEach-Object {
        $locPaths = (Get-PnpDeviceProperty -InstanceId $_.InstanceId `
                     -KeyName DEVPKEY_Device_LocationPaths -ErrorAction SilentlyContinue).Data
        [pscustomobject]@{
            Name         = $_.FriendlyName
            Class        = $_.Class
            InstanceId   = $_.InstanceId
            LocationPath = ($locPaths -join "; ")
        }
    } | Format-List
```

Example output for a GTX 1080 Ti:

```
Name         : NVIDIA GeForce GTX 1080 Ti
Class        : Display
InstanceId   : PCI\VEN_10DE&DEV_1B06&SUBSYS_36021462&REV_A1\4&1D81E16&0&0019
LocationPath : PCIROOT(0)#PCI(0301)#PCI(0000); ACPI(_SB_)#ACPI(PCI0)#ACPI(GPP8)#ACPI(VGA_)

Name         : High Definition Audio Controller
Class        : MEDIA
InstanceId   : PCI\VEN_10DE&DEV_10EF&SUBSYS_36021462&REV_A1\4&1D81E16&0&0119
LocationPath : PCIROOT(0)#PCI(0301)#PCI(0001); ACPI(_SB_)#ACPI(PCI0)#ACPI(GPP8)#ACPI(HDAU)
```

**The two values you need** are the `PCIROOT(...)` location paths
(everything before the first `;`):

- **GPU**: `PCIROOT(0)#PCI(0301)#PCI(0000)`
- **Audio**: `PCIROOT(0)#PCI(0301)#PCI(0001)`

The two devices share the same parent (`#PCI(0301)` here) and differ in
the function number (`#PCI(0000)` vs `#PCI(0001)`). That confirms they're
two functions of the same physical PCIe device â€” both must be dismounted
together.

Save these:

```powershell
$gpuId  = 'PCI\VEN_10DE&DEV_1B06&SUBSYS_36021462&REV_A1\4&1D81E16&0&0019'
$audId  = 'PCI\VEN_10DE&DEV_10EF&SUBSYS_36021462&REV_A1\4&1D81E16&0&0119'
$gpuLoc = 'PCIROOT(0)#PCI(0301)#PCI(0000)'
$audLoc = 'PCIROOT(0)#PCI(0301)#PCI(0001)'
```

Adapt to your hardware â€” vendor/device IDs and slot numbers will differ.

## 6.2 DDA assignability check

Before dismounting, confirm the GPU is actually assignable. The
authoritative check is whether `AcsCompatibleUpHierarchy` is populated
(non-empty, non-zero) and `RequiresReservedMemoryRegion` is `False`:

```powershell
foreach ($id in @($gpuId, $audId)) {
    $name = (Get-PnpDevice -InstanceId $id).FriendlyName
    "=== $name ==="
    "  ACS                          : $((Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_PciDevice_AcsCompatibleUpHierarchy').Data)"
    "  RequiresReservedMemoryRegion : $((Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_PciDevice_RequiresReservedMemoryRegion').Data)"
    "  InterruptSupport             : $((Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_PciDevice_InterruptSupport').Data)"
}
```

You want:

| Property | Required value |
|---|---|
| `AcsCompatibleUpHierarchy` | Any non-empty number (typically `3`) |
| `RequiresReservedMemoryRegion` | `False` |
| `InterruptSupport` | `3` (MSI + MSI-X) |

If `AcsCompatibleUpHierarchy` is **empty**, your BIOS hasn't exposed ACS.
Go back to [Â§03 BIOS configuration](03-bios-configuration.md) â€” DDA will
not work cleanly without this.

## 6.3 Dismount from host

This is the irreversible-within-the-session step. The GPU and its audio
function get disabled at the OS level, then dismounted at the hypervisor
level:

```powershell
# 1. Disable both functions in the OS
Disable-PnpDevice -InstanceId $gpuId -Confirm:$false
Disable-PnpDevice -InstanceId $audId -Confirm:$false
Start-Sleep -Seconds 3

# 2. Dismount them from the host partition (-Force because consumer GPUs
#    don't ship a vendor mitigation driver)
Dismount-VMHostAssignableDevice -LocationPath $gpuLoc -Force
Dismount-VMHostAssignableDevice -LocationPath $audLoc -Force
```

Verify the host no longer owns them:

```powershell
Get-VMHostAssignableDevice | Format-Table InstanceID, LocationPath -AutoSize
# Should list BOTH devices (their InstanceID changes from PCI\... to PCIP\...)
```

The change from `PCI\` to `PCIP\` in the instance ID is normal â€” `PCIP`
stands for "PCI assigned to partition," the parked state.

## 6.4 Attach to the VM

Make sure the VM is **stopped** first:

```powershell
$vm = "Fedora"
if ((Get-VM -Name $vm).State -ne 'Off') {
    Stop-VM -Name $vm -Force
    while ((Get-VM -Name $vm).State -ne 'Off') { Start-Sleep -Seconds 2 }
}
```

Then attach both devices:

```powershell
Add-VMAssignableDevice -VMName $vm -LocationPath $gpuLoc
Add-VMAssignableDevice -VMName $vm -LocationPath $audLoc

Get-VMAssignableDevice -VMName $vm | Format-Table LocationPath, InstanceID -AutoSize
```

> **Common naming gotcha**: the cmdlet is `Add-VMAssignableDevice` â€”
> "Assignable", not "Assigned". Several Microsoft community pages, blog
> posts, and even AI assistants get this wrong.

## 6.5 First boot with GPU

Start the VM:

```powershell
Start-VM -Name $vm
Start-Sleep -Seconds 5
Get-VM -Name $vm | Format-Table Name, State, CPUUsage, MemoryAssigned, Uptime
```

### If the VM starts (success path)

If you see `State: Running` with CPU activity, **DDA is working**. Skip to
Â§6.6 to verify the device is visible inside the guest.

### If the VM fails with `0xC035001E`

You'll see:

```
'Fedora' failed to start.
Virtual Pci Express Port (...): Failed to Power on with Error
'A hypervisor feature is not available to the user'. (0xC035001E).
```

This is the SKU gate. The Windows host hasn't been properly unlocked for
DDA. Check, in order:

1. **`ProductType` flip**: was the WinRE flip from
   [Â§4.6](04-windows-host-setup.md#46-the-productype-flip--this-is-the-dda-unlock)
   completed?
2. **`hypervisoriommupolicy`**:
   ```powershell
   bcdedit /enum "{current}" | Select-String 'hypervisoriommupolicy'
   # Must show: hypervisoriommupolicy   Enable
   ```
3. **VBS / `LsaIso.exe`**:
   ```powershell
   "LsaIso : $([bool](Get-Process -Name LsaIso -ErrorAction SilentlyContinue))"
   # Should be False
   ```

If everything checks out but the VM still fails, go to
[troubleshooting](troubleshooting.md).

## 6.6 Verify inside the guest

SSH into the guest (use the IP from chapter 05; it may have changed if the
Default Switch issued a new lease):

```powershell
# Find the current IP
(Get-VMNetworkAdapter -VMName Fedora).IPAddresses | Where-Object { $_ -match '^172\.21' }
```

Then SSH in and check `lspci`:

```bash
$ ssh aseem@172.21.42.216
[aseem@fedora ~]$ lspci -nn | grep -iE 'nvidia|10de|vga|3d|display'
48e0:00:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP102 [GeForce GTX 1080 Ti] [10de:1b06] (rev a1)
b860:00:00.0 Audio device [0403]: NVIDIA Corporation GP102 HDMI Audio Controller [10de:10ef] (rev a1)
```

The bus addresses (`48e0:00`, `b860:00`) look unusual â€” that's because
Hyper-V's VPCI projects each assigned device on its own synthetic PCIe
segment, with the segment ID derived from a per-device GUID. Don't be
alarmed; the kernel handles it fine.

Confirm with `dmesg`:

```bash
$ sudo dmesg | grep -iE 'hv_pci|nvidia|nouveau' | head
[    0.865496] hv_vmbus: registering driver hv_pci
[    0.867586] hv_pci 5a5f0867-48e0-4d7f-9442-885aee2d538b: PCI VMBus probing: Using version 0x10004
[    0.870175] hv_pci 5a5f0867-48e0-4d7f-9442-885aee2d538b: PCI host bridge to bus 48e0:00
[    0.880496] pci 48e0:00:00.0: [10de:1b06] type 00 class 0x030000 PCIe Legacy Endpoint
[    3.645313] nouveau 48e0:00:00.0: NVIDIA GP102 (132000a1)
```

`hv_pci` brought the device up over VMBus, and the kernel auto-loaded
**nouveau** (the open-source NVIDIA driver) against it. The card is
working â€” we'll replace nouveau with the proprietary NVIDIA driver in the
next chapter, but for now, **DDA is proven working**.

[â† VM creation](05-vm-creation.md) Â· [Fedora guest setup â†’](07-fedora-guest-setup.md)
