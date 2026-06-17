# 04 Â· Windows host setup

[â† BIOS configuration](03-bios-configuration.md) Â· [VM creation â†’](05-vm-creation.md)

This is the critical chapter. The previous chapter got the firmware ready;
this one prepares Windows itself, **including the ProductType flip which is
the actual DDA unlock**.

There are four phases:

1. Install / verify Hyper-V is enabled
2. Disable Virtualization-Based Security (VBS)
3. Configure hypervisor parameters
4. **Flip `ProductType` to `ServerNT` (the DDA unlock)**

Almost all of this is automated by
[`scripts/guide/01-host-prep.ps1`](../scripts/guide/01-host-prep.ps1). This chapter
explains *what* the script does and *why*, so you understand the system
state you're producing.

## 4.1 Install Hyper-V

If Hyper-V isn't already enabled, install it from an elevated PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
# Reboot when prompted
```

Verify:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All | Select-Object FeatureName, State
# Expect: State = Enabled
```

## 4.2 Disable Virtualization-Based Security

VBS, Credential Guard, HVCI, and friends are all forms of "isolated user
mode" features that use Hyper-V to protect kernel-mode secrets. They were
not the actual cause of our DDA error (that's `ProductType`), but they put
the hypervisor in a more restricted mode that complicates things and we
recommend disabling them for DDA work. Disabling them is reversible.

### Registry knobs

```powershell
# Lsa\LsaCfgFlags = 0 explicitly disables Credential Guard
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
                 -Name LsaCfgFlags -Value 0 -PropertyType DWord -Force | Out-Null

# DeviceGuard\EnableVirtualizationBasedSecurity = 0 disables VBS
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" `
                 -Name EnableVirtualizationBasedSecurity -Value 0 -PropertyType DWord -Force | Out-Null

# Policy path - covers default-enablement on Win11 Enterprise
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard" `
                 -Name LsaCfgFlags -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard" `
                 -Name EnableVirtualizationBasedSecurity -Value 0 -PropertyType DWord -Force | Out-Null

# HVCI / Memory Integrity scenario
New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" `
                 -Name Enabled -Value 0 -PropertyType DWord -Force | Out-Null
```

> **Important nuance on Win11 Enterprise**: on Enterprise SKU, the absence
> of `LsaCfgFlags` does *not* mean "off" â€” it means "use the default,"
> which is *on*. Always set `LsaCfgFlags = 0` explicitly. Do not just
> delete the value.

### BCD knobs

```powershell
bcdedit /set vsmlaunchtype off
bcdedit /set "{current}" isolatedcontext No
```

`isolatedcontext Yes` is a flag that tells the OS loader to launch in a
VBS-protected context. It defaults to `Yes` on Windows 11 and overrides
the registry values above unless flipped to `No`.

### Disable VMP and WHP

These two Windows features layer additional hypervisor partitioning that
isn't compatible with the simpler DDA model. **You don't need them unless
you use WSL2, Windows Sandbox, Docker Desktop, VirtualBox 6+, VMware
Workstation 16+, or Android emulators.**

```powershell
Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform   -NoRestart
```

### Hypervisor scheduler

Windows 11 client defaults to the "Root" hypervisor scheduler, which is
designed for WSL2/Sandbox/Application Guard. DDA was designed against the
older "Classic" scheduler. Switch:

```powershell
bcdedit /set hypervisorschedulertype Classic
```

On a single-VM workload this has no measurable performance impact.

### Reboot

All of the above need a full reboot to take effect. Reboot now and verify:

```powershell
$dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
"VBS status        : $($dg.VirtualizationBasedSecurityStatus)  (target: 0)"
"Services running  : $($dg.SecurityServicesRunning -join ',')  (target: 0)"
"LsaIso.exe       : $([bool](Get-Process -Name LsaIso -ErrorAction SilentlyContinue))  (target: False)"
```

If `LsaIso.exe` is still running after this reboot, your Credential Guard
is **UEFI-locked**. This is a Microsoft-by-design behavior on some Windows
11 22H2+ provisioning paths. To remove the UEFI lock, see
[the UEFI-locked Credential Guard removal procedure](#43-uefi-locked-credential-guard-if-applicable).

If `LsaIso.exe` is not running, you're done with the VBS phase. Continue to
Â§4.4.

## 4.3 UEFI-locked Credential Guard (if applicable)

If `LsaIso.exe` persists after the steps in Â§4.2, you have UEFI-locked
Credential Guard. Microsoft ships a signed EFI tool, `SecConfig.efi`, that
can issue the firmware-level "disable" request. The tool exists at
`C:\Windows\System32\SecConfig.efi`.

### Procedure

1. Copy `SecConfig.efi` to your EFI System Partition:

   ```powershell
   # Find a free drive letter
   $free = 67..90 | ForEach-Object { [char]$_ } |
       Where-Object { $_ -notin ((Get-Volume | Where-Object DriveLetter).DriveLetter) } |
       Select-Object -First 1

   mountvol "$free`:" /s
   Copy-Item "$env:windir\System32\SecConfig.efi" "$free`:\EFI\Microsoft\Boot\SecConfig.efi" -Force

   # Create a one-shot boot entry
   $guid = "{0cb3b571-2f2e-4343-a879-d86a476d7215}"
   bcdedit /create $guid /d "Disable VBS CredGuard" /application osloader
   bcdedit /set $guid path "\EFI\Microsoft\Boot\SecConfig.efi"
   bcdedit /set "{bootmgr}" bootsequence $guid
   bcdedit /set $guid loadoptions "DISABLE-LSA-ISO,DISABLE-VBS"
   bcdedit /set $guid device "partition=$free`:"

   mountvol "$free`:" /d
   ```

2. Reboot.

3. The machine will boot into `SecConfig.efi` and present a **firmware
   prompt** asking you to confirm the disable (this physical-presence
   check is the whole point â€” it can't be faked by software). Press the
   key it shows you to confirm.

4. The machine continues to Windows. `LsaIso.exe` should now be gone.

5. Verify:

   ```powershell
   "LsaIso : $([bool](Get-Process -Name LsaIso -ErrorAction SilentlyContinue))"
   # Expect: False
   ```

## 4.4 Hypervisor IOMMU policy

The Hyper-V hypervisor has a BCD setting that controls whether it enables
IOMMU functionality on launch. **DDA requires this be `Enable`.**

```powershell
bcdedit /set hypervisoriommupolicy Enable
```

Verify:

```powershell
bcdedit /enum "{current}" | Select-String 'hypervisoriommupolicy'
# Expect: hypervisoriommupolicy   Enable
```

This is one of the most commonly-overlooked settings. Without it, the
hypervisor doesn't claim the IOMMU, and the DDA Virtual PCIe Port
initialization fails.

## 4.5 HyperV policy keys (defense-in-depth)

These two policy keys tell Hyper-V on client SKUs to allow non-secure /
non-supported device assignment. They may or may not be honored on all
builds â€” set them anyway:

```powershell
$hvPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV"
New-Item -Path $hvPol -Force | Out-Null
New-ItemProperty -Path $hvPol -Name "RequireSecureDeviceAssignment"    -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $hvPol -Name "RequireSupportedDeviceAssignment" -Value 0 -PropertyType DWord -Force | Out-Null
```

## 4.6 The ProductType flip â€” THIS IS THE DDA UNLOCK

Everything above prepares the environment. **This is the one step that
actually lets DDA work on Windows 11 client.**

The Hyper-V hypervisor reads
`HKLM\SYSTEM\ControlSet001\Control\ProductOptions\ProductType` at boot.
Desktop Windows = `WinNT`. Server Windows = `ServerNT`. The DDA feature is
exposed to the root partition **only** when this reads `ServerNT`.

`ProductType` is protected from runtime writes â€” you cannot change it
while Windows is running. You must edit it offline, from the Recovery
Environment.

### Procedure

**Step 1.** Back up your BCD before doing anything boot-related:

```powershell
$backup = "C:\HyperV\bcd-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
bcdedit /export $backup
"Backed up to: $backup"
```

**Step 2.** Confirm what we're going to change:

```powershell
"ControlSet001\Control\ProductOptions\ProductType : $((Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Control\ProductOptions').ProductType)"
# Expect: WinNT
```

**Step 3.** Boot into Recovery Environment:

- **Start menu â†’ Power â†’ hold `Shift` while clicking Restart**, OR
- Settings â†’ System â†’ Recovery â†’ Advanced startup â†’ Restart now.

**Step 4.** Navigate: **Troubleshoot â†’ Advanced options â†’ Command Prompt**.

**Step 5.** In the recovery command prompt, find your Windows drive. In
WinRE the drive letters often shift, so check a couple of candidates:

```cmd
dir C:\Windows\System32\config
dir D:\Windows\System32\config
```

Use whichever shows the `SYSTEM` file. Call that letter `<WINDRIVE>`.

**Step 6.** Load the offline SYSTEM hive, flip the value, unload:

```cmd
reg load HKLM\TmpSys <WINDRIVE>:\Windows\System32\config\SYSTEM

reg query "HKLM\TmpSys\ControlSet001\Control\ProductOptions" /v ProductType
:: Expected: WinNT

reg add "HKLM\TmpSys\ControlSet001\Control\ProductOptions" /v ProductType /t REG_SZ /d ServerNT /f

reg query "HKLM\TmpSys\ControlSet001\Control\ProductOptions" /v ProductType
:: Expected: ServerNT

reg unload HKLM\TmpSys
exit
```

**Step 7.** Choose **Continue / Exit and continue to Windows 11**. Windows
will boot with the modified registry.

### What you'll observe

After this reboot, the Windows desktop looks essentially the same, but
some cosmetic details flip to server-style behavior:

- The shutdown menu may show a "Why are you shutting down?" prompt
- Night Light disappears from Display settings
- A few other small desktop features disappear

**Windows activation, licensing status, edition, and Windows Update
eligibility are unaffected** in observed behavior. The licensing service
rewrites `ProductType` back to `WinNT` at runtime after boot, but
crucially, the hypervisor has already read it and locked in the
ServerNT-mode DDA capability for this boot.

### Verification

After the reboot:

```powershell
# ProductType reverts to WinNT at runtime - that's normal and expected
(Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Control\ProductOptions').ProductType
# May read either ServerNT or WinNT - irrelevant to DDA at this point

# What matters: is the hypervisor still happy?
Get-VMHost | Select-Object IovSupport
# IovSupport: True

# Quick sanity that the VM start path will work - need an existing VM
# (we'll create one in chapter 05)
```

The proof DDA is now unlocked comes when we actually start a VM with a
GPU attached â€” covered in [chapter 06](06-gpu-passthrough.md).

### Persistence across reboots

The `ProductType = ServerNT` value, written into the offline SYSTEM hive,
**persists across all subsequent boots** in observed behavior on Windows
11 Enterprise 25H2. The licensing service's runtime "correction" to
`WinNT` happens after the hypervisor has booted and is now irrelevant.

You only need to do the WinRE flip **once**. Subsequent boots Just Work.

## 4.7 Pulling it all together

The full host-prep script lives at
[`scripts/guide/01-host-prep.ps1`](../scripts/guide/01-host-prep.ps1). Run it in an
elevated PowerShell, reboot when it prompts you, then do the WinRE
ProductType flip from Â§4.6.

After the WinRE step and one more reboot, your host is fully ready for
the VM creation phase.

[â† BIOS configuration](03-bios-configuration.md) Â· [VM creation â†’](05-vm-creation.md)
