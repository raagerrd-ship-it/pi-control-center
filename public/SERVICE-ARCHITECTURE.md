# Tjänstearkitektur — Pi Control Center

> **Komplett guide för hur tjänster/appar ska byggas och integreras med Pi Control Center.**

---

## Filosofi

Pi Control Center är **operativsystemet**. Tjänsterna är **program** som installeras och körs under strikta villkor. Ingen tjänst får påverka systemet — den får bara använda de resurser (CPU-kärna, minne, portar, katalog) som tilldelats den.

Varje tjänst delas upp i två delar:

| Del | Roll | Analogi |
|-----|------|---------|
| **Motor** (engine) | All logik, API, datahantering, integrationer | En maskin som alltid snurrar |
| **UI** (frontend) | Visuellt gränssnitt, fjärrkontroll mot motorn | Skärm/fjärrkontroll — kan stängas av utan att maskinen stannar |

**Motorn ska vara stabil och bara fungera.** Den startar automatiskt vid boot, startar om sig själv om den kraschar, och påverkas inte av att UI:t uppdateras, startas om eller stängs av.

**UI:t är en fjärrkontroll.** Det pratar med motorn via HTTP (REST API). Det kan uppdateras, bytas ut eller stängas av helt utan att tjänstens kärnfunktion påverkas.

---

## Portkonvention

Varje tjänst tilldelas **en port** av användaren vid installation (t.ex. `3002`). Pi Control Center beräknar sedan automatiskt:

| Komponent | Port | Exempel |
|-----------|------|---------|
| **UI** (frontend) | Vald port | `3002` |
| **Motor** (engine/backend) | Vald port **+ 50** | `3052` |

Båda portarna finns som miljövariabler i båda processerna:

```
PORT=<komponentens egen port>
UI_PORT=3002
ENGINE_PORT=3052
```

Det innebär att UI:t alltid vet var motorn lyssnar (`ENGINE_PORT`), och motorn vet var UI:t ligger (`UI_PORT`) om den behöver länka dit.

### Reserverade portar

| Port | Användning |
|------|-----------|
| `80` | nginx → Pi Control Center UI |
| `8585` | Pi Dashboard API |
| `3001–3003` | Tjänsternas UI-portar (tilldelad av användaren) |
| `3051–3053` | Tjänsternas motor-portar (auto-beräknad +50) |

---

## Arkitektur: Motor vs UI

### Motorn (Engine)

Motorn är hjärtat i tjänsten. Den hanterar all affärslogik och exponerar ett REST API som UI:t (och potentiellt andra klienter) använder.

**Krav på motorn:**

1. **Node.js-process** — Startas med `node {entrypoint}`
2. **Lyssnar på `process.env.PORT`** (= `ENGINE_PORT`, t.ex. 3052)
3. **Exponerar ett REST API** — minst dessa endpoints:
   - `GET /api/version` → `{ "version": "1.2.3" }`
   - `GET /api/health` → `{ "status": "ok" }` (för framtida hälsokontroller)
   - Appspecifika endpoints (`GET /api/devices`, `POST /api/play`, etc.)
4. **Ingen egen UI** — motorn serverar *inte* HTML/CSS/JS
5. **Stateless vid restart** — spara persistent data i filer (inom `installDir`), inte i minnet
6. **Hanterar SIGTERM graciöst** — stäng ner connections och spara state vid shutdown
7. **`alwaysOn: true`** — systemd startar om motorn automatiskt om den kraschar

**Exempelmotorn:**

```javascript
// engine/index.js
import express from 'express';

const app = express();
const PORT = process.env.PORT || 3052;

app.get('/api/version', (req, res) => {
  res.json({ version: '1.0.0' });
});

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', uptime: process.uptime() });
});

// --- Appspecifik logik ---
app.get('/api/devices', (req, res) => {
  // ... returnera enheter
});

app.post('/api/play', (req, res) => {
  // ... starta uppspelning
});

app.listen(PORT, () => {
  console.log(`Engine listening on port ${PORT}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Shutting down gracefully...');
  // Spara state, stäng connections
  process.exit(0);
});
```

### UI:t (Frontend)

UI:t är en statisk webbsida (HTML/CSS/JS) som serveras med `npx serve` och pratar med motorn via fetch/AJAX.

**Krav på UI:t:**

1. **Statisk build** — `npm run build` → `dist/`-katalog
2. **Serveras med `npx serve`** på `UI_PORT` (t.ex. 3002)
3. **Konfigurerar motor-URL dynamiskt** — hittar motorn via:
   - Samma hostname, port + 50: `http://{window.location.hostname}:{UI_PORT + 50}`
   - Eller via `ENGINE_PORT` om den bäddas in
4. **Kan stängas av** utan att påverka motorn
5. **`alwaysOn: false`** — kan vara avstängd

**Exempel UI-konfiguration:**

```javascript
// src/config.ts
const UI_PORT = parseInt(window.location.port) || 3002;
const ENGINE_PORT = UI_PORT + 50;

export const API_BASE = `http://${window.location.hostname}:${ENGINE_PORT}`;
```

```javascript
// src/App.tsx
import { API_BASE } from './config';

const fetchDevices = async () => {
  const res = await fetch(`${API_BASE}/api/devices`);
  return res.json();
};
```

---

## services.json — Registrering

### Komponentbaserad tjänst (rekommenderat)

```json
{
  "key": "lotus-light",
  "name": "Lotus Light Link",
  "repo": "https://github.com/user/lotus-light-link.git",
  "releaseUrl": "https://api.github.com/repos/user/lotus-light-link/releases/latest",
  "installDir": "/opt/lotus-light",
  "installScript": "scripts/install.sh",
  "updateScript": "/opt/lotus-light/scripts/update.sh",
  "uninstallScript": "scripts/uninstall.sh",
  "components": {
    "engine": {
      "type": "node",
      "entrypoint": "engine/index.js",
      "service": "lotus-light-engine",
      "alwaysOn": true
    },
    "ui": {
      "type": "static",
      "entrypoint": "dist/",
      "service": "lotus-light-ui",
      "alwaysOn": false
    }
  }
}
```

### Legacy (ej rekommenderat, bakåtkompatibelt)

```json
{
  "key": "my-app",
  "name": "My App",
  "type": "node",
  "entrypoint": "server/index.js",
  "service": "my-app",
  "repo": "...",
  "installDir": "..."
}
```

Legacy-tjänster har en enda process som hanterar allt. De fungerar men saknar fördelarna med separation.

---

## Genererade systemd-tjänster

Pi Control Center skapar automatiskt systemd-units vid installation. Du behöver **inte** skapa dem själv.

### Motor-unit (genererad)

```ini
[Unit]
Description=lotus-light engine service
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/lotus-light
ExecStart=/usr/bin/node /opt/lotus-light/engine/index.js
Environment=PORT=3052
Environment=ENGINE_PORT=3052
Environment=UI_PORT=3002
CPUAffinity=2
AllowedCPUs=2
MemoryMax=128M
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/opt/lotus-light
PrivateTmp=true
NoNewPrivileges=true
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

### UI-unit (genererad)

```ini
[Unit]
Description=lotus-light ui service
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/lotus-light
ExecStart=/usr/bin/npx serve dist/ -l 3002 -s
Environment=PORT=3002
Environment=ENGINE_PORT=3052
Environment=UI_PORT=3002
CPUAffinity=2
AllowedCPUs=2
MemoryMax=128M
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/opt/lotus-light
PrivateTmp=true
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

### Viktiga skillnader

| Egenskap | Motor | UI |
|----------|-------|----|
| `Restart` | `always` — startar om oavsett exit-kod | `on-failure` — startar bara om vid krasch |
| `PORT` | `3052` (vald port + 50) | `3002` (vald port) |
| `ExecStart` | `node engine/index.js` | `npx serve dist/ -l 3002 -s` |

---

## Sandboxning & Isolering

Varje tjänst körs i en **sandlåda**. Det finns ingen möjlighet att bryta ut.

### CPU-isolering (hård gräns)

```ini
CPUAffinity=2       # Schemaläggningshint
AllowedCPUs=2       # HÅRD gräns via cgroups v2 — kan inte köra på andra kärnor
```

| Kärna | Reserverad för |
|-------|---------------|
| 0 | Pi Control Center + nginx + system |
| 1 | Tjänst 1 (motor + UI) |
| 2 | Tjänst 2 (motor + UI) |
| 3 | Tjänst 3 (motor + UI) |

Motor och UI på samma tjänst delar kärna — de är båda låsta till samma CPU.

### Minnestak

```ini
MemoryMax=128M
```

Om en process försöker använda mer än 128MB RAM kommer den att termineras av systemd (OOM kill). Tjänsten bör designas för att fungera inom detta tak.

### Filsystemslåsning

```ini
ProtectSystem=strict       # Hela /usr, /boot, /etc är skrivskyddade
ProtectHome=read-only      # $HOME är skrivskyddat
ReadWritePaths=/opt/lotus-light  # BARA sin egen katalog är skrivbar
PrivateTmp=true            # Eget isolerat /tmp
NoNewPrivileges=true       # Kan inte eskalera rättigheter
```

**Vad en tjänst INTE kan göra:**

- ❌ Ändra `/etc/hosts` eller `/etc/hostname`
- ❌ Ändra systemkonfiguration (locale, timezone, nätverksinställningar)
- ❌ Skriva utanför sin egen `installDir`
- ❌ Installera systempaket
- ❌ Starta processer på andra CPU-kärnor
- ❌ Använda mer än 128MB RAM
- ❌ Läsa andra tjänsters filer
- ❌ Eskalera rättigheter (sudo, setuid, etc.)

**Vad en tjänst KAN göra:**

- ✅ Läsa/skriva filer i sin `installDir`
- ✅ Lyssna på sin/sina tilldelade port(ar)
- ✅ Göra utgående HTTP-anrop (API:er, webhooks)
- ✅ Använda sin tilldelade CPU-kärna
- ✅ Skriva till sitt eget `/tmp` (isolerat)

---

## Repostruktur (rekommenderad)

```
my-service/
├── engine/                    # Motor (Node.js backend)
│   ├── index.js               # Entrypoint — lyssnar på process.env.PORT
│   ├── routes/                # API-routes
│   ├── services/              # Affärslogik
│   └── data/                  # Lokal datalagring (SQLite, JSON-filer)
├── ui/                        # Frontend (statisk)
│   ├── src/
│   │   ├── App.tsx
│   │   ├── config.ts          # API_BASE = hostname:ENGINE_PORT
│   │   └── ...
│   ├── dist/                  # Byggs av CI → serveras av npx serve
│   └── package.json
├── scripts/
│   ├── install.sh             # Fallback-installation (om ingen release finns)
│   ├── update.sh              # Uppdateringsskript
│   └── uninstall.sh           # Avinstallationsskript
├── .github/
│   └── workflows/
│       └── release.yml        # Bygger och publicerar dist.tar.gz
└── package.json               # Root package.json
```

### dist.tar.gz-struktur

GitHub Actions bygger och paketerar båda delarna:

```
dist.tar.gz
├── engine/
│   ├── index.js
│   ├── routes/
│   ├── services/
│   └── node_modules/          # Produktionsberoenden inkluderade
├── dist/                      # UI:ts build-output
│   ├── index.html
│   ├── assets/
│   └── ...
```

### GitHub Actions Workflow

```yaml
name: Build and Release
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    env:
      FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20

      # Bygg UI
      - name: Build UI
        working-directory: ui
        run: |
          npm ci
          npm run build

      # Förbered motor med prod-dependencies
      - name: Prepare Engine
        working-directory: engine
        run: |
          npm ci
          npm run build --if-present
          npm install --omit=dev --package-lock=false

      # Paketera
      - name: Create tarball
        run: tar czf dist.tar.gz engine/ ui/dist/

      # Publicera release
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: latest
          files: dist.tar.gz
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## Kommunikation: UI → Motor

UI:t ska **aldrig** ha egen affärslogik. All data hämtas från motorn via HTTP.

### Mönster

```
┌─────────────────┐         HTTP          ┌─────────────────┐
│                 │   GET /api/devices     │                 │
│    UI (3002)    │ ──────────────────────→│  Motor (3052)   │
│    Statisk      │                       │  Node.js        │
│    React app    │ ←─────────────────────│  Express API    │
│                 │   JSON response       │                 │
└─────────────────┘                       └─────────────────┘
       ↑                                         ↑
  Användaren                              Extern hårdvara,
  öppnar i                                nätverk, databas,
  webbläsaren                             integrationer
```

### CORS

Motorn måste tillåta requests från UI:ts port:

```javascript
// engine/index.js
import cors from 'cors';
app.use(cors());  // Tillåt alla origins (ok i lokalt nätverk)
```

### Realtidsuppdateringar (valfritt)

Om tjänsten behöver push-uppdateringar (t.ex. "ny enhet hittad"), använd **Server-Sent Events (SSE)** istället för WebSockets — lättare och fungerar bättre med `npx serve`:

```javascript
// Motor
app.get('/api/events', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'Access-Control-Allow-Origin': '*'
  });

  const send = (data) => res.write(`data: ${JSON.stringify(data)}\n\n`);

  // Skicka events...
  send({ type: 'device-found', device: { name: 'Vardagsrum' } });
});

// UI
const events = new EventSource(`${API_BASE}/api/events`);
events.onmessage = (e) => {
  const data = JSON.parse(e.data);
  // Uppdatera state...
};
```

---

## Uppdateringsflöde

### Release-baserad uppdatering (rekommenderat)

1. Utvecklaren pushar till `main`
2. GitHub Actions bygger och publicerar ny `dist.tar.gz`
3. Pi Dashboard visar "Uppdatering tillgänglig"
4. Användaren klickar "Uppdatera"
5. Dashboard laddar ner ny `dist.tar.gz`, ersätter filer
6. **Motorn startas om** (kort downtime, ~2 sekunder)
7. **UI:t startas om** (cachas ofta av webbläsaren ändå)

Uppdatering tar **~10 sekunder**.

### Vad händer vid motor-uppdatering?

Motorn får `SIGTERM` → sparar state → avslutas → systemd startar ny version.

Design din motor så att:
- **State sparas till disk** (inte bara i minnet)
- **Startup är snabb** (<2 sekunder)
- **Inga pågående operationer förloras** (köa dem eller gör dem idempotenta)

---

## Minnesoptimering (Pi Zero 2 W — 512MB RAM)

Hela systemet har 512MB RAM. Med dashboard + nginx + 3 tjänster (motor + UI vardera) behöver varje process vara sparsam.

### Riktlinjer

| Resurs | Budget per tjänst |
|--------|------------------|
| Motor-RAM | ≤60MB |
| UI-serve-RAM | ≤30MB |
| Totalt per kärna | ≤128MB (systemd-gräns) |

### Tips

1. **Undvik tunga dependencies** — varje npm-paket kostar RAM
2. **Använd `--max-old-space-size=100`** i motorn om du vill vara extra säker:
   ```javascript
   // Lägg till i engine/index.js, toppen
   // Eller: NODE_OPTIONS="--max-old-space-size=100" i .env
   ```
3. **Lazy-loada moduler** — importera bara det du behöver
4. **Undvik stora in-memory-cacher** — använd filer på disk
5. **Stäng inaktiva connections** — setTimeout på sockets

---

## Avinstallation

Avinstallationsskriptet ska rensa **båda** komponenternas tjänster:

```bash
#!/bin/bash
# scripts/uninstall.sh

# Stoppa och ta bort engine
systemctl --user stop lotus-light-engine 2>/dev/null || true
systemctl --user disable lotus-light-engine 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/lotus-light-engine.service"

# Stoppa och ta bort UI
systemctl --user stop lotus-light-ui 2>/dev/null || true
systemctl --user disable lotus-light-ui 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/lotus-light-ui.service"

# Rensa systemd
systemctl --user daemon-reload

# Ta bort filer
rm -rf /opt/lotus-light
```

---

## Checklista för ny tjänst

### Obligatoriskt

- [ ] Motorn lyssnar på `process.env.PORT`
- [ ] Motorn exponerar `GET /api/version` → `{ "version": "x.y.z" }`
- [ ] Motorn exponerar `GET /api/health` → `{ "status": "ok" }`
- [ ] Motorn hanterar `SIGTERM` graciöst
- [ ] UI:t byggs till statisk `dist/`-katalog
- [ ] UI:t beräknar motor-URL från `window.location` (port + 50)
- [ ] Motorn tillåter CORS (åtminstone från lokalt nätverk)
- [ ] GitHub Actions publicerar `dist.tar.gz` med både `engine/` och `dist/`
- [ ] `dist.tar.gz` inkluderar `node_modules/` för motorn
- [ ] Avinstallationsskript rensar båda tjänsterna
- [ ] Alla `.sh`-filer har LF-radslut och är körbara

### Rekommenderat

- [ ] Motorn använder ≤60MB RAM
- [ ] Startup-tid <2 sekunder
- [ ] State sparas till disk (inte bara i minnet)
- [ ] Ingen skrivning utanför `installDir`
- [ ] `GET /api/health` returnerar mer detaljer (uptime, connections, etc.)
- [ ] SSE för realtidsuppdateringar istället för polling

---

## Sammanfattning

```
┌─────────────────────────────────────────────────────────────────┐
│                     Pi Control Center                          │
│                   (operativsystem, kärna 0)                    │
│                                                                │
│  ┌──────────────────────┐  ┌──────────────────────┐            │
│  │ Kärna 1              │  │ Kärna 2              │  Kärna 3   │
│  │                      │  │                      │  (ledig)   │
│  │ ┌──────────────────┐ │  │ ┌──────────────────┐ │            │
│  │ │ Motor    :3051   │ │  │ │ Motor    :3052   │ │            │
│  │ │ Node.js  always  │ │  │ │ Node.js  always  │ │            │
│  │ │ API + logik      │ │  │ │ API + logik      │ │            │
│  │ └──────────────────┘ │  │ └──────────────────┘ │            │
│  │ ┌──────────────────┐ │  │ ┌──────────────────┐ │            │
│  │ │ UI       :3001   │ │  │ │ UI       :3002   │ │            │
│  │ │ Statisk  on-fail │ │  │ │ Statisk  on-fail │ │            │
│  │ │ Fjärrkontroll    │ │  │ │ Fjärrkontroll    │ │            │
│  │ └──────────────────┘ │  │ └──────────────────┘ │            │
│  └──────────────────────┘  └──────────────────────┘            │
│                                                                │
│  Sandboxat: ProtectSystem=strict, AllowedCPUs, MemoryMax=128M  │
└─────────────────────────────────────────────────────────────────┘
```

Motorn = maskinen som aldrig stannar.
UI:t = fjärrkontrollen som kan stängas av.
Pi Control Center = operativsystemet som styr allt.
