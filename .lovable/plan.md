

## Implementeringsplan: Dynamiskt tjänsteregister + gemensam logg

Denna plan omvandlar dashboarden från hårdkodade tjänster till ett dynamiskt register via `services.json`, lägger till installationsdialog med port/core-val, avinstallation, och ersätter alla per-tjänst-loggar med en enda gemensam aktivitetslogg.

---

### Steg 1: Skapa `public/services.json`

Tjänsteregistret med metadata — ingen port/core (dessa väljs vid installation):

```json
[
  {
    "key": "lotus-lantern",
    "name": "Lotus Lantern Control",
    "repo": "https://github.com/raagerrd-ship-it/lotus-light-link.git",
    "installDir": "/opt/lotus-light",
    "installScript": "pi/setup-lotus.sh",
    "updateScript": "/opt/lotus-light/pi/dashboard-update.sh",
    "uninstallScript": "pi/uninstall.sh",
    "service": "lotus-light"
  },
  {
    "key": "cast-away",
    "name": "Cast Away Web",
    "repo": "https://github.com/raagerrd-ship-it/hromecast.git",
    "installDir": "$HOME/.local/share/cast-away",
    "installScript": "bridge-pi/install-linux.sh",
    "updateScript": "$HOME/.local/share/hromecast/bridge-pi/update.sh",
    "uninstallScript": "bridge-pi/uninstall.sh",
    "service": "cast-away"
  },
  {
    "key": "sonos-gateway",
    "name": "Sonos Gateway",
    "repo": "https://github.com/raagerrd-ship-it/sonos-gateway.git",
    "installDir": "$HOME/.local/share/sonos-proxy",
    "installScript": "bridge/install-linux.sh",
    "updateScript": "$HOME/.local/share/sonos-proxy/bridge/update.sh",
    "uninstallScript": "bridge/uninstall.sh",
    "service": "sonos-proxy"
  }
]
```

---

### Steg 2: Uppdatera `pi-dashboard-api.sh`

- **Ta bort** alla 7 `declare -A`-block (rad 30–76)
- **Läs** `services.json` med `jq` vid uppstart och bygg arrayer dynamiskt
- **Läs/skriv** `/etc/pi-dashboard/assignments.json` för port/core per installerad tjänst
- **Nytt endpoint**: `GET /api/available-services` — returnerar `services.json`
- **Nytt endpoint**: `POST /api/uninstall/{app}` — stoppar tjänst, kör `uninstallScript` om finns, tar bort från `assignments.json`
- **Uppdatera** `do_install` att läsa `port` och `core` från POST body och skicka som `--port X --core Y` till installationsskript, samt spara till `assignments.json`
- **Uppdatera** `build_status_json` att iterera över dynamisk tjänstlista
- **Uppdatera** `GET /api/versions` att iterera dynamiskt
- **Ta bort** `lotus-update.timer` från `install_lotus_lantern` (ingen auto-update)

---

### Steg 3: Uppdatera `update-dashboard.sh`

Lägg till rad som kopierar `services.json` till API-katalogen vid deploy:
```bash
sudo cp "$DASHBOARD_DIR/public/services.json" /var/www/pi-dashboard/
```

---

### Steg 4: Skapa gemensam logg-hook (`src/hooks/useActivityLog.ts`)

React context som exponerar `addEntry(source, message, type)`. Lagrar max 100 poster med tidsstämpel. Alla komponenter skriver till samma logg.

---

### Steg 5: Skapa `src/components/ActivityLog.tsx`

Ersätter `ConnectionLog.tsx`. Renderar den gemensamma loggen med format:
```
12:34:54 [SYSTEM] Ansluten till Pi
12:48:23 [SONOS GATEWAY] Startad
```
Behåller scroll-area med auto-scroll.

---

### Steg 6: Uppdatera `src/lib/api.ts`

- Ny typ `ServiceDefinition` (key, name, repo, installDir, installScript, updateScript, uninstallScript, service)
- Ny `fetchAvailableServices(): Promise<ServiceDefinition[]>`
- Uppdatera `triggerInstall(app, port, core)` att skicka `{ port, core }` i body
- Ny `triggerUninstall(app: string)`

---

### Steg 7: Skapa `src/components/InstallDialog.tsx`

Dialog som öppnas vid klick på "Installera":
- **Port** — nummerfält, föreslår nästa lediga (3000+)
- **CPU Core** — dropdown, Core 0 markerad "Reserverad (Dashboard)", använda cores markerade
- **RAM-varning** om < 100MB ledigt
- Validering: blockerar om port redan upptagen

---

### Steg 8: Uppdatera `src/components/ServiceCard.tsx`

- Använd `InstallDialog` istället för direkt `onInstall`
- Lägg till "Avinstallera"-knapp med bekräftelsedialog
- Visa vald port och core
- **Ta bort** `LogViewer` och `LogProvider` — all loggning sker centralt

---

### Steg 9: Uppdatera `src/hooks/useServiceUpdate.ts`

- Logga alla åtgärder (install, update, start, stop, restart, uninstall) till global logg via `addEntry`
- Lägg till `startUninstall(app)` funktion

---

### Steg 10: Uppdatera `src/hooks/useSystemStatus.ts`

- Flytta anslutningsmeddelanden till global logg med källa `[SYSTEM]`
- Ta bort lokal `logs`-state

---

### Steg 11: Uppdatera `src/pages/Index.tsx`

- Hämta tjänstlistan från `fetchAvailableServices()` istället för `settings.services`
- Slå ihop med status-data för att rendera kort dynamiskt
- Byt `ConnectionLog` mot `ActivityLog`
- Logga dashboard-uppdateringar till global logg

---

### Steg 12: Förenkla `src/components/Settings.tsx`

- Ta bort `ServiceConfig`-interface och `services`-arrayen
- Behåll bara `deviceLabel`

---

### Steg 13: Ta bort överflödiga filer

- `src/components/ConnectionLog.tsx`
- `src/components/LogViewer.tsx`

---

### Steg 14: Skapa `public/SERVICE-INTEGRATION.md`

Dokumentation för tjänsteutvecklare med krav:

```markdown
# Service Integration Guide — Pi Dashboard

## Installation Script Requirements

Your install script will receive two arguments:
  --port PORT    The port your service should listen on
  --core CORE    The CPU core (0-3) your service should be pinned to

Example: `bash install-linux.sh --port 3001 --core 1`

Parse them like this:
  PORT=3000; CORE=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) PORT="$2"; shift 2 ;;
      --core) CORE="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

Use PORT in your service's Environment= or config file.
Use CORE in your systemd unit's AllowedCPUs= directive.

## Uninstall Script

Provide an uninstall script that:
1. Stops and disables the systemd service
2. Removes the service file
3. Optionally removes installed files

## Logging

The dashboard handles all user-facing logging centrally.
Your scripts should write output to stdout/stderr as usual —
the dashboard captures it automatically.
No special logging integration is needed.
```

---

### Filer som ändras/skapas

| Fil | Åtgärd |
|-----|--------|
| `public/services.json` | **Ny** |
| `public/SERVICE-INTEGRATION.md` | **Ny** |
| `public/pi-scripts/pi-dashboard-api.sh` | Stor omskrivning |
| `public/pi-scripts/update-dashboard.sh` | Liten ändring |
| `src/hooks/useActivityLog.ts` | **Ny** |
| `src/components/ActivityLog.tsx` | **Ny** |
| `src/components/InstallDialog.tsx` | **Ny** |
| `src/lib/api.ts` | Nya typer och funktioner |
| `src/components/ServiceCard.tsx` | Omarbetad |
| `src/hooks/useServiceUpdate.ts` | Utökad med uninstall + loggning |
| `src/hooks/useSystemStatus.ts` | Förenklad |
| `src/pages/Index.tsx` | Dynamisk tjänstlista + ActivityLog |
| `src/components/Settings.tsx` | Förenklad |
| `src/components/ConnectionLog.tsx` | **Ta bort** |
| `src/components/LogViewer.tsx` | **Ta bort** |

