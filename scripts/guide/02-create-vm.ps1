<#
.SYNOPSIS
    Creates a Hyper-V VM correctly configured for Discrete Device
    Assignment.

.DESCRIPTION
    Creates a Generation-2 VM with the constraints DDA requires:
    static memory, checkpoints disabled, AutomaticStopAction TurnOff,
    write-combining enabled, MMIO windows sized for a modern GPU,
    and Secure Boot disabled (so an unsigned NVIDIA kmod can load in
    the guest).

.PARAMETER VMName
    Name for the VM. Default: Fedora

.PARAMETER VMPath
    Directory under which Hyper-V will create the VM's config + VHDX.
    Default: C:\HyperV\Fedora

.PARAMETER MemoryGB
    Static memory for the VM. Default: 16

.PARAMETER VCPUs
    Virtual CPU count. Default: 8

.PARAMETER DiskGB
    Maximum VHDX size (dynamic - grows on demand). Default: 256

.PARAMETER ISOPath
    Path to the install ISO. Default: C:\HyperV\ISO\Fedora-Workstation-Live-44-1.7.x86_64.iso

.PARAMETER SwitchName
    vSwitch to connect the VM to. Default: "Default Switch"

.PARAMETER HighMMIO_GB
    High MMIO window size. Default: 33 (sized for an 11 GB GPU; bump up
    for larger cards — rule of thumb is 3x VRAM rounded up).

.EXAMPLE
    .\02-create-vm.ps1

.EXAMPLE
    .\02-create-vm.ps1 -VMName MyLinux -MemoryGB 24 -VCPUs 12 -DiskGB 512
#>

[CmdletBinding()]
param(
    [string] $VMName     = "Fedora",
    [string] $VMPath     = "C:\HyperV\Fedora",
    [int]    $MemoryGB   = 16,
    [int]    $VCPUs      = 8,
    [int]    $DiskGB     = 256,
    [string] $ISOPath    = "C:\HyperV\ISO\Fedora-Workstation-Live-44-1.7.x86_64.iso",
    [string] $SwitchName = "Default Switch",
    [int]    $HighMMIO_GB = 33
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ISOPath)) {
    Write-Host "ISO not found at: $ISOPath" -ForegroundColor Red
    Write-Host "Either place it there or pass -ISOPath."
    return
}

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "VM '$VMName' already exists. Refusing to clobber." -ForegroundColor Red
    Write-Host "Delete it first with: Remove-VM -Name $VMName -Force"
    return
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Write-Host "vSwitch '$SwitchName' not found. Existing switches:" -ForegroundColor Red
    Get-VMSwitch | Format-Table Name, SwitchType
    return
}

New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
$vhd = Join-Path $VMPath "$VMName.vhdx"

Write-Host "===== Creating $VMName (Gen 2, $($MemoryGB)GB / $VCPUs vCPU / $($DiskGB)GB) =====" -ForegroundColor Cyan

# Create VM
New-VM -Name $VMName `
       -Path $VMPath `
       -MemoryStartupBytes ([int64]$MemoryGB * 1GB) `
       -Generation 2 `
       -NewVHDPath $vhd `
       -NewVHDSizeBytes ([int64]$DiskGB * 1GB) `
       -SwitchName $SwitchName | Out-Null

# CPU + static memory
Set-VMProcessor -VMName $VMName -Count $VCPUs
Set-VMMemory    -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ([int64]$MemoryGB * 1GB)

# DDA-required: no checkpoints, no save, write-combining, MMIO sizing
Set-VM -Name $VMName `
       -AutomaticStopAction TurnOff `
       -AutomaticCheckpointsEnabled $false `
       -CheckpointType Disabled `
       -GuestControlledCacheTypes $true `
       -LowMemoryMappedIoSpace 3GB `
       -HighMemoryMappedIoSpace ([int64]$HighMMIO_GB * 1024 * 1MB)

# Secure Boot OFF (Linux + unsigned NVIDIA kmod)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Attach install ISO and boot from it
Add-VMDvdDrive -VMName $VMName -Path $ISOPath
$dvd = Get-VMDvdDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

# Summary
Write-Host "`nVM created:" -ForegroundColor Green
Get-VM -Name $VMName | Format-List Name, State, Generation, ProcessorCount, MemoryStartup, `
                                   AutomaticStopAction, CheckpointType, AutomaticCheckpointsEnabled, `
                                   LowMemoryMappedIoSpace, HighMemoryMappedIoSpace, Path
Get-VMFirmware -VMName $VMName | Format-List SecureBoot, BootOrder

Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  Start-VM -Name $VMName"
Write-Host "  vmconnect.exe `$env:COMPUTERNAME $VMName"
Write-Host ""
Write-Host "Install Fedora interactively, then come back for scripts/03-attach-gpu.ps1"
