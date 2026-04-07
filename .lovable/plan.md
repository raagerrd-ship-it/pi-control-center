

# Pi Dashboard — Enkel lokal version

En mörk, minimal dashboard som körs lokalt på din Pi Zero 2 W. Ingen Supabase, inget fjärrläge — bara en statisk sida som pollar Pi:ns eget API.

## Vad som byggs

### 1. Dashboard-UI (React)

**SystemMonitor** — Toppen av sidan:
- CPU-användning (%), RAM (använt/totalt), CPU-temperatur (°C), disk-användning, uptime
- Visuella progress-bars, uppdateras var 5:e sekund via polling

**ServiceCard** (3 st) — Under systemövervakningen:
- **Lotus Lantern Control** — port 3001, länk till `:3001`
- **Cast Away Web** — port 3000, länk till `:3000`
- **Sonos Gateway** — port 3002, länk till `:3002`
- Varje kort: statusindikator (online/offline via fetch), nuvarande git-version (kort hash), **"Uppdatera"-knapp** som triggar respektive apps update-skript
- Uppdateringsstatus visas inline (idle → kollar → uppdaterar → klar/fel)

**Settings** — Konfiguration av Pi:ns IP-adress, sparas i localStorage. Portar är förkonfigurerade men ändringsbara.

### 2. Pi-skript (genereras i `public/pi-scripts/`)

**`pi-dashboard-api.sh`** — Liten HTTP-server (socat/netcat-baserad, ~50 rader):
- `GET /api/status` → JSON med CPU, temp, RAM, disk, uptime + tjänstestatus (port-check)
- `POST /api/update/lotus-lantern` → kör `/opt/lotus-light/pi/update-services.sh`
- `POST /api/update/cast-away` → kör `~/.local/share/cast-away/update.sh`
- `POST /api/update/sonos-gateway` → kör `~/sonos-proxy/update.sh`
- `GET /api/update-status/:app` → senaste uppdateringsresultat

**`pi-auto-update.sh`** — Bara för dashboarden:
- `git pull` → `npm run build` → kopiera till nginx-mapp
- Körs var timme via systemd-timer

**`install.sh`** — Installerar allt:
- Nginx, git, node
- Klonar dashboard-repo, bygger, konfigurerar nginx (port 80)
- Sätter upp dashboard-API som systemd-service
- Skapar timern för auto-update (1 gång/timme)
- Avaktiverar de tre apparnas egna update-timers

### 3. Filer som skapas/ändras

| Fil | Beskrivning |
|-----|-------------|
| `src/pages/Index.tsx` | Dashboard med SystemMonitor + ServiceCards |
| `src/components/SystemMonitor.tsx` | CPU/RAM/temp/disk-gauges |
| `src/components/ServiceCard.tsx` | Tjänstekort med uppdateringsknapp |
| `src/components/Settings.tsx` | IP/port-konfiguration (dialog) |
| `src/hooks/useSystemStatus.ts` | Polling var 5s mot `/api/status` |
| `src/hooks/useServiceUpdate.ts` | Trigger + status för manuell uppdatering |
| `src/lib/api.ts` | Fetch-wrapper mot Pi:ns lokala API |
| `src/index.css` | Mörkt tema-variabler |
| `public/pi-scripts/install.sh` | Installationsskript |
| `public/pi-scripts/pi-dashboard-api.sh` | Lokalt REST-API |
| `public/pi-scripts/pi-auto-update.sh` | Auto-update (bara dashboard) |

### 4. Design

- Mörkt tema: bakgrund `#0a0a0a`, kort `#141414`, accenter i dämpad grön/röd för status
- Monospace-typsnitt för systemdata (terminalkänsla)
- Kompakt layout optimerad för både desktop och mobil
- Inga animationer utöver subtila färgövergångar på statusändringar

