<#
.SYNOPSIS
    Reverses scripts/03-attach-gpu.ps1: detaches the GPU from the VM and
    returns it to the Windows host.

.DESCRIPTION
    Stops the VM, removes all assigned devices, re-mounts them on the
    host partition, and re-enables them in Device Manager.

.PARAMETER VMName
    The VM to detach from. Default: Fedora

.PARAMETER LeaveOff
    Don't restart the VM after detach.

.EXAMPLE
    .\04-detach-gpu.ps1

.EXAMPLE
    .\04-detach-gpu.ps1 -VMName MyLinux -LeaveOff
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $VMName = "Fedora",
    [switch] $LeaveOff
)

$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { throw "VM '$VMName' not found." }

# 1. Stop VM
if ($vm.State -ne 'Off') {
    Write-Host "Stopping $VMName (graceful)..." -ForegroundColor Yellow
    if ($PSCmdlet.ShouldProcess($VMName, "Stop-VM -Force")) {
        Stop-VM -Name $VMName -Force
        while ((Get-VM -Name $VMName).State -ne 'Off') { Start-Sleep -Seconds 2 }
    }
}

# 2. Enumerate assigned devices
$assigned = @(Get-VMAssignableDevice -VMName $VMName)
if (-not $assigned) {
    Write-Host "No devices assigned to $VMName. Nothing to do." -ForegroundColor Green
    return
}

Write-Host "Devices currently assigned to ${VMName}:" -ForegroundColor Cyan
$assigned | Format-Table LocationPath, InstanceID -AutoSize

# 3. Remove from VM
Write-Host "===== Removing assignment =====" -ForegroundColor Cyan
foreach ($d in $assigned) {
    Write-Host "  Remove-VMAssignableDevice  $($d.LocationPath)"
    Remove-VMAssignableDevice -VMName $VMName -LocationPath $d.LocationPath
}

# 4. Mount back on host
Write-Host "`n===== Mounting back on host =====" -ForegroundColor Cyan
foreach ($d in $assigned) {
    Write-Host "  Mount-VMHostAssignableDevice $($d.LocationPath)"
    Mount-VMHostAssignableDevice -LocationPath $d.LocationPath
}

# 5. Re-enable in Device Manager
Start-Sleep -Seconds 2
Write-Host "`n===== Re-enabling devices on host =====" -ForegroundColor Cyan
foreach ($d in $assigned) {
    # The InstanceID has "PCIP\..." while parked; once mounted it returns to "PCI\..."
    $pciInstance = $d.InstanceID -replace '^PCIP\\', 'PCI\'
    $dev = Get-PnpDevice -InstanceId $pciInstance -ErrorAction SilentlyContinue
    if ($dev) {
        if ($dev.Status -eq 'Error' -or $dev.Status -eq 'Unknown') {
            Write-Host "  Enable-PnpDevice $($dev.FriendlyName)"
            Enable-PnpDevice -InstanceId $pciInstance -Confirm:$false
        } else {
            Write-Host "  $($dev.FriendlyName) status: $($dev.Status) (no action)"
        }
    } else {
        Write-Host "  Could not find PnP device $pciInstance — host may need a reboot to fully re-enumerate" -ForegroundColor Yellow
    }
}

Write-Host "`n===== Post-detach state =====" -ForegroundColor Green
Get-VMHostAssignableDevice | Format-Table LocationPath, InstanceID -AutoSize
Get-PnpDevice -Class Display -PresentOnly | Format-Table FriendlyName, Status

# 6. Optionally restart VM (without the GPU)
if (-not $LeaveOff) {
    Write-Host "`nStarting $VMName (without GPU)..." -ForegroundColor Cyan
    Start-VM -Name $VMName
    Start-Sleep -Seconds 3
    Get-VM -Name $VMName | Format-Table Name, State, Uptime
}

Write-Host "Done. If a device shows Status: Error, reboot the host." -ForegroundColor Cyan
