<#
.SYNOPSIS
    Dismounts an NVIDIA GPU + its HDMI audio companion from the Windows
    host and attaches them to a Hyper-V VM via Discrete Device Assignment.

.DESCRIPTION
    Finds the GPU by NVIDIA vendor ID (10DE), disables both functions in
    the OS, dismounts from the host partition, and adds them to the VM.

    The VM must be Off when this runs. The host must be properly prepared
    (see scripts/01-host-prep.ps1 and the ProductType flip in
    docs/04-windows-host-setup.md §4.6).

.PARAMETER VMName
    Name of the VM to attach to. Default: Fedora

.PARAMETER VendorID
    PCI vendor ID for the GPU. NVIDIA = 10DE (default). AMD = 1002.

.PARAMETER WhatIf
    Show what would be done without performing the dismount/attach.

.EXAMPLE
    .\03-attach-gpu.ps1

.EXAMPLE
    .\03-attach-gpu.ps1 -VMName MyLinux -WhatIf

.NOTES
    POINT OF NO RETURN: once the GPU is dismounted, the host can't use
    it for display until you reverse with scripts/04-detach-gpu.ps1.
    Make sure your primary display is on a DIFFERENT GPU first.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $VMName   = "Fedora",
    [string] $VendorID = "10DE"
)

$ErrorActionPreference = 'Stop'

# Verify VM exists and is off
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { throw "VM '$VMName' not found." }
if ($vm.State -ne 'Off') {
    Write-Host "VM is currently $($vm.State). Stopping..." -ForegroundColor Yellow
    if ($PSCmdlet.ShouldProcess($VMName, "Stop-VM -Force")) {
        Stop-VM -Name $VMName -Force
        while ((Get-VM -Name $VMName).State -ne 'Off') { Start-Sleep -Seconds 2 }
    }
}

# Find all PCIe functions belonging to NVIDIA GPU + its audio companion
Write-Host "===== Locating NVIDIA PCIe devices =====" -ForegroundColor Cyan

$nvidiaDevs = Get-PnpDevice -PresentOnly |
    Where-Object { $_.InstanceId -like "PCI\VEN_$VendorID*" }

if (-not $nvidiaDevs) { throw "No NVIDIA PCIe devices found on the host. Is the GPU already attached to another VM?" }

# Pair GPU + audio by shared parent bus
$gpu   = $nvidiaDevs | Where-Object { $_.Class -eq 'Display' } | Select-Object -First 1
if (-not $gpu) { throw "No NVIDIA Display-class device found." }

$gpuPaths = (Get-PnpDeviceProperty -InstanceId $gpu.InstanceId -KeyName DEVPKEY_Device_LocationPaths).Data
$gpuLoc   = ($gpuPaths | Where-Object { $_ -like 'PCIROOT*' } | Select-Object -First 1)
$gpuParent = ($gpuLoc -replace '#PCI\([0-9A-F]+\)$', '')

# Find the audio companion (same parent path)
$audio = $nvidiaDevs | Where-Object {
    $_.Class -eq 'MEDIA' -and (
        ($_ | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_LocationPaths).Data |
            Where-Object { $_ -like "$gpuParent*" }
    )
} | Select-Object -First 1

$devices = @($gpu)
if ($audio) {
    $audPaths = (Get-PnpDeviceProperty -InstanceId $audio.InstanceId -KeyName DEVPKEY_Device_LocationPaths).Data
    $audLoc   = ($audPaths | Where-Object { $_ -like 'PCIROOT*' } | Select-Object -First 1)
    $devices += $audio
} else {
    Write-Host "(No HDMI audio companion found — proceeding with GPU only)" -ForegroundColor Yellow
}

Write-Host "Devices to assign:" -ForegroundColor Green
foreach ($d in $devices) {
    $loc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_LocationPaths).Data |
           Where-Object { $_ -like 'PCIROOT*' } | Select-Object -First 1
    "  {0,-40} {1}" -f $d.FriendlyName, $loc
}

# Confirm assignability
Write-Host "`nAssignability check:" -ForegroundColor Cyan
foreach ($d in $devices) {
    $acs = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_PciDevice_AcsCompatibleUpHierarchy).Data
    $rmrr = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_PciDevice_RequiresReservedMemoryRegion).Data
    "  $($d.FriendlyName): ACS=$acs RMRR=$rmrr"
    if (-not $acs -or $acs -eq 0) {
        Write-Host "    WARNING: ACS is not populated. DDA may fail. See docs/03-bios-configuration.md" -ForegroundColor Yellow
    }
}

# Confirm
if (-not $PSCmdlet.ShouldProcess(($devices.FriendlyName -join ', '), "Dismount from host and assign to '$VMName'")) {
    return
}

# Dismount + assign
Write-Host "`n===== Dismounting from host =====" -ForegroundColor Cyan
foreach ($d in $devices) {
    $loc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_LocationPaths).Data |
           Where-Object { $_ -like 'PCIROOT*' } | Select-Object -First 1

    Write-Host "  Disabling: $($d.FriendlyName)"
    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
    Start-Sleep -Seconds 1

    Write-Host "  Dismounting LocationPath: $loc"
    Dismount-VMHostAssignableDevice -LocationPath $loc -Force
}

Write-Host "`n===== Assigning to '$VMName' =====" -ForegroundColor Cyan
foreach ($d in $devices) {
    $loc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_LocationPaths).Data |
           Where-Object { $_ -like 'PCIROOT*' } | Select-Object -First 1
    Write-Host "  Adding: $loc"
    Add-VMAssignableDevice -VMName $VMName -LocationPath $loc
}

Write-Host "`n===== Verification =====" -ForegroundColor Green
Get-VMAssignableDevice -VMName $VMName | Format-Table LocationPath, InstanceID -AutoSize

Write-Host "===== Done. Starting VM... =====" -ForegroundColor Cyan
Start-VM -Name $VMName
Start-Sleep -Seconds 5
Get-VM -Name $VMName | Format-Table Name, State, CPUUsage, MemoryAssigned, Uptime

Write-Host "If VM is 'Running', success. If VM is 'Off' with error 0xC035001E, see docs/troubleshooting.md §1."
