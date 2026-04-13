# Tjänstearkitektur — Deep Dive

> **Denna guide kompletterar [SERVICE-INTEGRATION.md](./SERVICE-INTEGRATION.md).**
> Läs integrations­guiden först — den täcker filosofi, portkonvention, services.json-format, sandboxing, installation och checklista.
>
> Här hittar du **djupare arkitekturdetaljer** för hur du designar din motor och ditt UI.

---

## Innehåll

1. [Motorn — Krav och designmönster](#1-motorn--krav-och-designmönster)
2. [UI:t — Krav och konfiguration](#2-uit--krav-och-konfiguration)
3. [Kommunikation: UI → Motor](#3-kommunikation-ui--motor)
4. [Genererade systemd-tjänster (referens)](#4-genererade-systemd-tjänster-referens)
5. [Minnesoptimering (Pi Zero 2 W)](#5-minnesoptimering-pi-zero-2-w)
6. [Repostruktur och dist.tar.gz](#6-repostruktur-och-disttargz)
7. [Översiktsbild](#7-översiktsbild)

---

## 1. Motorn — Krav och designmönster

Motorn är hjärtat i tjänsten. Den hanterar all affärslogik och exponerar ett REST API.

### Obligatoriska krav

1. **Node.js-process** — Startas med `node {entrypoint}`
2. **Lyssnar på `process.env.PORT`** (= `ENGINE_PORT`, t.ex. 3052)
3. **Exponerar REST API** — minst:
   - `GET /api/health` → Se [health-endpoint-standarden i SERVICE-INTEGRATION.md](./SERVICE-INTEGRATION.md#11-health-endpoint--standard-för-motorer)
   - `GET /api/version` → `{ "version": "1.2.3" }`
   - Appspecifika endpoints
4. **Ingen egen UI** — motorn serverar *inte* HTML/CSS/JS
5. **Stateless vid restart** — spara persistent data i filer (inom `installDir`), inte i minnet
6. **Hanterar SIGTERM graciöst** — stäng ner connections och spara state vid shutdown

### Exempelmotor

```javascript
// engine/index.js
import express from 'express';
import cors from 'cors';

const app = express();
const PORT = process.env.PORT || 3052;
const startTime = Date.now();
const pkg = require('./package.json');

app.use(cors());  // Krävs — UI:t kör på annan port

app.get('/api/health', (req, res) => {
  const mem = process.memoryUsage();
  res.json({
    status: 'ok',
    service: 'my-service-engine',
    version: pkg.version,
    uptime: Math.floor((Date.now() - startTime) / 1000),
    memory: {
      rss: Math.round(mem.rss / 1024 / 1024),
      heapUsed: Math.round(mem.heapUsed / 1024 / 1024),
      heapTotal: Math.round(mem.heapTotal / 1024 / 1024)
    },
    timestamp: new Date().toISOString()
  });
});

app.get('/api/version', (req, res) => {
  res.json({ version: pkg.version });
});

// --- Appspecifik logik ---
app.get('/api/devices', (req, res) => {
  // ... returnera enheter
});

app.listen(PORT, () => {
  console.log(`Engine listening on port ${PORT}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Shutting down gracefully...');
  process.exit(0);
});
```

### Design för stabilitet

Motorn ska kunna köra i veckor utan tillsyn:

- **State till disk** — spara allt viktigt i filer, inte i minnet
- **Snabb startup** — under 2 sekunder
- **Idempotenta operationer** — inga förluster vid omstart
- **Inga minnesläckor** — stäng inaktiva connections med timeouts

---

## 2. UI:t — Krav och konfiguration

UI:t är en statisk webbsida som serveras med en inbyggd **Python-baserad SPA-server** (`static-spa-server.py`) och pratar med motorn via HTTP. Python-servern är extremt minnessnål (~5MB RSS) jämfört med `npx serve` (~40MB) och hanterar SPA-routing automatiskt.

### Krav

1. **Statisk build** — `npm run build` → `dist/`-katalog
2. **Serveras med Python SPA-server** på `UI_PORT`
3. **Konfigurerar motor-URL dynamiskt:**

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

4. **Kan stängas av** utan att påverka motorn

---

## 3. Kommunikation: UI → Motor

UI:t ska **aldrig** ha egen affärslogik. All data hämtas från motorn via HTTP.

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
import cors from 'cors';
app.use(cors());  // Tillåt alla origins (ok i lokalt nätverk)
```

### Realtidsuppdateringar (valfritt)

Använd **Server-Sent Events (SSE)** istället för WebSockets — lättare och enklare att implementera:

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

## 4. Genererade systemd-tjänster (referens)

Pi Control Center skapar automatiskt systemd-units vid installation. Du behöver **inte** skapa dem själv. Dessa visas här som referens.

### Motor-unit

```ini
[Unit]
Description=my-service engine service
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/my-service
ExecStart=/usr/bin/node /opt/my-service/engine/index.js
Environment=PORT=3052
Environment=ENGINE_PORT=3052
Environment=UI_PORT=3002
CPUAffinity=2
AllowedCPUs=2
MemoryMax=128M
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/opt/my-service
PrivateTmp=true
NoNewPrivileges=true
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

### UI-unit

```ini
[Unit]
Description=my-service ui service
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/my-service
ExecStart=/usr/bin/python3 /opt/pi-control-center/static-spa-server.py /opt/my-service/dist 3002
Environment=PORT=3002
Environment=ENGINE_PORT=3052
Environment=UI_PORT=3002
CPUAffinity=2
AllowedCPUs=2
MemoryMax=128M
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/opt/my-service
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
| `PORT` | Vald port + 50 | Vald port |
| `ExecStart` | `node engine/index.js` | `python3 static-spa-server.py {dir} {port}` |

---

## 5. Minnesoptimering (Pi Zero 2 W)

Hela systemet har **512MB RAM**. Med dashboard + nginx + 3 tjänster (motor + UI vardera) behöver varje process vara sparsam.

### Minnesbudget

| Resurs | Budget |
|--------|--------|
| Pi Control Center + nginx + system | ~150MB |
| Motor-RAM per tjänst | ≤60MB |
| UI-serve-RAM per tjänst | ≤30MB |
| Systemd-gräns per tjänst (motor+UI) | 128MB |

### Tips

1. **Undvik tunga dependencies** — varje npm-paket kostar RAM
2. **Använd `--max-old-space-size=100`** i motorn för extra säkerhet
3. **Lazy-loada moduler** — importera bara det du behöver
4. **Undvik stora in-memory-cacher** — använd filer på disk
5. **Stäng inaktiva connections** — setTimeout på sockets
6. **Övervaka via health-endpoint** — RSS nära 100MB = varningsflagga

---

## 6. Repostruktur och dist.tar.gz

### Rekommenderad repostruktur

```
my-service/
├── engine/                    # Motor (Node.js backend)
│   ├── index.js               # Entrypoint — lyssnar på process.env.PORT
│   ├── package.json           # Motorns beroenden
│   ├── routes/                # API-routes
│   ├── services/              # Affärslogik
│   └── data/                  # Lokal datalagring (SQLite, JSON-filer)
├── ui/                        # Frontend (statisk)
│   ├── src/
│   │   ├── App.tsx
│   │   ├── config.ts          # API_BASE = hostname:ENGINE_PORT
│   │   └── ...
│   ├── dist/                  # Byggs av CI → serveras av Python SPA-server
│   └── package.json
├── scripts/
│   ├── install.sh             # Fallback-installation
│   ├── update.sh              # Uppdateringsskript
│   └── uninstall.sh           # Avinstallationsskript
├── .github/
│   └── workflows/
│       └── release.yml        # Bygger och publicerar dist.tar.gz
└── package.json               # Root package.json
```

### dist.tar.gz-innehåll

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

## 7. Översiktsbild

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

Motorn = maskinen som aldrig stannar.
UI:t = fjärrkontrollen som kan stängas av.
Pi Control Center = operativsystemet som styr allt.
```

---

> **Se [SERVICE-INTEGRATION.md](./SERVICE-INTEGRATION.md)** för portkonvention, services.json-format, sandboxingregler, installationsflöde och komplett checklista.
