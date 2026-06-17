<#
.SYNOPSIS
    End-to-end health check for the DDA setup. Verifies host state,
    VM state, and (optionally) guest state.

.PARAMETER VMName
    Name of the VM. Default: Fedora

.PARAMETER GuestUser
    SSH username for the guest. Default: aseem

.PARAMETER GuestIP
    Override the guest IP (otherwise auto-detected from VM integration
    services).

.PARAMETER SkipGuestCheck
    Don't try to SSH into the guest.

.EXAMPLE
    .\05-health-check.ps1

.EXAMPLE
    .\05-health-check.ps1 -VMName MyLinux -GuestUser myuser -GuestIP 172.21.42.50
#>

[CmdletBinding()]
param(
    [string] $VMName   = "Fedora",
    [string] $GuestUser = "aseem",
    [string] $GuestIP   = $null,
    [switch] $SkipGuestCheck
)

$ErrorActionPreference = 'Continue'

function H($t) { Write-Host "`n========== $t ==========" -ForegroundColor Cyan }
function OK($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function BAD($t)  { Write-Host "  [BAD]  $t" -ForegroundColor Red }
function INFO($t) { Write-Host "  [INFO] $t" -ForegroundColor Yellow }

# ---------- Host ----------
H "Host: hypervisor and VBS state"

$dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
$lsaiso = [bool](Get-Process -Name LsaIso -ErrorAction SilentlyContinue)
if ($lsaiso) { BAD "LsaIso.exe is running — Credential Guard active (DDA may fail with 0xC035001E)" }
else         { OK  "LsaIso.exe not running — Credential Guard inactive" }
INFO "VBS status: $($dg.VirtualizationBasedSecurityStatus) (0 = off, 2 = running)"

$bcd = (& bcdedit /enum '{current}') -join "`n"
foreach ($pat in 'hypervisorlaunchtype.*Auto','hypervisorschedulertype.*Classic','hypervisoriommupolicy.*Enable','vsmlaunchtype.*Off') {
    if ($bcd -match $pat) { OK "BCD: $pat" } else { BAD "BCD missing: $pat" }
}

H "Host: Hyper-V"
$iov = Get-VMHost | Select-Object IovSupport, IovSupportReasons
if ($iov.IovSupport) { OK "IovSupport: True" }
else                 { BAD "IovSupport: False — $($iov.IovSupportReasons -join '; ')" }

# ---------- VM ----------
H "VM: $VMName"

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { BAD "VM not found"; return }

OK "Found, State: $($vm.State)"
INFO "Generation: $($vm.Generation), Memory: $([math]::Round($vm.MemoryStartup/1GB,1))GB, vCPU: $($vm.ProcessorCount)"
if (-not $vm.DynamicMemoryEnabled)              { OK "Static memory" } else { BAD "Dynamic memory enabled (DDA needs static)" }
if ($vm.CheckpointType -eq 'Disabled')          { OK "Checkpoints disabled" } else { BAD "Checkpoints not disabled: $($vm.CheckpointType)" }
if (-not $vm.AutomaticCheckpointsEnabled)       { OK "Automatic checkpoints disabled" } else { BAD "Automatic checkpoints still enabled" }
if ($vm.AutomaticStopAction -in 'TurnOff','ShutDown') { OK "AutomaticStopAction: $($vm.AutomaticStopAction)" } else { BAD "AutomaticStopAction is Save (DDA incompatible)" }
INFO "Low MMIO:  $([math]::Round($vm.LowMemoryMappedIoSpace/1GB,1))GB"
INFO "High MMIO: $([math]::Round($vm.HighMemoryMappedIoSpace/1GB,1))GB"
$fw = Get-VMFirmware -VMName $VMName
INFO "Secure Boot: $($fw.SecureBoot)"

H "VM: Assigned devices"
$assigned = @(Get-VMAssignableDevice -VMName $VMName)
if ($assigned) {
    foreach ($a in $assigned) { OK "$($a.LocationPath)  ($($a.InstanceID))" }
} else {
    INFO "No devices assigned (run 03-attach-gpu.ps1)"
}

# ---------- Guest ----------
if ($SkipGuestCheck) { return }

H "Guest: SSH + GPU"

if (-not $GuestIP) {
    $ips = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses
    $GuestIP = $ips | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } | Select-Object -First 1
}
if (-not $GuestIP) { BAD "Could not determine guest IP. Pass -GuestIP."; return }
INFO "Guest IP: $GuestIP"

$ssh = Test-NetConnection -ComputerName $GuestIP -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $ssh) { BAD "SSH (port 22) not reachable"; return }
OK "SSH reachable"

$keyPath = "$env:USERPROFILE\.ssh\id_ed25519"
if (-not (Test-Path $keyPath)) {
    INFO "No SSH key at $keyPath - guest commands will likely prompt for password"
}

Write-Host "  --- guest lspci ---"
& ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i $keyPath "$GuestUser@$GuestIP" "lspci -nn | grep -iE 'nvidia|10de:'"
Write-Host "  --- guest nvidia-smi ---"
& ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i $keyPath "$GuestUser@$GuestIP" "nvidia-smi --query-gpu=name,driver_version,memory.total,memory.free --format=csv 2>&1 | head"
Write-Host "  --- guest driver bound ---"
& ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i $keyPath "$GuestUser@$GuestIP" "lspci -nnk -d 10de:1b06 | tail -3"

Write-Host "`n========== Health check done ==========" -ForegroundColor Cyan
