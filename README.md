# HowTo: Windows-Installationsmedium fuer Client-Staging mit Autopilot / Intune vorbereiten

## Ziel
Ziel ist es, bestehende Geraete moeglichst effizient in Windows Autopilot / Intune zu ueberfuehren –
ohne Benutzeranmeldung, ohne Passwort- oder MFA-Eingaben und ohne nervige Klickerei waehrend der Installation.

Das Staging soll:
- vollautomatisiert ablaufen
- WLAN direkt zur Verfuegung stellen (Autopilot benoetigt Internet)
- GroupTags setzen
- ohne manuelle Benutzerinteraktion funktionieren
- fuer viele Geraete parallel geeignet sein

Die Grundlage fuer den Autopilot-Teil ist hier beschrieben:
https://github.com/nlappenbusch/IntuneAutopilot

Dieses Dokument ergaenzt das Ganze um:
- WLAN-Treiber und WLAN-Profil im Installationsmedium
- Datentraeger-Setup ohne Klickerei
- Einsatz einer autounattend.xml
- integrierten Autopilot Hardware-Hash Import

---

## Grundproblem bei Autopilot-Staging

Autopilot setzt voraus:
- funktionierende Internetverbindung waehrend OOBE
- moeglichst kein lokales Benutzerkonto
- saubere Namensvergabe durch Intune
- keine manuelle Eingabe von WLAN-Passwoertern an vielen Geraeten

Ohne Vorbereitung fuehrt das in der Praxis zu:
- manueller WLAN-Konfiguration pro Geraet
- Setup-Abbruechen
- inkonsistenten Installationen
- Zeitverlust beim gleichzeitigen Staging vieler Clients

---

## Loesung: Autounattend.xml + WLAN-Treiber + WLAN-Profil + HWID Import

### Bausteine
1. Angepasstes Windows-Installationsmedium
   - WLAN-Treiber bereits integriert
   - .NET Framework 3.5 bereits integriert
2. Autounattend.xml
   - automatisiert Setup-Schritte
   - konfiguriert WLAN
   - vermeidet manuelle Klicks
3. Autopilot-Import per Script
   - GroupTag
   - Tenant-Zuordnung
   - ohne User-Login

---

## Autounattend.xml erstellen (Schneegans Tool)

Zur Erstellung der autounattend.xml wird folgendes Tool empfohlen:
https://schneegans.de/windows/unattend-generator/

---

## Wichtige Einstellungen im Schneegans-Tool

### Sprache und Region

Windows-Installationssprache:
- English (muss zur ISO passen)

Sprachen und Tastaturen (Reihenfolge relevant):
1. German (Switzerland) – Swiss German
2. German (Germany) – German
3. Spanish (Spain) – Spanish

Home location:
- Switzerland

---

### Computername

Unbedingt setzen auf:
Let Windows generate a random computer name

Nur so kann Intune spaeter die Namensvergabe gemaess Naming Policy uebernehmen.

---

### Partitionierung und Datentraeger

Empfohlene Einstellung:
Let Windows Setup wipe, partition and format your hard drive

Partition Layout:
- GPT
- EFI System Partition (ESP): 300 MB

Keine interaktive Auswahl, keine manuelle Klickerei.

---

### Benutzerkonten (GANZ WICHTIG)

Fuer eine saubere Autopilot-Experience MUSS gesetzt sein:
Add a Microsoft (online) user account interactively during Windows Setup

Lokale Offline-Konten duerfen nur temporaer existieren und nicht fuer den finalen Login genutzt werden.

---

### WLAN / Wi-Fi Setup

Empfohlene Option:
Configure Wi-Fi using an XML file

Das WLAN-Profil kann von einem Referenzgeraet exportiert werden:
netsh wlan export profile key=clear

Der Inhalt der erzeugten XML-Datei kann direkt im Schneegans-Tool eingefuegt werden.

Wichtig:
- Kein echtes WLAN-Passwort im Klartext im Tool belassen
- <keyMaterial> nach Download der autounattend.xml anpassen

---

## WLAN-Treiber im Installationsmedium

Um WLAN- (und weitere) Treiber zu integrieren, kann folgendes Script verwendet werden:
Build-Windows11-WIM-NetFx3.ps1

Funktion:
- fragt nach einem Treiberordner (INF, SYS, CAT)
- injiziert Treiber rekursiv in install.wim
- optional auch in boot.wim (WinPE)
- integriert zusaetzlich .NET Framework 3.5

Empfehlung:
Drivers\WiFi
Drivers\LAN
Drivers\Storage

---

# Windows Autopilot Hardware-Hash Import – HowTo

Dieses Tool importiert die Hardware-ID eines Windows-Geraets automatisch in Microsoft Intune Autopilot und wartet optional auf die Profilzuweisung.

## Voraussetzungen
- Windows 10/11 PC
- PowerShell 5.1 oder hoeher
- Entra ID App Registration mit passenden Berechtigungen
- USB-Stick (empfohlen)

---

## Setup (einmalig)

### Entra ID App Registration erstellen

```powershell
cd C:\Users\<USER>\Downloads\Autopilot
.\createApp.ps1
```

Das Script erstellt:
- Entra ID App Registration
- Client Secret (2 Jahre)
- API Permissions
- IG-MgtTool-AutoApp_config.json (wichtig)

Admin Consent erteilen (falls noetig):
https://login.microsoftonline.com/<TenantID>/adminconsent?client_id=<AppID>

---

## USB-Stick vorbereiten

```
E:\Autopilot\
├── Start-Autopilot.bat
├── Run-AutopilotWithExternalAppConfig.ps1
├── get-windowsautopilotinfocommunity.ps1
├── wrapper-config.json
└── IG-MgtTool-AutoApp_config.json
```

---

## wrapper-config.json

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

---

## Verwendung

### Auf dem Zielgeraet
- USB-Stick einstecken
- Start-Autopilot.bat als Administrator ausfuehren

### Im OOBE
- Shift + F10
- powershell.exe
- cd E:\Autopilot
- .\Start-Autopilot.bat

---

## Ergebnis

- HWID wird importiert
- GroupTag gesetzt
- optional Profilzuweisung abgewartet
- CSV und Log auf USB gespeichert

---

## Zusammenfassung

Mit diesem integrierten Ansatz lassen sich Windows-Geraete:
- ohne manuelle WLAN-Konfiguration
- ohne Benutzerlogin
- ohne MFA
- reproduzierbar und skalierbar

in Autopilot / Intune ueberfuehren.
