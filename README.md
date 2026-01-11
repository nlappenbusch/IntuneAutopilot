# Windows Autopilot Hardware-Hash Import - HowTo

Dieses Tool importiert die Hardware-ID eines Windows-Geräts automatisch in Microsoft Intune Autopilot und wartet optional auf die Profilzuweisung.

## 📋 Voraussetzungen

- Windows 10/11 PC (auf dem die Hardware-Hash erfasst werden soll)
- PowerShell 5.1 oder höher
- Entra ID App Registration mit entsprechenden Berechtigungen
- USB-Stick (empfohlen für portable Verwendung)

---

## 🚀 Setup (Einmalig)

### Schritt 1: Entra ID App Registration erstellen

1. **PowerShell als Administrator öffnen**
2. **createApp.ps1 ausführen:**
   ```powershell
   cd C:\Users\<USER>\Downloads\Autopilot
   .\createApp.ps1
   ```

3. **Im Browser anmelden** (Global Admin Account)
4. **Das Script erstellt automatisch:**
   - Entra ID App Registration
   - Client Secret (2 Jahre gültig)
   - Zertifikat (optional)
   - Alle benötigten API-Permissions
   - JSON-Config-Datei: `IG-MgtTool-AutoApp_config.json`

5. **Dateien werden erstellt in `C:\Temp`:**
   - `IG-MgtTool-AutoApp_config.json` ← **Diese Datei brauchst du!**
   - `IG-MgtTool-AutoApp_credentials.txt` (Backup)
   - Zertifikat-Dateien (optional)

6. **Admin Consent erteilen** (wenn nicht automatisch geschehen):
   - URL aus dem Output kopieren: `https://login.microsoftonline.com/<TenantID>/adminconsent?client_id=<AppID>`
   - Im Browser als Global Admin öffnen
   - Auf "Akzeptieren" klicken

### Schritt 2: Dateien auf USB-Stick kopieren

Kopiere folgende Dateien in einen Ordner auf dem USB-Stick (z.B. `E:\Autopilot`):

```
E:\Autopilot\
├── Start-Autopilot.bat                         ← Hauptprogramm (zum Starten)
├── Run-AutopilotWithExternalAppConfig.ps1      ← PowerShell-Wrapper
├── get-windowsautopilotinfocommunity.ps1       ← Autopilot-Script (Community-Version)
├── wrapper-config.json                          ← Deine Konfiguration
└── IG-MgtTool-AutoApp_config.json              ← App-Credentials (aus Schritt 1)
```

### Schritt 3: wrapper-config.json anpassen

Öffne `wrapper-config.json` und passe folgende Werte an:

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

**Parameter:**
- **GroupTag:** Der Group Tag für Autopilot (z.B. `"HBL-Intern"`, `"NLA-TEST"`)
- **OutputFolder:** `"."` = CSV wird auf USB-Stick gespeichert
- **Assign:** `true` = Wartet auf Autopilot-Profilzuweisung
- **Reboot:** `false` = Kein automatischer Neustart (empfohlen für manuelle Kontrolle)

---

## 💻 Verwendung

### Auf dem Zielgerät (Windows OOBE oder bereits installiert)

1. **USB-Stick einstecken** (z.B. Laufwerk `E:`)

2. **Als Administrator ausführen:**
   - Rechtsklick auf `Start-Autopilot.bat`
   - "Als Administrator ausführen"

3. **Das Script:**
   - Erfasst die Hardware-Hash automatisch
   - Lädt sie hoch nach Intune Autopilot
   - Weist den GroupTag zu
   - Wartet auf Profilzuweisung (wenn `Assign: true`)
   - Erstellt CSV-Backup auf dem USB-Stick
   - Schreibt Log-Datei: `autopilot-log.txt`

4. **Ausgabe-Dateien auf USB-Stick:**
   ```
   E:\Autopilot\
   ├── HWID-<SERIALNUMMER>-2026-01-11.csv    ← Hardware-Hash (Backup)
   └── autopilot-log.txt                      ← Vollständiges Log
   ```

### Während Windows Setup (OOBE)

1. **Shift + F10** drücken → CMD öffnet sich
2. **PowerShell starten:**
   ```cmd
   powershell.exe
   ```
3. **Zum USB-Stick wechseln:**
   ```powershell
   cd E:\Autopilot
   ```
4. **Script ausführen:**
   ```powershell
   .\Start-Autopilot.bat
   ```

---

## 📊 Was passiert im Hintergrund?

### 1. Hardware-Hash Erfassung
- Liest Seriennummer, Modell, Hardware-ID vom BIOS/UEFI
- Erstellt CSV-Datei im Autopilot-Format

### 2. Upload zu Intune
- Authentifiziert sich per App-only Auth (Client Secret)
- Importiert Gerät in Intune Autopilot
- Setzt den GroupTag

### 3. Assign (optional)
- Wartet alle 30 Sekunden auf Profilzuweisung
- Zeigt Fortschritt an: `"Waiting for X of Y devices to be assigned"`
- Beendet sich, sobald Profil zugewiesen wurde

### 4. Reboot (optional)
- Startet Gerät neu (nur wenn `Reboot: true`)
- Notwendig, damit Autopilot-Profil angewendet wird

---

## 🔧 Troubleshooting

### "Script cannot be loaded - not digitally signed"
→ Die `.bat`-Datei umgeht das automatisch. Alternativ:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Run-AutopilotWithExternalAppConfig.ps1
```

### "Gerät erscheint nicht in Intune Autopilot"
1. **Log prüfen:** `autopilot-log.txt` auf Fehler checken
2. **Berechtigungen prüfen:** App braucht `DeviceManagementServiceConfig.ReadWrite.All`
3. **Admin Consent:** Muss erteilt sein (siehe Setup Schritt 1)
4. **Warten:** Bei dynamischen Gruppen kann es Minuten dauern

### "Assign hängt ewig"
- Kein Autopilot-Profil wurde dem GroupTag/der Gruppe zugewiesen
- Lösung: In Intune ein Profil erstellen und der Gruppe zuweisen

### "ClientSecret expired"
- Client Secret ist 2 Jahre gültig
- Lösung: `createApp.ps1` erneut ausführen → neue App erstellen

### CSV wird auf C:\Temp gespeichert statt USB
- `wrapper-config.json` prüfen → `"OutputFolder": "."` muss gesetzt sein

---

## 📝 Dateien Übersicht

| Datei | Beschreibung |
|-------|--------------|
| **Start-Autopilot.bat** | Hauptprogramm zum Starten (umgeht Execution Policy) |
| **Run-AutopilotWithExternalAppConfig.ps1** | PowerShell-Wrapper, liest Configs und ruft Autopilot-Script auf |
| **get-windowsautopilotinfocommunity.ps1** | Community-Version des Microsoft Autopilot-Scripts |
| **wrapper-config.json** | Deine Konfiguration (GroupTag, Assign, Reboot) |
| **IG-MgtTool-AutoApp_config.json** | App-Credentials (TenantId, AppId, ClientSecret) |
| **createApp.ps1** | Setup-Tool zum Erstellen der Entra ID App Registration |
| **autopilot-log.txt** | Wird beim Ausführen erstellt - komplettes Log |
| **HWID-*.csv** | Wird beim Ausführen erstellt - Hardware-Hash Backup |

---

## 🔐 Sicherheitshinweise

- **Client Secret schützen!** Die `IG-MgtTool-AutoApp_config.json` enthält sensible Daten
- USB-Stick verschlüsseln (BitLocker) empfohlen
- Client Secret regelmäßig rotieren (alle 1-2 Jahre)
- App-Berechtigungen nur bei Bedarf erweitern

---

## 🎯 Workflow-Übersicht

```
┌─────────────────────────────────────────────────────────────┐
│ 1. VORBEREITUNG (Einmalig)                                  │
│    - createApp.ps1 ausführen                                │
│    - App Registration erstellen                             │
│    - Config-Dateien auf USB-Stick kopieren                  │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. AUF JEDEM GERÄT                                          │
│    - USB-Stick einstecken                                   │
│    - Start-Autopilot.bat als Admin ausführen                │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. AUTOMATISCHER ABLAUF                                     │
│    ├─ Hardware-Hash erfassen                                │
│    ├─ Upload zu Intune Autopilot                            │
│    ├─ GroupTag zuweisen                                     │
│    ├─ [Optional] Warten auf Profilzuweisung                 │
│    ├─ CSV + Log auf USB speichern                           │
│    └─ [Optional] Reboot                                     │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. FERTIG                                                   │
│    - Gerät ist in Intune Autopilot registriert              │
│    - Autopilot-Profil zugewiesen (wenn Assign=true)         │
│    - Bereit für Deployment                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 📞 Support

Bei Problemen:
1. `autopilot-log.txt` prüfen
2. Intune Portal: **Devices → Windows → Windows enrollment → Devices**
3. Entra ID Portal: **App registrations** → Berechtigungen prüfen

---

**Erstellt:** 2026-01-11  
**Version:** 1.0
