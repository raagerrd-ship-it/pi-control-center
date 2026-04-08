# Pi Dashboard

Dashboard för att övervaka och hantera tjänster på en **Raspberry Pi Zero 2 W**.  
Öppnas via mobilen i webbläsaren — ingen app behövs.

---

## Funktioner

- 📊 **Systemövervakning** — CPU, temperatur, RAM, disk, drifttid
- 🔧 **Tjänsthantering** — starta, stoppa, omstart per tjänst
- 📦 **Uppdateringar** — versionskontroll och one-click uppdatering
- 📋 **Loggar** — visa installations- och uppdateringsloggar
- 📱 **Mobilanpassad** — pull-to-refresh, optimerad för små skärmar
- 🌙 **Dark theme** — alltid mörkt
- 💡 **Status-LED** — blinkar under installation, fast sken när klart

## Krav

| Komponent | Minimum |
|-----------|---------|
| Hårdvara | Raspberry Pi Zero 2 W (eller nyare) |
| OS | Raspberry Pi OS Lite (Bookworm) |
| RAM | 512 MB |
| SD-kort | 8 GB+ |
| Nätverk | WiFi (konfigurerat via Pi Imager) |

## Snabbinstallation (SSH)

### 1. Flasha SD-kort

Använd [Raspberry Pi Imager](https://www.raspberrypi.com/software/) och konfigurera:
- **OS:** Raspberry Pi OS Lite (64-bit)
- **Användarnamn/lösenord:** valfritt (t.ex. `pi`)
- **WiFi:** ditt hemnätverk
- **SSH:** aktivera

### 2. Starta Pi:n och SSH:a in

```bash
ssh pi@<pi-ip>
```

> **Tips:** Hitta IP:n via din router, eller prova `pi@raspberrypi.local`

### 3. Kör installationsscriptet

```bash
curl -sL https://raw.githubusercontent.com/YOUR_USER/pi-dashboard/main/public/pi-scripts/first-boot-setup.sh | sudo bash
```

Med eget repo:

```bash
curl -sL <url>/first-boot-setup.sh | sudo PI_DASHBOARD_REPO=https://github.com/ditt-repo.git bash
```

### 4. Klart!

Öppna **http://\<pi-ip\>** i mobilen. Dashboarden körs på port 80 via Nginx.

---

## Alternativ: SD-kort förberedelse

Om du vill att Pi:n ska installera allt automatiskt vid första boot (utan SSH):

```bash
./public/pi-scripts/prep-sd-card.sh /mnt/rootfs https://github.com/YOUR_USER/pi-dashboard.git
```

---

## Vad installeras?

| Steg | Beskrivning |
|------|-------------|
| Swap | 512 MB swapfil (krävs för npm på 512 MB RAM) |
| Node.js | v20 LTS via NodeSource |
| Nginx | Reverse proxy på port 80 |
| Dashboard | React-app byggd och servad via Nginx |
| API | Bash-baserat REST-API på port 8585 |
| Systemd | Tjänster för API + autostart |

## LED-indikator under installation

| Mönster | Betydelse |
|---------|-----------|
| 🔵 Långsam blink (1s) | Väntar på nätverk |
| 🔵 Snabb blink (0.2s) | Installerar |
| 🔵 Fast sken | Klart! |

## API-endpoints (port 8585)

| Endpoint | Metod | Beskrivning |
|----------|-------|-------------|
| `/api/status` | GET | Systemstatus (CPU, RAM, disk, tjänster) |
| `/api/versions` | GET | Lokala och remote-versioner |
| `/api/update/:app` | POST | Starta uppdatering |
| `/api/install/:app` | POST | Installera en tjänst |
| `/api/service/:app/:action` | POST | start / stop / restart |
| `/api/update-log/:app` | GET | Uppdateringslogg |
| `/api/install-log/:app` | GET | Installationslogg |

## Tjänster

- **Lotus Lantern Control** — port 3001
- **Cast Away Web** — port 3000
- **Sonos Gateway** — port 3002

## Felsökning

| Problem | Lösning |
|---------|---------|
| Kan inte ansluta | Kontrollera WiFi, prova `ping <pi-ip>` |
| Installation fastnade | `cat /var/log/pi-dashboard-setup.log` |
| Kör om installation | `sudo rm /opt/.pi-dashboard-installed && sudo bash ~/pi-dashboard/public/pi-scripts/first-boot-setup.sh` |
| LED blinkar fortfarande | Scriptet väntar på nätverk — kontrollera WiFi |

## Utveckling

```bash
npm install
npm run dev
```

Startar på `http://localhost:8080`. Utan Pi-anslutning visas demo-data automatiskt.

## Licens

MIT
