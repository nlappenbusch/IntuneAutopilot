# HowTo: Windows Installationsmedium fuer Client Staging mit Autopilot / Intune (inkl. HWID Import)

Dieses Dokument beschreibt einen praxisnahen End-to-End Ablauf, um bestehende Geraete effizient zu stagen:
- Windows Installation mit moeglichst wenig Klicks (autounattend.xml)
- WLAN direkt im Setup/OOBE (Treiber + WLAN Profil)
- Autopilot HWID Import inkl. GroupTag ohne User Login (USB Workflow)

Repo/Grundlage fuer den Autopilot Import:
https://github.com/nlappenbusch/IntuneAutopilot

---

## 1) Zielbild

Du willst:
- mehrere Geraete parallel installieren/stagen
- kein WLAN Passwort x-mal eintippen
- keine Usernamen/Passwoerter/MFA im Prozess
- GroupTag direkt setzen, damit das richtige Autopilot Profil greift
- moeglichst wenig Setup Klickerei (Partitionierung, Sprache, OOBE)

---

## 2) Bausteine

1. Autounattend.xml (Setup automatisieren)
2. WLAN Treiber Injection (install.wim und optional boot.wim)
3. WLAN Profil Injection (autounattend.xml, XML aus Referenzgeraet)
4. Autopilot HWID Import via USB Stick (App-only Auth, GroupTag, optional Assign/Wait)

---

## 3) Autounattend.xml erstellen (Schneegans Tool)

Empfohlenes Tool:
https://schneegans.de/windows/unattend-generator/

### 3.1 Wichtige Settings (muss so gesetzt sein)

#### Region and language
- Windows display language: English (muss zur ISO passen)
- Languages / keyboards (Reihenfolge):
  1) German (Switzerland) / Swiss German
  2) German (Germany) / German
  3) Spanish (Spain) / Spanish
- Home location: Switzerland

#### Computer name
- Let Windows generate a random computer name

Wichtig: Damit Intune spaeter die Namensvergabe gemaess Naming Policy uebernehmen kann.

#### Partitioning and formatting
Empfohlen:
- Let Windows Setup wipe, partition and format disk 0
- Layout: GPT
- ESP size: 300 MB

Damit entfaellt interaktives Loeschen/Anlegen von Partitionen.

#### User accounts (GANZ WICHTIG fuer Autopilot Experience)
Unbedingt:
- Add a Microsoft (online) user account interactively during Windows Setup

Hinweis:
- Lokale Offline Accounts nur dann nutzen, wenn du genau weisst, warum.
- Fuer Autopilot/OOBE ist ein "normaler" Online Sign-In der Standardpfad. Autounattend soll hier nicht in einen Offline-Flow abbiegen.

---

## 4) WLAN Profil ohne Passwort-Klickerei

### 4.1 WLAN Profil von Referenzgeraet exportieren

Auf einem Referenzgeraet, das bereits mit dem Staging-WLAN verbunden ist:

```powershell
netsh wlan export profile key=clear
```

Das erzeugt eine XML Datei pro Profil.

Alternativ (wenn vorhanden): export-wlan-profile.ps1 aus deinem Repo verwenden.

### 4.2 WLAN XML in Schneegans Tool hinterlegen
Im Schneegans Tool bei WLAN / Wi-Fi:
- Configure Wi-Fi using an XML file
- Inhalt des exportierten WLANProfile XML einfuegen

Wichtig:
- Kein echtes Passwort im Klartext "liegen lassen"
- Wenn du nach Download der autounattend.xml das Passwort anpasst: <keyMaterial>...</keyMaterial>

---

## 5) WLAN Treiber (und weitere Treiber) ins Installationsmedium injizieren

### 5.1 Warum?
Autopilot benoetigt Internet in OOBE. Ohne passenden WLAN Treiber:
- kein WLAN im OOBE
- Setup bleibt haengen oder du musst mit USB-Ethernet "retten"
- bei vielen Geraeten wird das unbrauchbar

### 5.2 Treiberpaket (erforderliche Dateien)
Der Treiberordner muss INF-basiert sein.

Pflicht:
- *.inf

Typisch zusaetzlich (sollten im gleichen Ordnerbaum liegen):
- *.sys
- *.cat
- ggf. *.dll, *.dat

Beispiel:
Drivers\WiFi\
- Netwtw6e.inf
- Netwtw14.inf
- *.sys
- *.cat

### 5.3 Injection Script
Nutze:
- Build-Windows11-WIM-NetFx3.ps1

Das Script:
- fragt nach ISO
- fragt nach Treiberordner (rekursiv)
- injiziert Treiber in install.wim
- optional zusaetzlich in boot.wim (Index 2)
- integriert .NET Framework 3.5 (NetFx3) aus sources\sxs

Empfehlung:
- install.wim immer injizieren
- boot.wim injizieren, wenn du WLAN bereits im Setup/WinPE brauchst (kein LAN vorhanden)

---

## 6) Autopilot Hardware-Hash Import (USB Workflow)

Dieses Tool importiert die Hardware-ID eines Windows Geraets automatisch in Microsoft Intune Autopilot und wartet optional auf die Profilzuweisung.

### 6.1 Voraussetzungen
- Windows 10/11 (Zielgeraet)
- PowerShell 5.1+
- Entra ID App Registration mit passenden Berechtigungen
- USB Stick (empfohlen)

---

## 7) Setup (einmalig): Entra ID App Registration erstellen

### Schritt 1: createApp.ps1 ausfuehren
1. PowerShell als Administrator oeffnen
2. createApp.ps1 ausfuehren:

```powershell
cd C:\Users\<USER>\Downloads\Autopilot
.\createApp.ps1
```

3. Im Browser anmelden (Global Admin Account)

Das Script erstellt automatisch:
- Entra ID App Registration
- Client Secret (2 Jahre)
- API Permissions
- JSON Config: IG-MgtTool-AutoApp_config.json

Dateien in C:\Temp:
- IG-MgtTool-AutoApp_config.json (wichtig)
- IG-MgtTool-AutoApp_credentials.txt (Backup)
- optional Zertifikate

### Schritt 2: Admin Consent erteilen (falls noetig)
URL aus dem Output oeffnen (als Global Admin):
https://login.microsoftonline.com/<TenantID>/adminconsent?client_id=<AppID>

---

## 8) USB Stick vorbereiten

Kopiere diese Dateien z. B. nach E:\Autopilot:

```
E:\Autopilot\
├── Start-Autopilot.bat
├── Run-AutopilotWithExternalAppConfig.ps1
├── get-windowsautopilotinfocommunity.ps1
├── wrapper-config.json
└── IG-MgtTool-AutoApp_config.json
```

---

## 9) wrapper-config.json konfigurieren

Beispiel:

```json
{
  "GroupTag": "DEIN-GROUPTAG",
  "OutputFolder": ".",
  "AppConfigPath": "IG-MgtTool-AutoApp_config.json",
  "AutopilotScriptPath": "get-windowsautopilotinfocommunity.ps1",
  "Assign": true,
  "Reboot": false
}
```

Parameter:
- GroupTag: Ziel GroupTag fuer Autopilot
- OutputFolder: "." speichert CSV/Logs auf USB
- Assign: true wartet auf Profilzuweisung
- Reboot: true rebootet nach Assignment (optional)

---

## 10) Ausfuehrung

### 10.1 Auf installiertem Windows (oder wenn du schon Desktop hast)
1. USB Stick einstecken
2. Start-Autopilot.bat als Administrator ausfuehren

Script macht:
- HWID erfassen
- Upload nach Autopilot
- GroupTag setzen
- optional warten auf Profilzuweisung (Assign=true)
- CSV + Log auf USB speichern

Output:
- HWID-<SERIAL>-<DATE>.csv
- autopilot-log.txt

### 10.2 Waehrend OOBE / Setup (Shift+F10)
1. Shift+F10
2. PowerShell starten:
```cmd
powershell.exe
```
3. Zum USB wechseln:
```powershell
cd E:\Autopilot
```
4. Start:
```powershell
.\Start-Autopilot.bat
```

---

## 11) Troubleshooting (kurz)

### Script cannot be loaded - not digitally signed
Workaround:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Run-AutopilotWithExternalAppConfig.ps1
```

### Geraet erscheint nicht in Autopilot
- autopilot-log.txt pruefen
- Permissions: DeviceManagementServiceConfig.ReadWrite.All
- Admin Consent erteilt?
- etwas warten (dynamische Gruppen)

### Assign haengt
- kein Autopilot Profil zugewiesen (GroupTag/Gruppe)
- Intune Profilzuweisung pruefen

### ClientSecret expired
- neues Secret erstellen (createApp.ps1 erneut)

---

## 12) Empfohlener Gesamt-Workflow

1) Installationsmedium vorbereiten
- WIM mit NetFx3 + WLAN Treiber erstellen (install.wim, optional boot.wim)
- autounattend.xml mit WLAN Profil und Setup-Automation erstellen

2) Staging pro Geraet
- Windows installieren (autounattend reduziert Klicks, WLAN steht)
- im OOBE/Setup via USB: HWID Import + GroupTag setzen
- optional warten auf Assignment, optional reboot
- anschliessend Autopilot OOBE / Enrollment durchlaufen lassen
