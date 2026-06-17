<#
.SYNOPSIS
    One-time setup of the WinPE flip image and BCD entry that automates the
    ProductType -> ServerNT registry edit needed for Hyper-V DDA on Win11
    client.

.DESCRIPTION
    Builds a minimal Windows PE 4.0+ image from the system's WinRE WIM and
    injects a startnet.cmd that:
      1. Detects the Windows installation drive
      2. Loads the offline SYSTEM hive
      3. Sets ProductType to ServerNT
      4. Reboots into Windows

    Then configures a BCD boot entry pointing at the new WIM, so that
    Fix-DDA.ps1 can trigger it on demand.

    This is a one-time setup. After it runs, you only need Fix-DDA.ps1 to
    recover after Windows Updates that break DDA.

.PARAMETER Force
    Recreate the flip image even if one already exists.

.EXAMPLE
    .\Setup-DdaFlip.ps1

.NOTES
    Run from an elevated PowerShell prompt.
    Total setup time: ~3-5 minutes (mostly DISM mount/commit).
    Disk usage: ~700 MB at C:\HyperV\flip\
#>

[CmdletBinding()]
param(
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
$mountDir = "C:\HyperV\flip-mount"

# Idempotency check
if (-not $Force -and (Test-Path $wimPath) -and (Test-Path $sdiPath) -and (Test-Path $guidFile)) {
    $existingGuid = (Get-Content $guidFile -Raw).Trim()
    $entryCheck = & bcdedit /enum $existingGuid 2>&1
    if ($entryCheck -match 'ProductType Flip') {
        Write-Host "Flip image already installed. Use -Force to recreate." -ForegroundColor Green
        Write-Host "  WIM   : $wimPath"
        Write-Host "  SDI   : $sdiPath"
        Write-Host "  GUID  : $existingGuid"
        return
    }
}

# Prep directories
New-Item -ItemType Directory -Path $flipDir -Force | Out-Null
New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
if ((Get-ChildItem $mountDir -Force | Measure-Object).Count -gt 0) {
    Remove-Item "$mountDir\*" -Recurse -Force -ErrorAction SilentlyContinue
}

# Discard any orphaned DISM mounts
Write-Host "Cleaning up any prior DISM state..." -ForegroundColor Yellow
& dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null

# Back up BCD
$bcdBak = "C:\HyperV\bcd-backup-flip-setup-$(Get-Date -Format yyyyMMdd-HHmmss)"
& bcdedit /export $bcdBak | Out-Null
Write-Host "BCD backed up to: $bcdBak"

# ------ Acquire Winre.wim ------
Write-Host ""
Write-Host "[1/5] Acquiring Winre.wim..." -ForegroundColor Yellow

$reInfo = & reagentc /info
$reDevLine = ($reInfo | Select-String 'Windows RE location').ToString()
if ($reDevLine -match 'harddisk(\d+)\\partition(\d+)') {
    $disk = [int]$matches[1]
    $partNo = [int]$matches[2]
    Write-Host "      Recovery partition: disk $disk, partition $partNo"

    $tempLetter = "R"
    try { Remove-PartitionAccessPath -DiskNumber $disk -PartitionNumber $partNo -AccessPath "${tempLetter}:" -ErrorAction Stop } catch {}
    Add-PartitionAccessPath -DiskNumber $disk -PartitionNumber $partNo -AccessPath "${tempLetter}:"
    Start-Sleep 2

    $srcWim = "${tempLetter}:\Recovery\WindowsRE\Winre.wim"
    if (-not (Test-Path $srcWim)) {
        $srcWim = (Get-ChildItem "${tempLetter}:\" -Recurse -Force -Filter "Winre.wim" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $srcWim -or -not (Test-Path $srcWim)) {
        Remove-PartitionAccessPath -DiskNumber $disk -PartitionNumber $partNo -AccessPath "${tempLetter}:" -ErrorAction SilentlyContinue
        throw "Could not locate Winre.wim on recovery partition"
    }

    Write-Host "      Copying from: $srcWim"
    Copy-Item -Path $srcWim -Destination $wimPath -Force
    & attrib -h -s $wimPath
    Remove-PartitionAccessPath -DiskNumber $disk -PartitionNumber $partNo -AccessPath "${tempLetter}:"

    $wimSize = [math]::Round((Get-Item $wimPath).Length/1MB,1)
    Write-Host "      OK ($wimSize MB)"
} else {
    throw "Could not parse recovery partition from reagentc output"
}

# ------ Copy boot.sdi ------
Write-Host ""
Write-Host "[2/5] Copying boot.sdi..." -ForegroundColor Yellow
Copy-Item -Path "$env:windir\System32\boot.sdi" -Destination $sdiPath -Force
"      OK"

# ------ Mount WIM and inject startnet.cmd ------
Write-Host ""
Write-Host "[3/5] Mounting WIM read-write (3-5 min)..." -ForegroundColor Yellow
& dism.exe /Mount-Wim /WimFile:"$wimPath" /Index:1 /MountDir:"$mountDir" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "DISM mount failed" }
"      OK"

$flipScript = @'
@echo off
title DDA ProductType Flip
mode con: cols=100 lines=25
echo.
echo  ============================================================
echo   DDA ProductType Flip - Setting ProductType=ServerNT
echo  ============================================================
echo.

wpeinit >nul 2>&1

REM Find real OS drive: exclude WinPE's own SYSTEMDRIVE (typically X:)
REM and require \Users as a marker (the WinPE WIM doesn't have it).
set "WIN="
for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if /I not "%%d:"=="%SYSTEMDRIVE%" (
        if not defined WIN (
            if exist "%%d:\Windows\System32\config\SYSTEM" (
                if exist "%%d:\Users" set "WIN=%%d"
            )
        )
    )
)

if not defined WIN (
    echo  [ERROR] Could not find real Windows OS drive.
    echo  Rebooting in 15 seconds...
    timeout /t 15
    wpeutil reboot
    exit /b
)

echo  [INFO] WinPE SYSTEMDRIVE = %SYSTEMDRIVE%
echo  [INFO] OS drive detected = %WIN%:
echo.

REM Log to OS drive too, for post-boot diagnostics
set "LOG=%WIN%:\flip-log.txt"
echo === DDA Flip %DATE% %TIME% > "%LOG%"
echo SYSTEMDRIVE=%SYSTEMDRIVE% >> "%LOG%"
echo OS drive=%WIN%: >> "%LOG%"

reg load HKLM\TmpSys "%WIN%:\Windows\System32\config\SYSTEM"
if errorlevel 1 (
    echo  [ERROR] Failed to load offline SYSTEM hive.
    echo Load failed >> "%LOG%"
    timeout /t 15
    wpeutil reboot
    exit /b
)
echo Load exit: %ERRORLEVEL% >> "%LOG%"

echo  [INFO] Setting ProductType to ServerNT...
reg add "HKLM\TmpSys\ControlSet001\Control\ProductOptions" /v ProductType /t REG_SZ /d ServerNT /f >nul
echo Add exit: %ERRORLEVEL% >> "%LOG%"

reg query "HKLM\TmpSys\ControlSet001\Control\ProductOptions" /v ProductType
reg query "HKLM\TmpSys\ControlSet001\Control\ProductOptions" /v ProductType >> "%LOG%" 2>&1

reg unload HKLM\TmpSys
echo Unload exit: %ERRORLEVEL% >> "%LOG%"

echo === DONE === >> "%LOG%"

echo.
echo  [OK] Flip complete. Rebooting in 3 seconds...
timeout /t 3
wpeutil reboot
'@

# Also need a winpeshl.ini to explicitly launch our startnet.cmd
# (WinRE WIMs ignore startnet.cmd if winpeshl.ini is absent or points elsewhere)
$winpeshlContent = @"
[LaunchApps]
%SYSTEMDRIVE%\Windows\System32\cmd.exe, /k %SYSTEMDRIVE%\Windows\System32\startnet.cmd
"@

Write-Host ""
Write-Host "[4/5] Injecting startnet.cmd + winpeshl.ini..." -ForegroundColor Yellow
$enc = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText("$mountDir\Windows\System32\startnet.cmd", $flipScript, $enc)
[System.IO.File]::WriteAllText("$mountDir\Windows\System32\winpeshl.ini", $winpeshlContent, $enc)
"      OK"

Write-Host ""
Write-Host "      Committing changes (this also takes 3-5 min)..."
& dism.exe /Unmount-Wim /MountDir:"$mountDir" /Commit 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "DISM commit failed" }
"      OK"

# Clear attributes the WIM may have inherited from recovery partition
& attrib -h -s $wimPath
Remove-Item $mountDir -Recurse -Force -ErrorAction SilentlyContinue

# ------ Configure BCD ------
Write-Host ""
Write-Host "[5/5] Configuring BCD boot entry..." -ForegroundColor Yellow

# Remove any prior flip entry
$existing = & bcdedit /enum all | Select-String 'ProductType Flip'
if ($existing) {
    foreach ($line in (& bcdedit /enum all)) {
        if ($line -match 'identifier\s+(\{[0-9a-f-]+\})') {
            $candidateGuid = $matches[1]
            $desc = & bcdedit /enum $candidateGuid 2>&1 | Select-String 'description'
            if ($desc -match 'ProductType Flip') {
                Write-Host "      Removing prior flip entry: $candidateGuid"
                & bcdedit /delete $candidateGuid /f | Out-Null
            }
        }
    }
}

# Ramdiskoptions entry
& bcdedit /create '{ramdiskoptions}' /d "Ramdisk options for ProductType flip" 2>&1 | Out-Null
& bcdedit /set '{ramdiskoptions}' ramdisksdidevice partition=C: | Out-Null
& bcdedit /set '{ramdiskoptions}' ramdisksdipath \HyperV\flip\boot.sdi | Out-Null

# Create the osloader
$createOutput = & bcdedit /create /d "ProductType Flip to ServerNT" /application osloader
if (-not ($createOutput -match '\{([0-9a-f-]+)\}')) { throw "Failed to extract GUID from: $createOutput" }
$flipGuid = "{$($matches[1])}"

& bcdedit /set $flipGuid device "ramdisk=[C:]\HyperV\flip\boot.wim,{ramdiskoptions}" | Out-Null
& bcdedit /set $flipGuid osdevice "ramdisk=[C:]\HyperV\flip\boot.wim,{ramdiskoptions}" | Out-Null
& bcdedit /set $flipGuid path \windows\system32\winload.efi | Out-Null
& bcdedit /set $flipGuid systemroot \windows | Out-Null
& bcdedit /set $flipGuid winpe Yes | Out-Null
& bcdedit /set $flipGuid detecthal Yes | Out-Null

# Persist GUID for Fix-DDA.ps1
$flipGuid | Out-File $guidFile -Encoding ASCII

"      Flip GUID: $flipGuid"
Write-Host ""
Write-Host "===============================================================" -ForegroundColor Green
Write-Host "Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "To recover DDA after a Windows Update:"
Write-Host "  .\Fix-DDA.ps1"
Write-Host ""
Write-Host "That's it. One command, one ~60-second reboot cycle." -ForegroundColor Cyan
