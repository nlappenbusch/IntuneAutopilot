#requires -RunAsAdministrator
Add-Type -AssemblyName System.Windows.Forms

function Get-ISOFileName {
    param([string]$InitialDirectory = "$env:USERPROFILE\Downloads")

    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.InitialDirectory = $InitialDirectory
    $dlg.Filter = "ISO files (*.iso)|*.iso"
    $null = $dlg.ShowDialog()
    return $dlg.FileName
}

function Get-FolderName {
    param(
        [string]$Description = "Bitte Ordner auswaehlen",
        [string]$InitialDirectory = "$env:USERPROFILE\Downloads"
    )

    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.SelectedPath = $InitialDirectory
    $null = $dlg.ShowDialog()
    return $dlg.SelectedPath
}

function Assert-HasInfFiles {
    param([Parameter(Mandatory)][string]$DriverFolder)

    if (-not (Test-Path $DriverFolder)) {
        throw "Driver folder not found: $DriverFolder"
    }

    $inf = Get-ChildItem -Path $DriverFolder -Filter *.inf -Recurse -ErrorAction SilentlyContinue
    if (-not $inf) {
        throw "No .inf files found in driver folder: $DriverFolder"
    }
}

function Safe-DismountIso {
    param([string]$IsoPath)
    try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch {}
}

function Safe-DismountImage {
    param([string]$Path, [switch]$Save)
    try {
        if ($Save) { Dismount-WindowsImage -Path $Path -Save | Out-Null }
        else { Dismount-WindowsImage -Path $Path -Discard | Out-Null }
    } catch {}
}

# -----------------------------
# Variablen
# -----------------------------
$date = Get-Date -Format "dd-MMM-yyyy"
$name = "Windows 11 with net$date"
$scriptRoot = $PSScriptRoot
$targetFolder = Join-Path $scriptRoot $name

# Tipp: Wenn Temp/OneDrive zickt -> fix auf C:\Temp
$tempRoot  = "C:\Temp\Images"
$mountPathInstall = Join-Path $tempRoot "mount-install"
$mountPathBoot    = Join-Path $tempRoot "mount-boot"
$destWim          = Join-Path $tempRoot "install.wim"
$destBootWim      = Join-Path $tempRoot "boot.wim"

Write-Host "Choose Windows 11 ISO..."
$iso = Get-ISOFileName
if (-not (Test-Path $iso)) {
    throw "ISO file not found: $iso"
}

Write-Host "Choose WLAN driver folder (folder with Netwtw*.inf etc.)..."
$wifiDriverFolder = Get-FolderName -Description "WLAN Treiberordner auswaehlen (enthaelt .inf)"
Assert-HasInfFiles -DriverFolder $wifiDriverFolder
Write-Host "WLAN driver folder: $wifiDriverFolder" -ForegroundColor Cyan

$injectBoot = Read-Host "WLAN auch in boot.wim (Index 2) injizieren? (j/n)"
$injectBoot = $injectBoot -match '^(j|y)$'

# ISO mounten (mit DriveLetter)
$mount = Mount-DiskImage -ImagePath $iso -PassThru
$vol = $mount | Get-Volume

if (-not $vol.DriveLetter) {
    Safe-DismountIso -IsoPath $iso
    throw "Could not determine DriveLetter for mounted ISO."
}

$drive = "$($vol.DriveLetter):"

# Pfade in der ISO
$installWimPath = Join-Path $drive "sources\install.wim"
$installEsdPath = Join-Path $drive "sources\install.esd"
$sxsPath        = Join-Path $drive "sources\sxs"
$bootWimPath    = Join-Path $drive "sources\boot.wim"

# Temp-Verzeichnisse vorbereiten
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path $mountPathInstall -ItemType Directory -Force | Out-Null
New-Item -Path $mountPathBoot -ItemType Directory -Force | Out-Null

# Quelle bestimmen
if (Test-Path $installWimPath) {
    $sourceImage = $installWimPath
} elseif (Test-Path $installEsdPath) {
    $sourceImage = $installEsdPath
} else {
    Safe-DismountIso -IsoPath $iso
    throw "Neither install.wim nor install.esd found."
}

$images = Get-WindowsImage -ImagePath $sourceImage
$images | Select-Object ImageIndex, ImageName | Format-Table -AutoSize

do {
    $sourceIndex = Read-Host "Bitte ImageIndex eingeben (z.B. 5 fuer Pro, 3 fuer Education)"
} until ($images.ImageIndex -contains [int]$sourceIndex)

Write-Host "Ausgewaehlter ImageIndex: $sourceIndex" -ForegroundColor Cyan

try {
    # Image exportieren
    Export-WindowsImage `
        -SourceImagePath $sourceImage `
        -SourceIndex $sourceIndex `
        -DestinationImagePath $destWim `
        -DestinationName $name `
        -CheckIntegrity

    # -----------------------------
    # install.wim mounten
    # -----------------------------
    Mount-WindowsImage -ImagePath $destWim -Index 1 -Path $mountPathInstall | Out-Null

    # .NET Framework 3.5 integrieren
    if (-not (Test-Path $sxsPath)) {
        throw "SxS source not found: $sxsPath"
    }

    Enable-WindowsOptionalFeature `
        -Path $mountPathInstall `
        -FeatureName NetFx3 `
        -All `
        -Source $sxsPath `
        -LimitAccess | Out-Null

    # -----------------------------
    # WLAN Treiber in install.wim injizieren
    # -----------------------------
    Write-Host "Injecting WLAN driver into install.wim..." -ForegroundColor Cyan
    Add-WindowsDriver -Path $mountPathInstall -Driver $wifiDriverFolder -Recurse | Out-Null

    # Commit + Unmount install.wim
    Safe-DismountImage -Path $mountPathInstall -Save

    # -----------------------------
    # Optional: boot.wim injizieren
    # -----------------------------
    if ($injectBoot) {
        if (-not (Test-Path $bootWimPath)) {
            throw "boot.wim not found in ISO: $bootWimPath"
        }

        Copy-Item -Path $bootWimPath -Destination $destBootWim -Force

        # --- FIX: ISO macht Dateien oft ReadOnly -> DISM kann nicht committen
        attrib -r "$destBootWim"

        # Optional ACL-Fix (hilft bei zickigen Berechtigungen)
        icacls "$destBootWim" /inheritance:e /grant:r "$env:USERNAME:(F)" "Administrators:(F)" | Out-Null

        # Falls alte Mount-Leichen existieren
        dism /Cleanup-Wim | Out-Null

        # Mount-Ordner sicher leer machen
        Remove-Item $mountPathBoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        New-Item -Path $mountPathBoot -ItemType Directory -Force | Out-Null

        Write-Host "Mounting boot.wim (Index 2)..." -ForegroundColor Cyan
        Mount-WindowsImage -ImagePath $destBootWim -Index 2 -Path $mountPathBoot | Out-Null

        Write-Host "Injecting WLAN driver into boot.wim..." -ForegroundColor Cyan
        Add-WindowsDriver -Path $mountPathBoot -Driver $wifiDriverFolder -Recurse | Out-Null

        Safe-DismountImage -Path $mountPathBoot -Save
    } else {
        Write-Host "Skipping boot.wim injection." -ForegroundColor Yellow
    }

    # -----------------------------
    # Output
    # -----------------------------
    New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
    Copy-Item -Path $destWim -Destination (Join-Path $targetFolder "install.wim") -Force

    if ($injectBoot) {
        Copy-Item -Path $destBootWim -Destination (Join-Path $targetFolder "boot.wim") -Force
    }

    $finalInstallPath = Join-Path $targetFolder "install.wim"
    Set-Clipboard -Value $finalInstallPath

    Write-Host "Done:" -ForegroundColor Green
    Write-Host $finalInstallPath

    if ($injectBoot) {
        $finalBootPath = Join-Path $targetFolder "boot.wim"
        Write-Host $finalBootPath
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Safe-DismountImage -Path $mountPathInstall
    Safe-DismountImage -Path $mountPathBoot
    throw
}
finally {
    Safe-DismountIso -IsoPath $iso
}
