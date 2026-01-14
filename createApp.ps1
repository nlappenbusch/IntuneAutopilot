<#
.SYNOPSIS
    Legt eine Entra ID App Registration an, erstellt ein Zertifikat,
    hängt das Zert an die App, und gibt alle Infos für Certificate-based Auth aus.

.Voraussetzungen
    - Du musst Global Admin / Application Administrator + Directory Schreibrechte haben.
    - Internetzugang zu Microsoft Graph.
#>

param(
    [string]$AppDisplayName   = "IG-MgtTool-AutoApp",
    [string]$CertPathRoot     = "C:\Temp",
    [int]   $CertValidYears   = 2
)

#region Helper: Modul-Check
function Ensure-Module {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$MinVersion = "0.0.0"
    )

    Write-Host "  - Pruefe Modul '$Name'..." -ForegroundColor Gray
    $module = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1

    if (-not $module -or ([version]$module.Version -lt [version]$MinVersion)) {
        Write-Host "  - Installiere PowerShell-Modul '$Name' (min. Version $MinVersion)..." -ForegroundColor Yellow
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Host "  - Installation abgeschlossen." -ForegroundColor Green
    } else {
        Write-Host "  - Modul '$Name' (v$($module.Version)) ist vorhanden." -ForegroundColor Green
    }
}
#endregion

#region Vorbereitung: Module & Pfade
Write-Host "==> Pruefe/Installiere benoetigte Module..." -ForegroundColor Cyan

# Nur die spezifischen Sub-Module installieren/importieren (viel schneller!)
Ensure-Module -Name "Microsoft.Graph.Authentication" -MinVersion "2.0.0"
Ensure-Module -Name "Microsoft.Graph.Applications"   -MinVersion "2.0.0"
Ensure-Module -Name "ExchangeOnlineManagement"  -MinVersion "3.0.0"

Write-Host "  - Lade Module..." -ForegroundColor Gray
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Applications   -ErrorAction Stop
Write-Host "  - Module geladen." -ForegroundColor Green

if (-not (Test-Path $CertPathRoot)) {
    Write-Host "==> Erstelle Ordner $CertPathRoot..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $CertPathRoot -Force | Out-Null
}
#endregion

#region Graph-Login
Write-Host "==> Verbinde zu Microsoft Graph..." -ForegroundColor Cyan
Write-Host "    Bitte melden Sie sich im Browser-Fenster an..." -ForegroundColor Yellow

# Stelle sicher, dass keine alte Sitzung aktiv ist
try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}

$requiredScopes = @(
    "Application.ReadWrite.All",
    "Directory.AccessAsUser.All"
)

Connect-MgGraph -Scopes $requiredScopes -NoWelcome -UseDeviceCode:$false -ErrorAction Stop

$ctx = Get-MgContext
if (-not $ctx) {
    throw "Microsoft Graph Verbindung fehlgeschlagen. Bitte erneut versuchen."
}

$tenantId = $ctx.TenantId

# Hole Tenant-Info direkt via REST API (vermeidet Modul-Probleme)
$orgUri = "https://graph.microsoft.com/v1.0/organization"
$orgResponse = Invoke-MgGraphRequest -Method GET -Uri $orgUri
$org = $orgResponse.value | Select-Object -First 1
$defaultDomain = ($org.verifiedDomains | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1).name

Write-Host "    TenantId:      $tenantId" -ForegroundColor DarkGray
Write-Host "    DefaultDomain: $defaultDomain" -ForegroundColor DarkGray
#endregion

#region Zertifikat erstellen
Write-Host "==> Erstelle Self-Signed Zertifikat im User-Kontext..." -ForegroundColor Cyan

$certSubject = "CN=$AppDisplayName"
$notAfter    = (Get-Date).AddYears($CertValidYears)

$cert = New-SelfSignedCertificate `
    -Subject $certSubject `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -NotAfter $notAfter

if (-not $cert) {
    throw "Zertifikat konnte nicht erstellt werden."
}

$thumbprint = $cert.Thumbprint
Write-Host "    Zertifikat-Thumbprint: $thumbprint" -ForegroundColor Green
Write-Host "    Zertifikat liegt in:   Cert:\CurrentUser\My" -ForegroundColor DarkGray

# Export .cer (Public Key)
$cerFile = Join-Path $CertPathRoot "$($AppDisplayName)_public.cer"
Export-Certificate -Cert $cert -FilePath $cerFile -Force | Out-Null

# Export .pfx (Private Key) mit Zufallspasswort
$pfxFile = Join-Path $CertPathRoot "$($AppDisplayName)_private.pfx"
$pfxPasswordPlain = [System.Convert]::ToBase64String((New-Guid).ToByteArray())
$pfxSecure        = ConvertTo-SecureString -String $pfxPasswordPlain -AsPlainText -Force

Export-PfxCertificate -Cert $cert -FilePath $pfxFile -Password $pfxSecure -Force | Out-Null

Write-Host "    Exportiert:" -ForegroundColor DarkGray
Write-Host "      CER : $cerFile" -ForegroundColor DarkGray
Write-Host "      PFX : $pfxFile" -ForegroundColor DarkGray
Write-Host "      PFX-Passwort (bitte sicher speichern!): $pfxPasswordPlain" -ForegroundColor Yellow
#endregion

#region Client Secret erstellen
Write-Host "==> Erstelle Client Secret..." -ForegroundColor Cyan

$secretDisplayName = "$AppDisplayName-secret"
$secretDuration = New-TimeSpan -Days ($CertValidYears * 365)

# Generiere ein sicheres Secret (32 Zeichen)
$clientSecretValue = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})
$clientSecretValue += "-" + [guid]::NewGuid().ToString().Substring(0,8)

Write-Host "    Client Secret generiert (wird nur einmal angezeigt!)" -ForegroundColor Yellow
Write-Host "    Secret: $clientSecretValue" -ForegroundColor Green
#endregion

#region keyCredentials fuer App vorbereiten
Write-Host "==> Bereite keyCredentials fuer App-Registrierung vor..." -ForegroundColor Cyan

# KeyCredentials als Hashtable mit Byte-Array (nicht Base64 String!)
$keyCredential = @{
    displayName   = "$AppDisplayName-cert"
    type          = "AsymmetricX509Cert"
    usage         = "Verify"
    key           = $cert.RawData  # Direktes Byte-Array
    startDateTime = $cert.NotBefore.ToUniversalTime()
    endDateTime   = $cert.NotAfter.ToUniversalTime()
}
#endregion

#region Permissions definieren & requiredResourceAccess bauen
Write-Host "==> Baue requiredResourceAccess fuer Microsoft Graph & Exchange Online..." -ForegroundColor Cyan

# Well-known IDs
$graphAppId    = "00000003-0000-0000-c000-000000000000"
$exchangeAppId = "00000002-0000-0ff1-ce00-000000000000"

# Konfiguration der Permissions (Name = Value im SP, Type = Application/Delegated)
$permissionConfig = @(
    @{
        ResourceAppId = $graphAppId
        Permissions = @(
            @{ Name = "AuditLog.Read.All";                            Type = "Application" }
            @{ Name = "DeviceManagementConfiguration.ReadWrite.All";  Type = "Application" }
            @{ Name = "DeviceManagementManagedDevices.PrivilegedOperations.All"; Type = "Application" }
            @{ Name = "DeviceManagementManagedDevices.ReadWrite.All"; Type = "Application" }
            @{ Name = "DeviceManagementServiceConfig.Read.All";       Type = "Application" }
            @{ Name = "DeviceManagementServiceConfig.ReadWrite.All";  Type = "Application" }
            @{ Name = "Directory.ReadWrite.All";                      Type = "Application" }
            @{ Name = "Group.ReadWrite.All";                          Type = "Application" }
            @{ Name = "LicenseAssignment.ReadWrite.All";              Type = "Application" }
            @{ Name = "User.ManageIdentities.All";                    Type = "Application" }
            @{ Name = "User.Read";                                    Type = "Delegated"  } # Sign-in & Profil
        )
    },
    @{
        ResourceAppId = $exchangeAppId
        Permissions = @(
            @{ Name = "Contacts.ReadWrite";           Type = "Application" }
            @{ Name = "Exchange.ManageAsApp";         Type = "Application" }
            @{ Name = "Exchange.ManageAsAppV2";       Type = "Application" }
            @{ Name = "full_access_as_app";           Type = "Application" }
            @{ Name = "Mailbox.Migration";            Type = "Application" }
            @{ Name = "MailboxSettings.ReadWrite";    Type = "Application" }
            @{ Name = "Organization.ReadWrite.All";   Type = "Application" }
            @{ Name = "User.ReadBasic.All";           Type = "Application" }
        )
    }
)

function Get-RequiredResourceAccess {
    param(
        [Parameter(Mandatory)][array]$Config
    )

    $result = @()

    foreach ($resource in $Config) {
        # Hole Service Principal via REST API
        $spUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($resource.ResourceAppId)'"
        $spResponse = Invoke-MgGraphRequest -Method GET -Uri $spUri
        $sp = $spResponse.value | Select-Object -First 1

        if (-not $sp) {
            throw "Service Principal mit appId $($resource.ResourceAppId) wurde nicht gefunden."
        }

        $resourceAccess = @()

        foreach ($perm in $resource.Permissions) {
            if ($perm.Type -eq "Application") {
                $appRole = $sp.appRoles | Where-Object { $_.value -eq $perm.Name -and $_.allowedMemberTypes -contains "Application" }
                if (-not $appRole) {
                    throw "AppRole '$($perm.Name)' wurde auf Resource $($resource.ResourceAppId) nicht gefunden."
                }

                $resourceAccess += @{
                    id   = $appRole.id
                    type = "Role"
                }
            }
            elseif ($perm.Type -eq "Delegated") {
                $scope = $sp.oauth2PermissionScopes | Where-Object { $_.value -eq $perm.Name }
                if (-not $scope) {
                    throw "Delegated-Scope '$($perm.Name)' wurde auf Resource $($resource.ResourceAppId) nicht gefunden."
                }

                $resourceAccess += @{
                    id   = $scope.id
                    type = "Scope"
                }
            }
            else {
                throw "Unbekannter Permission-Type '$($perm.Type)' fuer '$($perm.Name)'."
            }
        }

        $result += @{
            resourceAppId  = $resource.ResourceAppId
            resourceAccess = $resourceAccess
        }
    }

    return $result
}

$requiredResourceAccess = Get-RequiredResourceAccess -Config $permissionConfig
#endregion

#region App-Registrierung erstellen
Write-Host "==> Erstelle Application Registration '$AppDisplayName'..." -ForegroundColor Cyan

$appParams = @{
    DisplayName            = $AppDisplayName
    SignInAudience         = "AzureADMyOrg"      # Nur eigener Tenant
    RequiredResourceAccess = $requiredResourceAccess
    KeyCredentials         = @($keyCredential)
}

$app = New-MgApplication @appParams

if (-not $app) {
    throw "Anwendungsregistrierung konnte nicht erstellt werden."
}

Write-Host "    AppId:    $($app.AppId)" -ForegroundColor Green
Write-Host "    ObjectId: $($app.Id)"    -ForegroundColor DarkGray

# Client Secret hinzufügen
Write-Host "  - Füge Client Secret hinzu..." -ForegroundColor Gray
$secretParams = @{
    passwordCredential = @{
        displayName = $secretDisplayName
        endDateTime = (Get-Date).Add($secretDuration).ToUniversalTime().ToString("o")
    }
}

$addedSecret = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/applications/$($app.Id)/addPassword" -Body ($secretParams | ConvertTo-Json)
$clientSecret = $addedSecret.secretText
Write-Host "    Client Secret hinzugefügt" -ForegroundColor Green

# Service Principal fuer App erzeugen
Write-Host "==> Erstelle Service Principal fuer die App..." -ForegroundColor Cyan
$spApp = New-MgServicePrincipal -AppId $app.AppId

Write-Host "    ServicePrincipalId: $($spApp.Id)" -ForegroundColor Green

# Exchange Administrator Rolle zuweisen
Write-Host "==> Weise Exchange Administrator Rolle zu..." -ForegroundColor Cyan
try {
    # Exchange Administrator Role Template ID (fix)
    $exchangeAdminRoleId = "29232cdf-9323-42fd-ade2-1d097af3e4de"
    
    # Hole die Directory Role (muss aktiviert sein)
    $roleUri = "https://graph.microsoft.com/v1.0/directoryRoles?`$filter=roleTemplateId eq '$exchangeAdminRoleId'"
    $roleResponse = Invoke-MgGraphRequest -Method GET -Uri $roleUri
    $role = $roleResponse.value | Select-Object -First 1
    
    if (-not $role) {
        # Rolle muss erst aktiviert werden
        Write-Host "  - Aktiviere Exchange Administrator Rolle..." -ForegroundColor Gray
        $activateUri = "https://graph.microsoft.com/v1.0/directoryRoles"
        $activateBody = @{
            roleTemplateId = $exchangeAdminRoleId
        } | ConvertTo-Json
        $role = Invoke-MgGraphRequest -Method POST -Uri $activateUri -Body $activateBody
    }
    
    # Service Principal zur Rolle hinzufuegen
    $memberUri = "https://graph.microsoft.com/v1.0/directoryRoles/$($role.id)/members/`$ref"
    $memberBody = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($spApp.Id)"
    } | ConvertTo-Json
    
    Invoke-MgGraphRequest -Method POST -Uri $memberUri -Body $memberBody -ErrorAction Stop
    Write-Host "  - Exchange Administrator Rolle erfolgreich zugewiesen." -ForegroundColor Green
    Write-Host "  - HINWEIS: Sichtbar unter Entra ID - Roles and administrators - Exchange Administrator" -ForegroundColor Cyan
} catch {
    Write-Host "  - WARNUNG: Exchange Administrator Rolle konnte nicht zugewiesen werden." -ForegroundColor Yellow
    Write-Host "  - Fehler: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  - Bitte manuell im Azure Portal zuweisen." -ForegroundColor Yellow
}

# Admin Consent automatisch erteilen
Write-Host "==> Erteile Admin Consent für API Permissions..." -ForegroundColor Cyan
$adminConsentGranted = $false
try {
    $resourceSPs = @(
        @{ AppId = "00000003-0000-0000-c000-000000000000"; Name = "Microsoft Graph" }
        @{ AppId = "00000002-0000-0ff1-ce00-000000000000"; Name = "Office 365 Exchange Online" }
    )
    
    foreach ($resource in $resourceSPs) {
        Write-Host "  - Erteile Consent fuer $($resource.Name)..." -ForegroundColor Gray
        
        $filterQuery = "`$filter=appId eq '$($resource.AppId)'"
        $resourceSPUri = "https://graph.microsoft.com/v1.0/servicePrincipals?$filterQuery"
        $resourceSPResponse = Invoke-MgGraphRequest -Method GET -Uri $resourceSPUri
        $resourceSP = $resourceSPResponse.value | Select-Object -First 1
        
        if ($resourceSP) {
            $appRoleAssignments = $requiredResourceAccess | Where-Object { $_.resourceAppId -eq $resource.AppId }
            
            if ($appRoleAssignments) {
                foreach ($roleAccess in $appRoleAssignments.resourceAccess) {
                    if ($roleAccess.type -eq "Role") {
                        $assignmentBody = @{
                            principalId = $spApp.Id
                            resourceId = $resourceSP.id
                            appRoleId = $roleAccess.id
                        } | ConvertTo-Json
                        
                        try {
                            $assignUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$($spApp.Id)/appRoleAssignments"
                            Invoke-MgGraphRequest -Method POST -Uri $assignUri -Body $assignmentBody -ErrorAction Stop | Out-Null
                        }
                        catch {
                            if ($_.Exception.Message -notlike "*Permission being assigned already exists*") {
                                throw
                            }
                        }
                    }
                }
            }
            
            Write-Host "    OK Consent fuer $($resource.Name) erteilt" -ForegroundColor Green
        }
    }
    
    $adminConsentGranted = $true
    Write-Host "  - Admin Consent erfolgreich erteilt!" -ForegroundColor Green
}
catch {
    Write-Host "  - WARNUNG: Admin Consent konnte nicht automatisch erteilt werden." -ForegroundColor Yellow
    Write-Host "  - Fehler: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  - Bitte manuell im Browser erteilen (URL siehe unten)." -ForegroundColor Yellow
}
#endregion

#region Ausgabe & Connect-ExchangeOnline-Cmdlet
Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   Fertig. Zusammenfassung:" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$connectExchangeCmd = "Connect-ExchangeOnline -AppId $($app.AppId) -CertificateThumbprint $thumbprint -Organization $defaultDomain"

$result = [PSCustomObject]@{
    TenantId             = $tenantId
    DefaultDomain        = $defaultDomain
    Organization         = $defaultDomain
    AppDisplayName       = $AppDisplayName
    ApplicationId        = $app.AppId
    ClientId             = $app.AppId
    ApplicationObjectId  = $app.Id
    ServicePrincipalId   = $spApp.Id
    ClientSecret         = $clientSecret
    CertificateThumbprint= $thumbprint
    CertStoreLocation    = "Cert:\CurrentUser\My"
    CerFile              = $cerFile
    PfxFile              = $pfxFile
    PfxPassword          = $pfxPasswordPlain
    ConnectExchangeCmd   = $connectExchangeCmd
    AdminConsentUrl      = "https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$($app.AppId)"
}

# Erstelle TXT-Datei mit allen Informationen
$txtFile = Join-Path $CertPathRoot "$($AppDisplayName)_credentials.txt"

$appIdForScript = $app.AppId

# Erstelle Text-Inhalt ohne problematische Here-String Syntax
$txtLines = @()
$txtLines += "========================================================"
$txtLines += "Entra ID App Registration - Credentials"
$txtLines += "========================================================"
$txtLines += "Erstellt am: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$txtLines += ""
$txtLines += "TENANT INFORMATIONEN"
$txtLines += "Tenant ID:           $tenantId"
$txtLines += "Organization:        $defaultDomain"
$txtLines += "Default Domain:      $defaultDomain"
$txtLines += ""
$txtLines += "APPLICATION INFORMATIONEN"
$txtLines += "App Name:            $AppDisplayName"
$txtLines += "Application ID:      $appIdForScript"
$txtLines += "Client ID:           $appIdForScript"
$txtLines += "Object ID:           $($app.Id)"
$txtLines += "Service Principal:   $($spApp.Id)"
$txtLines += ""
$txtLines += "AUTHENTIFIZIERUNG"
$txtLines += "Client Secret:       $clientSecret"
$txtLines += "  (Gueltig bis: $((Get-Date).Add($secretDuration).ToString('yyyy-MM-dd')))"
$txtLines += ""
$txtLines += "Zertifikat Thumbprint: $thumbprint"
$txtLines += "  (Gueltig bis: $($cert.NotAfter.ToString('yyyy-MM-dd')))"
$txtLines += "Zertifikat Store:    Cert:\CurrentUser\My"
$txtLines += ""
$txtLines += "DATEIEN"
$txtLines += "CER-Datei (Public):  $cerFile"
$txtLines += "PFX-Datei (Private): $pfxFile"
$txtLines += "PFX-Passwort:        $pfxPasswordPlain"
$txtLines += ""
$txtLines += "VERBINDUNGS-BEISPIELE"
$txtLines += "Exchange Online (Certificate):"
$txtLines += "  Connect-ExchangeOnline -AppId $appIdForScript -CertificateThumbprint $thumbprint -Organization $defaultDomain"
$txtLines += ""
$txtLines += "Microsoft Graph (Certificate):"
$txtLines += "  Connect-MgGraph -ClientId $appIdForScript -TenantId $tenantId -CertificateThumbprint $thumbprint"
$txtLines += ""
$txtLines += "Microsoft Graph (Client Secret):"
$secretLine1 = '  $secureSecret = ConvertTo-SecureString "SECRET_HERE" -AsPlainText -Force'
$secretLine1 = $secretLine1.Replace("SECRET_HERE", $clientSecret)
$txtLines += $secretLine1
$secretLine2 = '  $cred = New-Object System.Management.Automation.PSCredential("APPID_HERE", $secureSecret)'
$secretLine2 = $secretLine2.Replace("APPID_HERE", $appIdForScript)
$txtLines += $secretLine2
$secretLine3 = '  Connect-MgGraph -TenantId TENANT_HERE -ClientSecretCredential $cred'
$secretLine3 = $secretLine3.Replace("TENANT_HERE", $tenantId)
$txtLines += $secretLine3
$txtLines += ""
$txtLines += "ADMIN CONSENT"
$txtLines += "URL (im Browser oeffnen als Global Admin):"
$txtLines += "https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$appIdForScript"
$txtLines += ""
$txtLines += "WICHTIG"
$txtLines += "- Client Secret und PFX-Passwort sicher aufbewahren!"
$txtLines += "- Admin Consent muss einmalig erteilt werden"
$txtLines += "- Exchange Administrator Rolle wurde dem Service Principal zugewiesen"
$txtLines += "- Zertifikat ist im User-Store (CurrentUser\My) installiert"
$txtLines += ""
$txtLines += "========================================================"

$txtContent = $txtLines -join "`r`n"

Set-Content -Path $txtFile -Value $txtContent -Encoding UTF8
Write-Host "" -ForegroundColor Cyan
Write-Host "==> Credentials-Datei erstellt: $txtFile" -ForegroundColor Green

# Erstelle JSON-Datei für Web-Tools / Backend-Authentifizierung
$jsonFile = Join-Path $CertPathRoot "$($AppDisplayName)_config.json"
$jsonConfig = @{
    config = @{
        version = "1.0"
        createdAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        description = "Entra ID App Configuration for $AppDisplayName"
    }
    tenant = @{
        id = $tenantId
        domain = $defaultDomain
        organization = $defaultDomain
    }
    application = @{
        name = $AppDisplayName
        clientId = $app.AppId
        applicationId = $app.AppId
        objectId = $app.Id
        servicePrincipalId = $spApp.Id
    }
    credentials = @{
        clientSecret = @{
            value = $clientSecret
            expiresAt = (Get-Date).Add($secretDuration).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            displayName = $secretDisplayName
        }
        certificate = @{
            thumbprint = $thumbprint
            subject = $certSubject
            storeLocation = "CurrentUser\\My"
            expiresAt = $cert.NotAfter.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            files = @{
                publicKey = @{
                    path = $cerFile
                    format = "CER"
                }
                privateKey = @{
                    path = $pfxFile
                    format = "PFX"
                    password = $pfxPasswordPlain
                }
            }
        }
    }
    authentication = @{
        methods = @(
            @{
                type = "Certificate"
                primary = $true
                thumbprint = $thumbprint
            },
            @{
                type = "ClientSecret"
                primary = $false
                secretValue = $clientSecret
            }
        )
    }
    services = @{
        exchangeOnline = @{
            enabled = $true
            connectionMethod = "Certificate"
            parameters = @{
                AppId = $app.AppId
                CertificateThumbprint = $thumbprint
                Organization = $defaultDomain
            }
            sampleCommand = "Connect-ExchangeOnline -AppId $($app.AppId) -CertificateThumbprint $thumbprint -Organization $defaultDomain"
        }
        microsoftGraph = @{
            enabled = $true
            connectionMethod = "Certificate"
            parameters = @{
                ClientId = $app.AppId
                TenantId = $tenantId
                CertificateThumbprint = $thumbprint
            }
            sampleCommand = "Connect-MgGraph -ClientId $($app.AppId) -TenantId $tenantId -CertificateThumbprint $thumbprint"
        }
    }
    permissions = @{
        microsoftGraph = @{
            application = @(
                @{ name = "AuditLog.Read.All"; description = "Read audit logs" },
                @{ name = "DeviceManagementConfiguration.ReadWrite.All"; description = "Read and write device configuration" },
                @{ name = "DeviceManagementManagedDevices.PrivilegedOperations.All"; description = "Perform privileged operations on devices" },
                @{ name = "DeviceManagementManagedDevices.ReadWrite.All"; description = "Read and write managed devices" },
                @{ name = "DeviceManagementServiceConfig.Read.All"; description = "Read device management service config" },
                @{ name = "DeviceManagementServiceConfig.ReadWrite.All"; description = "Read and write device management service config" },
                @{ name = "Directory.ReadWrite.All"; description = "Read and write directory data" },
                @{ name = "Group.ReadWrite.All"; description = "Read and write all groups" },
                @{ name = "LicenseAssignment.ReadWrite.All"; description = "Read and write license assignments" },
                @{ name = "User.ManageIdentities.All"; description = "Manage user identities" }
            )
            delegated = @(
                @{ name = "User.Read"; description = "Sign in and read user profile" }
            )
        }
        exchange = @{
            application = @(
                @{ name = "Contacts.ReadWrite"; description = "Read and write contacts" },
                @{ name = "Exchange.ManageAsApp"; description = "Manage Exchange as application" },
                @{ name = "Exchange.ManageAsAppV2"; description = "Manage Exchange as application V2" },
                @{ name = "full_access_as_app"; description = "Full access as application" },
                @{ name = "Mailbox.Migration"; description = "Mailbox migration" },
                @{ name = "MailboxSettings.ReadWrite"; description = "Read and write mailbox settings" },
                @{ name = "Organization.ReadWrite.All"; description = "Read and write organization" },
                @{ name = "User.ReadBasic.All"; description = "Read basic user information" }
            )
        }
        roles = @{
            directory = @(
                @{ name = "Exchange Administrator"; id = "29232cdf-9323-42fd-ade2-1d097af3e4de"; assigned = $true }
            )
        }
    }
    adminConsent = @{
        required = $true
        granted = $false
        url = "https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$($app.AppId)"
        note = "Admin consent must be granted by a Global Administrator"
    }
}

$jsonConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonFile -Encoding UTF8
Write-Host "==> JSON-Konfiguration erstellt: $jsonFile" -ForegroundColor Green

$result | Format-List

Write-Host ""
Write-Host "Beispiel-Cmdlet fuer Exchange Online:" -ForegroundColor Yellow
Write-Host "  $connectExchangeCmd" -ForegroundColor Green

Write-Host ""
Write-Host "Admin-Consent (einmalig als Global Admin im Browser aufrufen):" -ForegroundColor Yellow
if ($adminConsentGranted) {
    Write-Host "  [OK] Admin Consent wurde automatisch erteilt!" -ForegroundColor Green
} else {
    Write-Host "  [!] Bitte manuell erteilen:" -ForegroundColor Yellow
    Write-Host "  $($result.AdminConsentUrl)" -ForegroundColor Green
}
Write-Host ""
Write-Host "Hinweis: Zertifikat ist bereits im User-Store (CurrentUser\My) importiert." -ForegroundColor Cyan
Write-Host "" -ForegroundColor Cyan
Write-Host "Alle Credentials wurden gespeichert in:" -ForegroundColor Yellow
Write-Host "  TXT: $txtFile" -ForegroundColor Green
Write-Host "  JSON: $jsonFile" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
#endregion
