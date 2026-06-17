<#
.SYNOPSIS
    Prepares a Windows 11 host for Hyper-V Discrete Device Assignment (DDA).

.DESCRIPTION
    Performs all the host-side configuration needed to unlock DDA on
    Windows 11 client SKUs (Pro / Enterprise / LTSC).

    This script does NOT do the ProductType flip — that has to be done
    offline from the Windows Recovery Environment. After this script
    finishes and you reboot, you still need to do the WinRE flip manually
    (see docs/04-windows-host-setup.md §4.6).

.PARAMETER SkipBcdBackup
    Skip the BCD export. Useful for repeated runs.

.EXAMPLE
    .\01-host-prep.ps1

.NOTES
    Run from an elevated PowerShell prompt.
    Reboot after completion, then perform the WinRE ProductType flip.
#>

[CmdletBinding()]
param(
    [switch] $SkipBcdBackup
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Sanity
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Must run elevated." }

Write-Host "===== Hyper-V DDA host prep =====" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 0. Back up BCD
# ---------------------------------------------------------------------------
if (-not $SkipBcdBackup) {
    $backupDir = "C:\HyperV"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $bcdBak = "$backupDir\bcd-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "`n[0/8] Backing up BCD to $bcdBak..." -ForegroundColor Yellow
    & bcdedit /export $bcdBak | Out-Null
    Write-Host "      OK"
}

# ---------------------------------------------------------------------------
# 1. Hyper-V feature
# ---------------------------------------------------------------------------
Write-Host "`n[1/8] Hyper-V optional feature..." -ForegroundColor Yellow
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hv.State -ne 'Enabled') {
    Write-Host "      Enabling Microsoft-Hyper-V-All (will require reboot)..."
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
} else {
    Write-Host "      Already enabled"
}

# ---------------------------------------------------------------------------
# 2. Disable VBS / Credential Guard / HVCI
# ---------------------------------------------------------------------------
Write-Host "`n[2/8] Disabling VBS / Credential Guard / HVCI..." -ForegroundColor Yellow

New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
                 -Name LsaCfgFlags -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" `
                 -Name EnableVirtualizationBasedSecurity -Value 0 -PropertyType DWord -Force | Out-Null

New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard" `
                 -Name LsaCfgFlags -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard" `
                 -Name EnableVirtualizationBasedSecurity -Value 0 -PropertyType DWord -Force | Out-Null

New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" `
                 -Name Enabled -Value 0 -PropertyType DWord -Force | Out-Null

& bcdedit /set vsmlaunchtype off | Out-Null
& bcdedit /set "{current}" isolatedcontext No | Out-Null

Write-Host "      OK (effective after reboot)"

# ---------------------------------------------------------------------------
# 3. Disable VMP and WHP
# ---------------------------------------------------------------------------
Write-Host "`n[3/8] Disabling VirtualMachinePlatform + HypervisorPlatform..." -ForegroundColor Yellow
foreach ($feat in 'VirtualMachinePlatform','HypervisorPlatform') {
    $f = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction SilentlyContinue
    if ($f -and $f.State -eq 'Enabled') {
        Disable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart | Out-Null
        Write-Host "      Disabled $feat"
    } else {
        Write-Host "      $feat already disabled / absent"
    }
}

# ---------------------------------------------------------------------------
# 4. Hypervisor: Classic scheduler + IOMMU policy
# ---------------------------------------------------------------------------
Write-Host "`n[4/8] Setting hypervisor scheduler = Classic, IOMMU policy = Enable..." -ForegroundColor Yellow
& bcdedit /set hypervisorlaunchtype Auto | Out-Null
& bcdedit /set hypervisorschedulertype Classic | Out-Null
& bcdedit /set hypervisoriommupolicy Enable | Out-Null
Write-Host "      OK"

# ---------------------------------------------------------------------------
# 5. HyperV policy keys (defense in depth)
# ---------------------------------------------------------------------------
Write-Host "`n[5/8] HyperV policy keys (RequireSecure/SupportedDeviceAssignment = 0)..." -ForegroundColor Yellow
$hvPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV"
New-Item -Path $hvPol -Force | Out-Null
New-ItemProperty -Path $hvPol -Name "RequireSecureDeviceAssignment"    -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $hvPol -Name "RequireSupportedDeviceAssignment" -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host "      OK"

# ---------------------------------------------------------------------------
# 6. Status snapshot
# ---------------------------------------------------------------------------
Write-Host "`n[6/8] Current state (effective values appear after reboot)..." -ForegroundColor Yellow
Write-Host "      BCD:"
& bcdedit /enum '{current}' | Select-String 'hypervisor|vsm|isolatedcontext'

# ---------------------------------------------------------------------------
# 7. Detect UEFI-locked Credential Guard
# ---------------------------------------------------------------------------
Write-Host "`n[7/8] Note: if LsaIso.exe is STILL running after the next reboot," -ForegroundColor Yellow
Write-Host "       your Credential Guard is UEFI-locked. See docs/04-windows-host-setup.md §4.3"
Write-Host "       for the SecConfig.efi removal procedure."

# ---------------------------------------------------------------------------
# 8. ProductType reminder
# ---------------------------------------------------------------------------
Write-Host "`n[8/8] REMINDER: this script does NOT do the ProductType flip." -ForegroundColor Cyan
Write-Host "      That step is the actual DDA unlock and must be done offline"
Write-Host "      from the Windows Recovery Environment. Steps:"
Write-Host ""
Write-Host "      1. Reboot now"
Write-Host "      2. Once back in Windows, verify VBS is OFF:"
Write-Host "         Get-Process LsaIso  # should error - not running"
Write-Host "      3. Shift+Restart, Troubleshoot > Advanced > Command Prompt"
Write-Host "      4. In the recovery prompt:"
Write-Host "         dir D:\Windows\System32\config   # find your Windows drive"
Write-Host "         reg load HKLM\TmpSys D:\Windows\System32\config\SYSTEM"
Write-Host "         reg add `"HKLM\TmpSys\ControlSet001\Control\ProductOptions`" /v ProductType /t REG_SZ /d ServerNT /f"
Write-Host "         reg unload HKLM\TmpSys"
Write-Host "         exit"
Write-Host "      5. Continue to Windows"
Write-Host ""
Write-Host "===== Host prep done. Reboot, then do the ProductType flip. =====" -ForegroundColor Cyan
