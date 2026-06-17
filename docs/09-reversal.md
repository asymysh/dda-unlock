# 09 Â· Reversal

[â† Verification](08-verification.md) Â· [Troubleshooting â†’](troubleshooting.md)

How to put things back. Everything in this guide is reversible at three
granularities:

1. **Return the GPU to the host** â€” keep the VM, keep DDA capability, just
   re-mount the device on Windows.
2. **Remove the VM** â€” delete the VM and its files.
3. **Fully revert the host** â€” undo VBS-off, scheduler change, ProductType,
   etc., returning the machine to "normal" Windows 11 client behavior.

You can do (1) without (2) or (3), and (2) without (3). (3) is the full
factory reset.

## 9.1 Return the GPU to the host

Use this when you want to reclaim the GPU for Windows (e.g., to do GPU-P,
WSL2 with GPU compute, or just video encoding with the GPU's NVENC).

The full automation is in
[`scripts/guide/04-detach-gpu.ps1`](../scripts/guide/04-detach-gpu.ps1).

```powershell
$vm     = "Fedora"
$gpuLoc = "PCIROOT(0)#PCI(0301)#PCI(0000)"
$audLoc = "PCIROOT(0)#PCI(0301)#PCI(0001)"
$gpuId  = 'PCI\VEN_10DE&DEV_1B06&SUBSYS_36021462&REV_A1\4&1D81E16&0&0019'
$audId  = 'PCI\VEN_10DE&DEV_10EF&SUBSYS_36021462&REV_A1\4&1D81E16&0&0119'

# 1. Stop the VM (graceful shutdown via integration services)
if ((Get-VM -Name $vm).State -ne 'Off') {
    Stop-VM -Name $vm -Force
    while ((Get-VM -Name $vm).State -ne 'Off') { Start-Sleep -Seconds 2 }
}

# 2. Remove assignment
Remove-VMAssignableDevice -VMName $vm -LocationPath $gpuLoc
Remove-VMAssignableDevice -VMName $vm -LocationPath $audLoc

# 3. Re-mount on the host
Mount-VMHostAssignableDevice -LocationPath $gpuLoc
Mount-VMHostAssignableDevice -LocationPath $audLoc

# 4. Re-enable in Device Manager
Enable-PnpDevice -InstanceId $gpuId -Confirm:$false
Enable-PnpDevice -InstanceId $audId -Confirm:$false

# 5. Verify
Get-PnpDevice -InstanceId $gpuId | Format-Table FriendlyName, Status, Class
# Expected: Status: OK
```

After this, the host sees the GPU normally. Windows may need a moment to
auto-install / re-bind the NVIDIA driver. Open Device Manager to confirm
no yellow exclamation marks.

> **If anything won't enumerate**, reboot the Windows host. The PCIe state
> machine for "re-attach after dismount" isn't always perfectly clean and
> a reboot resolves it.

## 9.2 Delete the VM

```powershell
$vm = "Fedora"
$path = (Get-VM -Name $vm).Path

# Stop if running, detach any assigned devices first (see Â§9.1)
if ((Get-VM -Name $vm).State -ne 'Off') { Stop-VM -Name $vm -Force }
foreach ($dev in (Get-VMAssignableDevice -VMName $vm)) {
    Remove-VMAssignableDevice -VMName $vm -LocationPath $dev.LocationPath
    Mount-VMHostAssignableDevice -LocationPath $dev.LocationPath
}

# Delete the VM (Hyper-V config only â€” VHDX and ISO stay)
Remove-VM -Name $vm -Force

# Optionally delete VHDX and folder
Remove-Item -LiteralPath $path -Recurse -Force
```

## 9.3 Revert Windows host (full)

The full host revert undoes everything we did in
[chapter 04](04-windows-host-setup.md). Do this if you no longer need DDA
and want the Windows machine back to its default Windows 11 Enterprise
posture.

### 9.3.1 Revert ProductType to `WinNT`

Same procedure as the original flip, with the opposite value. Boot into
WinRE, open Command Prompt, find your Windows drive, then:

```cmd
reg load HKLM\TmpSys D:\Windows\System32\config\SYSTEM
reg add "HKLM\TmpSys\ControlSet001\Control\ProductOptions" /v ProductType /t REG_SZ /d WinNT /f
reg unload HKLM\TmpSys
exit
```

Continue to Windows.

> Note: on most observed installs the runtime licensing service has
> already rewritten `ProductType` to `WinNT` at every boot anyway, so the
> stored value may already be `WinNT`. The WinRE flip back is belt-and-
> suspenders.

### 9.3.2 Re-enable VBS / Credential Guard

```powershell
# Registry: delete the explicit disable values (default behavior re-enables CG on Enterprise)
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LsaCfgFlags -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name EnableVirtualizationBasedSecurity -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard" -Name LsaCfgFlags -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard" -Name EnableVirtualizationBasedSecurity -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name Enabled -ErrorAction SilentlyContinue

# BCD: restore defaults
bcdedit /set vsmlaunchtype Auto
bcdedit /set "{current}" isolatedcontext Yes
```

### 9.3.3 Restore default hypervisor scheduler

```powershell
bcdedit /deletevalue hypervisorschedulertype
# Or set it back to Root explicitly:
# bcdedit /set hypervisorschedulertype Root
```

### 9.3.4 Re-enable VMP and WHP (if you need WSL2 / Docker Desktop / VirtualBox)

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform   -NoRestart
```

### 9.3.5 Remove HyperV policy keys

```powershell
$hvPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV"
if (Test-Path $hvPol) {
    Remove-ItemProperty -Path $hvPol -Name "RequireSecureDeviceAssignment"    -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $hvPol -Name "RequireSupportedDeviceAssignment" -ErrorAction SilentlyContinue
}
```

### 9.3.6 Keep `hypervisoriommupolicy = Enable` (harmless)

This BCD setting doesn't hurt anything, even without DDA. You can leave it
on; it just tells the hypervisor to use the IOMMU when it's available.

If you really want to undo it:

```powershell
bcdedit /deletevalue hypervisoriommupolicy
```

### 9.3.7 Reboot

```powershell
Restart-Computer
```

After this reboot:

- `LsaIso.exe` should be back (Credential Guard re-enabled by default)
- `VirtualizationBasedSecurityStatus` should be `2` again
- WSL2 / Docker Desktop / VirtualBox should work again
- DDA will once again fail with `0xC035001E` if you try it (Windows 11
  client SKU restriction reapplied)

## 9.4 Restore BCD from backup

If your boot configuration ever gets into a state you can't easily fix
with `bcdedit`, you can restore from the backup the host-prep script took:

```powershell
# Find the backup
Get-ChildItem C:\HyperV\bcd-backup-* | Sort-Object LastWriteTime -Descending

# Restore (from elevated PowerShell)
bcdedit /import C:\HyperV\bcd-backup-20260615-062840
```

If you can't boot at all, do it from the Recovery Environment instead:

```cmd
:: From WinRE Command Prompt
bcdedit /import D:\HyperV\bcd-backup-20260615-062840
```

(Drive letter depends on your WinRE environment.)

## 9.5 BIOS reverts

If you want to undo the BIOS changes from [Â§03](03-bios-configuration.md):

- ACS Enable â†’ set back to `Auto` or `Disabled`
- PCIe ARI Support â†’ set back to your previous value
- (Leave SVM, IOMMU, and Above 4G Decoding on â€” they're broadly useful)

A safer alternative: use the BIOS's "Reset to defaults" option, then
re-enable only SVM and IOMMU.

[â† Verification](08-verification.md) Â· [Troubleshooting â†’](troubleshooting.md)
