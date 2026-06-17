<#
.SYNOPSIS
    Restores DDA on Windows 11 client after a Windows Update has reverted
    ProductType to WinNT.

.DESCRIPTION
    Sets a one-time boot sequence to the WinPE flip image, then reboots.
    The flip image automatically:
      1. Mounts the offline SYSTEM hive
      2. Writes ProductType = ServerNT
      3. Reboots into Windows

    Total time: ~60 seconds from running this script to being back at the
    Windows login screen with DDA working again.

.PARAMETER NoReboot
    Stage the bootsequence but do not trigger a reboot. Useful for testing
    or scheduled execution.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\Fix-DDA.ps1

.EXAMPLE
    .\Fix-DDA.ps1 -Force

.NOTES
    Requires the flip image installed by Setup-DdaFlip.ps1.
    Run from an elevated PowerShell prompt.
#>

[CmdletBinding()]
param(
    [switch] $NoReboot,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Elevation check
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Must run elevated." }

$flipDir = "C:\HyperV\flip"
$wimPath = "$flipDir\boot.wim"
$sdiPath = "$flipDir\boot.sdi"
$guidFile = "$flipDir\flip-guid.txt"

# Verify the flip image is installed
foreach ($p in @($wimPath, $sdiPath, $guidFile)) {
    if (-not (Test-Path $p)) {
        Write-Host "Missing component: $p" -ForegroundColor Red
        Write-Host "Run scripts\Setup-DdaFlip.ps1 first to install the flip image." -ForegroundColor Yellow
        return
    }
}

$flipGuid = (Get-Content $guidFile -Raw).Trim()
if (-not ($flipGuid -match '^\{[0-9a-f-]+\}$')) {
    throw "Invalid GUID in $guidFile : $flipGuid"
}

# Confirm BCD entry exists
$entryCheck = & bcdedit /enum $flipGuid 2>&1
if ($entryCheck -match 'error' -or -not ($entryCheck -match 'ProductType Flip')) {
    Write-Host "BCD entry missing or corrupt. Re-run Setup-DdaFlip.ps1 to recreate." -ForegroundColor Red
    return
}

# Pre-flight: show what we're about to do
Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host " DDA Recovery: One-shot WinPE flip of ProductType -> ServerNT"
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Flip image      : $wimPath ($([math]::Round((Get-Item $wimPath).Length/1MB,0)) MB)"
Write-Host "Flip entry GUID : $flipGuid"
Write-Host ""
Write-Host "Next steps (automatic):"
Write-Host "  1. Set one-time boot to flip image"
Write-Host "  2. Restart computer (immediate)"
Write-Host "  3. WinPE briefly shows, flips ProductType, reboots"
Write-Host "  4. Windows boots normally with DDA working"
Write-Host ""

# Confirmation
if (-not $Force) {
    $resp = Read-Host "Proceed? [Y/n]"
    if ($resp -and $resp -notmatch '^[Yy]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }
}

# Set the one-shot boot sequence
Write-Host ""
Write-Host "[1/2] Setting one-shot bootsequence..." -ForegroundColor Yellow
$r = & bcdedit /set "{bootmgr}" bootsequence $flipGuid 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to set bootsequence: $r" -ForegroundColor Red
    return
}
"      OK"

if ($NoReboot) {
    Write-Host ""
    Write-Host "[2/2] -NoReboot specified. Manually run: shutdown /r /t 0" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Bootsequence will fire on next boot. To cancel before reboot:" -ForegroundColor Cyan
    Write-Host "  bcdedit /deletevalue ""{bootmgr}"" bootsequence" -ForegroundColor Cyan
    return
}

Write-Host ""
Write-Host "[2/2] Rebooting in 5 seconds. Ctrl+C to abort..." -ForegroundColor Yellow
for ($i = 5; $i -gt 0; $i--) {
    Write-Host "      $i..." -NoNewline
    Start-Sleep -Seconds 1
    Write-Host "`r" -NoNewline
}
Write-Host "      Rebooting now."
& shutdown /r /t 0
