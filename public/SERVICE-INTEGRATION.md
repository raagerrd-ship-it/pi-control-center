# Service Integration Guide — Pi Control Center

> **Pi Control Center är operativsystemet. Din tjänst är ett program.**
>
> Denna guide beskriver exakt hur du bygger en tjänst som kan installeras, uppdateras och avinstalleras via Pi Control Center — helt från mobilen.

---

## Innehåll

1. [Filosofi — OS och Program](#1-filosofi--os-och-program)
2. [Motor och UI — Två halvor av samma tjänst](#2-motor-och-ui--två-halvor-av-samma-tjänst)
3. [Portkonvention](#3-portkonvention)
4. [services.json — Registrera din tjänst](#4-servicesjson--registrera-din-tjänst)
5. [Sandboxing och isolering](#5-sandboxing-och-isolering)
6. [Release-baserad installation (rekommenderat)](#6-release-baserad-installation-rekommenderat)
7. [Legacy-installation (fallback)](#7-legacy-installation-fallback)
8. [Uppdateringsflöde](#8-uppdateringsflöde)
9. [Avinstallation](#9-avinstallation)
10. [Miljövariabler](#10-miljövariabler)
11. [Health Endpoint — Standard för motorer](#11-health-endpoint--standard-för-motorer)
12. [Checklista](#12-checklista)

---

## 1. Filosofi — OS och Program

Pi Control Center fungerar som ett **operativsystem** för din Raspberry Pi. Det hanterar:

- **Tjänsteinstallation** — ladda ner, packa upp, konfigurera
- **Processhantering** — starta, stoppa, starta om via systemd
- **Resursallokering** — tilldela CPU-kärna och minnesgräns
- **Isolering** — varje tjänst körs i en sandlåda

Din tjänst är ett **program** som installeras i detta OS. Precis som en app på en telefon:

- Du bestämmer inte själv vilken port du kör på — **OS:et tilldelar den**
- Du bestämmer inte vilken CPU du använder — **OS:et tilldelar den**
- Du kan inte ändra systemfiler — **OS:et skyddar sig självt**
- Du tillhandahåller koden — **OS:et sköter resten**

### Användarens perspektiv

1. Användaren öppnar Pi Control Center på mobilen via Pi:ns IP-adress
2. Trycker "Installera tjänst" och väljer din tjänst
3. Väljer port och CPU-kärna
4. Klart — tjänsten körs och kan hanteras via dashboarden

---

## 2. Motor och UI — Två halvor av samma tjänst

Varje tjänst bör bestå av två separata komponenter:

### Motor (Engine) — Det stabila hjärtat

Motorn är din tjänsts **backend/logik**. Den:

- Körs **alltid** (`Restart=always`) — startar om automatiskt vid krasch
- Hanterar all affärslogik, datahantering, API:er
- Lyssnar på sin egen port (se [portkonvention](#3-portkonvention))
- Ska vara **stabil och lättviktig** — minimal resursförbrukning
- Behöver **aldrig** startas om vid UI-uppdateringar

**Tänk på motorn som en tjänst som "bara fungerar".** Den ska kunna köra i veckor utan tillsyn.

### UI (Frontend) — Fjärrkontrollen

UI:t är din tjänsts **webbgränssnitt**. Det:

- Är en **statisk webbapp** som serveras via en inbyggd **Python SPA-server** (`static-spa-server.py`)
- Python-servern använder ~5MB RAM jämfört med ~40MB för `npx serve`
- Kommunicerar med motorn via HTTP (till motorns port)
- Kan stoppas, startas om och uppdateras **utan att motorn påverkas**
- Har `Restart=on-failure` — startar bara om vid krasch, inte vid normal stopp

**Tänk på UI:t som en fjärrkontroll.** Om fjärrkontrollen slutar fungera fortsätter TV:n att spela.

### Varför separation?

| Scenario | Utan separation | Med separation |
|----------|----------------|----------------|
| UI-uppdatering | Hela tjänsten startar om | Bara UI:t startar om, motorn fortsätter |
| UI kraschar | Tjänsten dör | Motorn fortsätter, UI startar om |
| Felsökning | Svårt att isolera problem | Testa motor och UI oberoende |
| Resursanvändning | En stor process | Två små, optimerade processer |

### Kommunikation mellan Motor och UI

UI:t pratar med motorn via HTTP på `localhost`:

```
┌──────────────────────────────────────────────┐
│  Raspberry Pi                                │
│                                              │
│  ┌─────────────┐       ┌─────────────┐       │
│  │   UI :3002  │──HTTP──▶ Motor :3052│       │
│  │  (static)   │       │  (node.js)  │       │
│  └─────────────┘       └─────────────┘       │
│                                              │
│  Användare ──▶ http://pi-ip:3002             │
└──────────────────────────────────────────────┘
```

I UI:ts JavaScript-kod, använd `ENGINE_PORT` miljövariabeln eller beräkna motorns port som **UI-port + 50**:

```javascript
// I UI:t (byggs vid compile-tid eller injiceras)
const ENGINE_PORT = parseInt(window.location.port) + 50;
const ENGINE_URL = `http://${window.location.hostname}:${ENGINE_PORT}`;

// Anropa motorn
const response = await fetch(`${ENGINE_URL}/api/status`);
```

---

## 3. Portkonvention

När användaren väljer en port i dashboarden (t.ex. `3002`) tilldelas **två portar** automatiskt:

| Komponent | Port | Exempel |
|-----------|------|---------|
| **UI** | Vald port | `3002` |
| **Motor** | Vald port + 50 | `3052` |

Regeln är enkel: **Motor = UI + 50**.

Båda komponenterna får alla portar som miljövariabler:

```bash
PORT=3002          # Komponentens egen port (3002 för UI, 3052 för Motor)
ENGINE_PORT=3052   # Motorns port (alltid)
UI_PORT=3002       # UI:ts port (alltid)
```

### Varför +50?

- Enkelt att beräkna i huvudet
- Tillräckligt avstånd för att undvika kollisioner
- Fungerar för alla vanliga portintervall (3000-3999)

### Legacy-tjänster (utan components)

Tjänster utan `components` i `services.json` får enbart en port — den valda porten. Ingen motor/UI-separation.

---

## 4. services.json — Registrera din tjänst

Din tjänst registreras i `public/services.json`. Det finns två format:

### Rekommenderat format — Med Motor/UI-separation

```json
{
  "key": "my-service",
  "name": "My Service",
  "repo": "https://github.com/user/my-service.git",
  "releaseUrl": "https://api.github.com/repos/user/my-service/releases/latest",
  "installDir": "$HOME/.local/share/my-service",
  "installScript": "scripts/install.sh",
  "updateScript": "$HOME/.local/share/my-service/scripts/update.sh",
  "uninstallScript": "scripts/uninstall.sh",
  "components": {
    "engine": {
      "type": "node",
      "entrypoint": "server/index.js",
      "service": "my-service-engine",
      "alwaysOn": true
    },
    "ui": {
      "type": "static",
      "entrypoint": "dist/",
      "service": "my-service-ui",
      "alwaysOn": false
    }
  }
}
```

### Legacy-format — En enda process

```json
{
  "key": "my-service",
  "name": "My Service",
  "type": "node",
  "entrypoint": "server/index.js",
  "repo": "https://github.com/user/my-service.git",
  "releaseUrl": "https://api.github.com/repos/user/my-service/releases/latest",
  "installDir": "$HOME/.local/share/my-service",
  "installScript": "scripts/install.sh",
  "updateScript": "$HOME/.local/share/my-service/scripts/update.sh",
  "uninstallScript": "scripts/uninstall.sh",
  "service": "my-service"
}
```

### Fältreferens — Tjänstnivå

| Fält | Krävs | Beskrivning |
|------|-------|-------------|
| `key` | ✅ | Unikt ID (används i API-anrop, inga mellanslag) |
| `name` | ✅ | Visningsnamn i dashboarden |
| `repo` | ✅ | Git-klon-URL (fallback om inget release finns) |
| `releaseUrl` | ⭐ | GitHub Releases API-URL för förbyggda nedladdningar |
| `releaseAsset` | 🔹 | Filnamn på release-asset att ladda ner (default: `dist.tar.gz`). Ange om din release använder ett annat namn |
| `installDir` | ✅ | Installationskatalog (`$HOME` expanderas automatiskt) |
| `runInstallOnRelease` | 🔹 | `true` = kör `npm install --omit=dev` efter uppackning av release. Krävs om motorn har **native-moduler** (t.ex. Bluetooth, sharp) som måste kompileras för Pi:ns arkitektur/Node-version |
| `installScript` | ✅ | Sökväg relativt repo-root (körs vid fallback-install) |
| `updateScript` | ✅ | Absolut sökväg (finns efter installation) |
| `uninstallScript` | ✅ | Sökväg relativt repo-root |
| `components` | ⭐ | Motor/UI-definition (rekommenderat) |
| `type` | 🔸 | `"node"` eller `"static"` (enbart legacy) |
| `entrypoint` | 🔸 | Sökväg till huvudfil (enbart legacy) |
| `service` | 🔸 | systemd-tjänstnamn (enbart legacy) |

✅ = krävs alltid · ⭐ = starkt rekommenderat · 🔹 = valfritt · 🔸 = enbart legacy-format

### Fältreferens — Komponentnivå

| Fält | Krävs | Beskrivning |
|------|-------|-------------|
| `type` | ✅ | `"node"` (motor) eller `"static"` (UI) |
| `entrypoint` | ✅ | Sökväg relativt `installDir` |
| `service` | ✅ | systemd-tjänstnamn för denna komponent |
| `alwaysOn` | ✅ | `true` = `Restart=always`, `false` = `Restart=on-failure` |

### Tjänstetyper

**`"node"`** — Node.js-server (typiskt motorn):
```bash
node {installDir}/{entrypoint}
# PORT sätts automatiskt som miljövariabel
```

**`"static"`** — Statisk webbapp (typiskt UI:t), serveras av Python SPA-server:
```bash
python3 /opt/pi-control-center/static-spa-server.py {installDir}/{entrypoint} {port}
```

---

## 5. Sandboxing och isolering

Pi Control Center skyddar systemet genom att köra varje tjänst i en **strikt sandlåda**. Detta konfigureras automatiskt i den genererade systemd-unit-filen.

### CPU-isolering (cgroups v2)

Varje tjänst pinnas till **en enda CPU-kärna** med hårda gränser:

```ini
CPUAffinity=2          # Scheduling-hint
AllowedCPUs=2          # Hård cgroup-gräns — kan inte köra på andra kärnor
MemoryMax=128M         # Minnestak per tjänst
```

- `AllowedCPUs` är en **fysisk begränsning** — processen kan bokstavligen inte köra på andra kärnor
- Kärna 0 är reserverad för Pi Control Center + nginx
- Tillgängliga kärnor för tjänster: **1, 2, 3**

### Filsystemsskydd

Tjänster kan **inte modifiera systemfiler** under körning:

```ini
ProtectSystem=strict          # /usr, /boot, /etc är skrivskyddade
ProtectHome=read-only         # $HOME är skrivskyddat
ReadWritePaths={installDir}   # Enbart sin egen katalog är skrivbar
PrivateTmp=true               # Isolerat /tmp per tjänst
NoNewPrivileges=true          # Kan inte eskalera rättigheter
```

### Vad tjänster INTE får göra

| ❌ Förbjudet | Varför |
|-------------|--------|
| Ändra `/etc/hosts` | `ProtectSystem=strict` blockerar |
| Ändra `/etc/hostname` | `ProtectSystem=strict` blockerar |
| Ändra systemklocka/tidszon | `ProtectSystem=strict` blockerar |
| Skriva utanför `installDir` | `ReadWritePaths` begränsar |
| Köra på andra CPU-kärnor | `AllowedCPUs` blockerar |
| Använda mer än 128MB RAM | `MemoryMax` dödar processen |
| Eskalera privilegier | `NoNewPrivileges` blockerar |

### Vad tjänster FÅR göra

| ✅ Tillåtet | Hur |
|------------|-----|
| Läsa systemfiler | Allt är läsbart (bara ej skrivbart) |
| Skriva i sin `installDir` | `ReadWritePaths` tillåter |
| Lyssna på tilldelad port | `PORT` miljövariabel |
| Kommunicera via nätverk | Inga nätverksbegränsningar |
| Använda sitt eget `/tmp` | Isolerat per tjänst |

> **OBS:** Installskript körs fortfarande med fulla rättigheter under installationen. Men den **körande tjänsten** är fullständigt sandboxad.

---

## 6. Release-baserad installation (rekommenderat)

Den snabbaste vägen att installera tjänster på Pi Zero 2 W. **Inget byggsteg på Pi:n.**

### Flöde

1. Din CI (GitHub Actions) bygger projektet och publicerar `dist.tar.gz` som en GitHub Release
2. Pi Control Center laddar ner och packar upp till `installDir`
3. Sandboxade systemd-tjänster skapas automatiskt
4. Installation tar **~30 sekunder**

### GitHub Actions — Statisk app (UI)

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
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npm run build
      - run: tar czf dist.tar.gz dist/
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: latest
          files: dist.tar.gz
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### GitHub Actions — Node.js-app (Motor)

Inkludera `node_modules` så att Pi:n **inte behöver köra npm install**:

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
      - run: npm ci
      - run: npm run build
      - run: npm install --omit=dev --package-lock=false
      - run: tar czf dist.tar.gz server/ node_modules/
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: latest
          files: dist.tar.gz
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### GitHub Actions — Motor + UI i samma repo

Om din motor och UI byggs i samma repo, inkludera båda i tarballen:

```yaml
      - run: npm ci
      - run: npm run build        # bygger både server/ och dist/
      - run: npm install --omit=dev --package-lock=false
      - run: tar czf dist.tar.gz server/ dist/ node_modules/
```

### Repostruktur (rekommenderad)

```
my-service/
├── server/              # Motorkod (Node.js)
│   └── index.js         # Entrypoint
├── src/                 # UI-källkod
│   └── ...
├── dist/                # Byggd UI (genereras av CI)
│   └── index.html
├── scripts/
│   ├── install.sh       # Fallback-installskript
│   ├── update.sh        # Uppdateringsskript
│   └── uninstall.sh     # Avinstallationsskript
├── package.json
└── .github/
    └── workflows/
        └── release.yml  # GitHub Actions-workflow
```

---

## 7. Legacy-installation (fallback)

Om inget `releaseUrl` finns i `services.json`, klonar dashboarden repot och kör installskriptet.

### Flaggor som skickas till installskriptet

```bash
./scripts/install.sh --port 3002 --core 2
```

| Flagga | Beskrivning |
|--------|-------------|
| `--port` | Porten som UI:t ska lyssna på |
| `--core` | CPU-kärnan (1-3) som tjänsten tilldelas |

### Vad installskriptet får göra

- ✅ Installera beroenden (`npm install`)
- ✅ Bygga projektet (`npm run build`)
- ✅ Skapa konfigurationsfiler i `installDir`
- ✅ Skriv ut statusinformation

### Vad installskriptet INTE får göra

- ❌ Skapa egna systemd-tjänster (det gör Pi Control Center)
- ❌ Ändra `/etc/hosts` eller andra systemfiler
- ❌ Ändra hostname
- ❌ Installera systempaket utan användarens vetskap

---

## 8. Uppdateringsflöde

### Release-baserad uppdatering

1. Dashboarden kollar `releaseUrl` efter ny version
2. Laddar ner ny `dist.tar.gz`
3. Packar upp till `installDir` (ersätter befintliga filer)
4. Startar om berörd komponent (motor eller UI)

### Komponentvis uppdatering

Med motor/UI-separation kan användaren uppdatera **en komponent i taget**:

- **Uppdatera UI** → bara UI-tjänsten startar om, motorn fortsätter köra
- **Uppdatera Motor** → motorn gör en graceful restart

### Uppdateringsskript (fallback)

Om `updateScript` finns i `services.json` körs det som fallback. Skriptet ansvarar för att:

1. Hämta ny kod (git pull eller liknande)
2. Bygga om (om nödvändigt)
3. Returnera exit code 0 vid framgång

Pi Control Center hanterar omstart av systemd-tjänsten **efter** att skriptet kört klart.

---

## 9. Avinstallation

Tillhandahåll ett avinstallationsskript som städar upp. Pi Control Center stoppar och tar bort systemd-tjänsterna, men ditt skript hanterar filstädning.

### Mall — Component-baserad tjänst

```bash
#!/bin/bash
# uninstall.sh — städa upp installationskatalog
# systemd-tjänster hanteras av Pi Control Center

INSTALL_DIR="$HOME/.local/share/my-service"

# Rensa installationskatalog
rm -rf "$INSTALL_DIR"

echo "✅ my-service avinstallerad"
```

### Mall — Legacy-tjänst

```bash
#!/bin/bash
SERVICE="my-service"
INSTALL_DIR="$HOME/.local/share/my-service"

# Stoppa och inaktivera tjänst
systemctl --user stop "$SERVICE" 2>/dev/null || true
systemctl --user disable "$SERVICE" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/${SERVICE}.service"
systemctl --user daemon-reload

# Rensa installationskatalog
rm -rf "$INSTALL_DIR"

echo "✅ $SERVICE avinstallerad"
```

---

## 10. Miljövariabler

Dessa miljövariabler sätts **automatiskt** av Pi Control Center i systemd-unit-filen. Du behöver inte konfigurera dem själv.

### Alla tjänster

| Variabel | Beskrivning | Exempel |
|----------|-------------|---------|
| `PORT` | Komponentens egen port | `3052` (motor) eller `3002` (UI) |
| `NODE_ENV` | Alltid `production` | `production` |

### Component-baserade tjänster (motor/UI)

| Variabel | Beskrivning | Exempel |
|----------|-------------|---------|
| `ENGINE_PORT` | Motorns port (alltid UI-port + 50) | `3052` |
| `UI_PORT` | UI:ts port | `3002` |

### Använda i din kod

**Motor (Node.js):**
```javascript
const PORT = process.env.PORT || 3052;
const server = app.listen(PORT, () => {
  console.log(`Engine running on port ${PORT}`);
});
```

**UI (statisk app — vid byggtid eller runtime):**
```javascript
// Beräkna motorns port baserat på UI:ts port
const uiPort = parseInt(window.location.port);
const enginePort = uiPort + 50;
const ENGINE_URL = `http://${window.location.hostname}:${enginePort}`;
```

---

## 11. Health Endpoint — Standard för motorer

Varje motor **bör** exponera en hälsokontroll-endpoint som Pi Control Center kan använda för att övervaka tjänstens tillstånd.

### Endpoint

```
GET /api/health
```

### Responsformat

```json
{
  "status": "ok",
  "service": "my-service-engine",
  "version": "1.2.0",
  "uptime": 84372,
  "memory": {
    "rss": 42,
    "heapUsed": 28,
    "heapTotal": 48
  },
  "timestamp": "2026-04-12T14:30:00.000Z"
}
```

### Fältspecifikation

| Fält | Typ | Krävs | Beskrivning |
|------|-----|-------|-------------|
| `status` | `string` | ✅ | `"ok"` om allt fungerar, `"degraded"` om delvis, `"error"` vid problem |
| `service` | `string` | ✅ | Tjänstens `service`-namn från `services.json` |
| `version` | `string` | ✅ | Semantisk version (t.ex. `"1.2.0"`) |
| `uptime` | `number` | ✅ | Sekunder sedan processen startade |
| `memory` | `object` | ⭐ | Minnesanvändning i MB |
| `memory.rss` | `number` | ⭐ | Resident Set Size i MB (totalt fysiskt minne) |
| `memory.heapUsed` | `number` | ⭐ | Använt heap-minne i MB |
| `memory.heapTotal` | `number` | ⭐ | Totalt allokerat heap i MB |
| `timestamp` | `string` | ⭐ | ISO 8601 tidsstämpel |

✅ = krävs · ⭐ = starkt rekommenderat

### Statusvärden

| Status | Betydelse | Pi Control Center visar |
|--------|-----------|------------------------|
| `"ok"` | Allt fungerar normalt | 🟢 Grön indikator |
| `"degraded"` | Fungerar men med begränsningar | 🟡 Gul indikator |
| `"error"` | Kritiskt fel, behöver åtgärd | 🔴 Röd indikator |

### Referensimplementation (Node.js)

```javascript
const startTime = Date.now();
const pkg = require('./package.json');

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
```

### Referensimplementation med felhantering

Om motorn har beroenden (databas, extern tjänst etc.) kan du rapportera degraderat tillstånd:

```javascript
app.get('/api/health', async (req, res) => {
  const mem = process.memoryUsage();
  const rssMB = Math.round(mem.rss / 1024 / 1024);
  
  // Kontrollera beroenden
  let status = 'ok';
  if (rssMB > 100) status = 'degraded';  // Närmar sig 128MB-gränsen
  
  try {
    await checkDatabaseConnection();  // Valfri beroendecheck
  } catch {
    status = 'error';
  }

  res.json({
    status,
    service: 'my-service-engine',
    version: pkg.version,
    uptime: Math.floor((Date.now() - startTime) / 1000),
    memory: {
      rss: rssMB,
      heapUsed: Math.round(mem.heapUsed / 1024 / 1024),
      heapTotal: Math.round(mem.heapTotal / 1024 / 1024)
    },
    timestamp: new Date().toISOString()
  });
});
```

### Hur Pi Control Center använder health-endpointen

Pi Control Center pollar `/api/health` var **30:e sekund** för varje aktiv motor. Informationen används för att:

1. **Visa status i dashboarden** — grön/gul/röd indikator per motor
2. **Visa minnesanvändning** — varnar om RSS närmar sig 128MB-gränsen
3. **Detektera hängda processer** — om health inte svarar inom 5 sekunder markeras motorn som "ej svarar"
4. **Visa version** — visar installerad version och jämför med senaste release

### Timeout och felhantering

- **Timeout:** 5 sekunder — om motorn inte svarar inom denna tid markeras den som offline
- **HTTP-statuskod:** Svara alltid med `200 OK`, även vid `"error"` status. Pi Control Center tolkar JSON-fältet `status`, inte HTTP-koden
- **Om endpointen saknas:** Pi Control Center faller tillbaka på `systemctl is-active` för statuscheck

---

## 12. Checklista

Innan din tjänst kan installeras via Pi Control Center, verifiera:

### Obligatoriskt

- [ ] Registrerad i `services.json` med alla obligatoriska fält
- [ ] GitHub Actions-workflow publicerar `dist.tar.gz` (rekommenderat)
- [ ] ELLER: installskript hanterar `--port` och `--core`
- [ ] Avinstallationsskript som städar upp
- [ ] Alla skript är exekverbara (`chmod +x`) med **LF-radslut**
- [ ] Tjänsten lyssnar på `PORT` miljövariabeln
- [ ] Tjänsten modifierar **inga** systemfiler

### Starkt rekommenderat

- [ ] Motor/UI-separation med `components` i `services.json`
- [ ] Motor och UI har separata tjänstnamn (t.ex. `my-service-engine`, `my-service-ui`)
- [ ] Motorn exponerar `/api/health` endpoint
- [ ] UI:t beräknar motorns port som `UI-port + 50`
- [ ] Motorn klarar av att köras i veckor utan omstart
- [ ] RAM-förbrukning under 128MB per komponent

### Testning

- [ ] Testa att motorn startar med enbart `PORT` miljövariabel
- [ ] Testa att UI:t kan nå motorn via HTTP
- [ ] Testa att tjänsten fungerar efter `kill -9` (automatisk omstart)
- [ ] Testa att UI:t kan uppdateras utan att motorn påverkas
