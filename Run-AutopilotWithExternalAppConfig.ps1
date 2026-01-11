# --- Self-relaunch with ExecutionPolicy Bypass if needed (loop-safe) ---
if (-not $env:AP_WRAPPER_BYPASS_RELAUNCHED) {
    $processPolicy = Get-ExecutionPolicy -Scope Process
    if ($processPolicy -ne "Bypass") {
        Write-Host "ExecutionPolicy (Process) ist '$processPolicy' - starte Script neu mit Bypass..."
        $env:AP_WRAPPER_BYPASS_RELAUNCHED = "1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"
        exit
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-JsonPropValue {
    param(
        [Parameter(Mandatory=$true)][object]$Obj,
        [Parameter(Mandatory=$true)][string]$Name
    )
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

$BasePath = $PSScriptRoot
$WrapperConfigPath = Join-Path $BasePath "wrapper-config.json"
if (-not (Test-Path $WrapperConfigPath)) { throw "wrapper-config.json nicht gefunden: $WrapperConfigPath" }

# ---- Read wrapper-config.json ----
try {
    $cfg = Get-Content $WrapperConfigPath -Raw | ConvertFrom-Json
} catch {
    throw "wrapper-config.json konnte nicht gelesen werden (ungueltiges JSON?): $($_.Exception.Message)"
}

$cfgGroupTag = Get-JsonPropValue -Obj $cfg -Name "GroupTag"
$cfgAppCfg   = Get-JsonPropValue -Obj $cfg -Name "AppConfigPath"
if ([string]::IsNullOrWhiteSpace([string]$cfgGroupTag)) { throw "wrapper-config.json: GroupTag fehlt/leer" }
if ([string]::IsNullOrWhiteSpace([string]$cfgAppCfg))   { throw "wrapper-config.json: AppConfigPath fehlt/leer" }

$GroupTag     = [string]$cfgGroupTag
$OutputFolder = [string](Get-JsonPropValue -Obj $cfg -Name "OutputFolder")
if ([string]::IsNullOrWhiteSpace($OutputFolder)) { $OutputFolder = "." }

$WantAssign = $true
$assignVal = Get-JsonPropValue -Obj $cfg -Name "Assign"
if ($null -ne $assignVal) { $WantAssign = [bool]$assignVal }

$WantReboot = $false
$rebootVal = Get-JsonPropValue -Obj $cfg -Name "Reboot"
if ($null -ne $rebootVal) { $WantReboot = [bool]$rebootVal }

$AutopilotScriptPath = [string](Get-JsonPropValue -Obj $cfg -Name "AutopilotScriptPath")
if ([string]::IsNullOrWhiteSpace($AutopilotScriptPath)) { $AutopilotScriptPath = "Get-WindowsAutoPilotInfo.ps1" }
if (-not [System.IO.Path]::IsPathRooted($AutopilotScriptPath)) {
    $AutopilotScriptPath = Join-Path $BasePath $AutopilotScriptPath
}
if (-not (Test-Path $AutopilotScriptPath)) {
    throw "AutopilotScriptPath nicht gefunden: $AutopilotScriptPath (Tipp: Datei heisst meist Get-WindowsAutoPilotInfo.ps1)"
}

$AppConfigPath = [string]$cfgAppCfg
if (-not [System.IO.Path]::IsPathRooted($AppConfigPath)) {
    $AppConfigPath = Join-Path $BasePath $AppConfigPath
}
if (-not (Test-Path $AppConfigPath)) { throw "AppConfigPath nicht gefunden: $AppConfigPath" }

# ---- Read App Config JSON ----
try {
    $appCfg = Get-Content $AppConfigPath -Raw | ConvertFrom-Json
} catch {
    throw "AppConfig JSON konnte nicht gelesen werden (ungueltiges JSON?): $($_.Exception.Message)"
}

$TenantId = $appCfg.tenant.id
if ([string]::IsNullOrWhiteSpace([string]$TenantId)) { throw "TenantId konnte nicht aus appCfg.tenant.id gelesen werden" }

$AppId = $appCfg.application.applicationId
if ([string]::IsNullOrWhiteSpace([string]$AppId)) { throw "AppId konnte nicht aus appCfg.application.applicationId gelesen werden" }

$AppSecret = $appCfg.credentials.clientSecret.value
if ([string]::IsNullOrWhiteSpace([string]$AppSecret) -and $appCfg.authentication -and $appCfg.authentication.methods) {
    $secretMethod = $appCfg.authentication.methods | Where-Object { $_.type -eq "ClientSecret" } | Select-Object -First 1
    if ($secretMethod) { $AppSecret = $secretMethod.secretValue }
}
if ([string]::IsNullOrWhiteSpace([string]$AppSecret)) {
    throw "ClientSecret konnte nicht aus der AppConfig extrahiert werden (credentials.clientSecret.value / authentication.methods)"
}

# ---- Ensure output folder exists ----
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }

# ---- Build HWID filename FIRST ----
try {
    $serial = (Get-CimInstance -Class Win32_BIOS).SerialNumber
    if ([string]::IsNullOrWhiteSpace($serial)) { $serial = $env:COMPUTERNAME }
} catch {
    $serial = $env:COMPUTERNAME
}

$date    = (Get-Date).ToString("yyyy-MM-dd")
$csvName = "HWID-$serial-$date.csv"
$csvPath = Join-Path (Resolve-Path $OutputFolder) $csvName

Write-Host "HWID CSV: $csvPath"
Write-Host "App-only Auth: TenantId=$TenantId AppId=$AppId (Secret aus AppConfig geladen)"
Write-Host "GroupTag: $GroupTag"
Write-Host "Autopilot Script: $AutopilotScriptPath"

# ---- Call script using splatting ----
$splat = @{
    Online     = $true
    GroupTag   = $GroupTag
    OutputFile = $csvPath
    TenantId   = $TenantId
    AppId      = $AppId
    AppSecret  = $AppSecret
}
if ($WantAssign) { $splat["Assign"] = $true }
if ($WantReboot) { $splat["Reboot"] = $true }

Write-Host "Starte Autopilot Import$(if($WantAssign){' + Assign-Wait'}else{''})..."
Write-Host "$AutopilotScriptPath (Splatting) => $($splat.Keys -join ', ')"

# Run the Autopilot script with StrictMode OFF in a local subscope (NO $using:)
& {
    Set-StrictMode -Off
    & $AutopilotScriptPath @splat
}

Write-Host "Fertig. HWID CSV liegt unter: $csvPath"
