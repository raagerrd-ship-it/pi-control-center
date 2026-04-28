# pcc-service-template — komplett skiss

Det här dokumentet innehåller **all fil-innehåll** för `pcc-service-template`-repot.
Det är inte en del av PCC i runtime — det är ett klippblock som används vid skapande av nya tjänster.

## Hur du använder den här skissen

1. Skapa ett nytt Lovable-projekt → koppla till nytt tomt GitHub-repo `pcc-service-template`.
2. Be Lovable skapa filerna nedan (klistra in det här dokumentet eller länka till det).
3. På GitHub: **Settings → Template repository ✅**.
4. Klart. Nästa nya tjänst: "Use this template" → ny repo → klona i Lovable → sök/ersätt `{{...}}`.

## Designprinciper

- **Headless som default.** UI är opt-in (separat branch `with-ui` eller separat template).
- **Inga `.template`-suffix.** Placeholders direkt i filer (`{{SERVICE_KEY}}`) — fungerar med syntax highlighting och Lovable-utveckling.
- **Inga `examples/`.** Lotus, Sonos, Cast Away är levande exempel i sina egna repon — länka från README.
- **Följer SERVICE-CONTRACT.md v1.0.**

## Placeholders

| Placeholder | Exempel | Var |
|---|---|---|
| `{{SERVICE_KEY}}` | `weather-display` | kebab-case, inga mellanslag |
| `{{SERVICE_NAME}}` | `Weather Display` | visningsnamn |
| `{{GITHUB_OWNER}}` | `raagerrd-ship-it` | GitHub user/org |
| `{{REPO_NAME}}` | `weather-display` | repo-namn (typiskt = SERVICE_KEY) |
| `{{DESCRIPTION}}` | `Visar väder från SMHI på en Pi.` | en mening |

---

## Filstruktur

```text
pcc-service-template/
├── README.md
├── PCC-CONTRACT-VERSION.txt
├── service.json
├── package.json
├── tsconfig.json
├── .gitignore
├── .nvmrc
├── engine/
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       ├── index.ts
│       ├── health.ts
│       ├── cors.ts
│       └── config.ts
├── scripts/
│   ├── install.sh
│   ├── update.sh
│   └── uninstall.sh
└── .github/
    └── workflows/
        └── release.yml
```

---

## `PCC-CONTRACT-VERSION.txt`

```
1.0
```

---

## `.nvmrc`

```
24
```

---

## `.gitignore`

```
node_modules/
engine/dist/
dist.tar.gz
*.log
.DS_Store
```

---

## `service.json`

> Det här är en **snippet att klistra in** i PCC-repots `public/services.json`. Den distribueras inte med tjänsten själv.

```json
{
  "key": "{{SERVICE_KEY}}",
  "name": "{{SERVICE_NAME}}",
  "repo": "https://github.com/{{GITHUB_OWNER}}/{{REPO_NAME}}.git",
  "releaseUrl": "https://api.github.com/repos/{{GITHUB_OWNER}}/{{REPO_NAME}}/releases/latest",
  "releaseAsset": "dist.tar.gz",
  "installDir": "/opt/{{SERVICE_KEY}}",
  "memoryProfile": {
    "defaultLevel": "balanced",
    "levels": { "low": 100, "balanced": 140, "high": 200 }
  },
  "permissions": ["network"],
  "runInstallOnRelease": false,
  "installScript": "scripts/install.sh",
  "updateScript": "/opt/{{SERVICE_KEY}}/scripts/update.sh",
  "uninstallScript": "scripts/uninstall.sh",
  "components": {
    "engine": {
      "type": "node",
      "entrypoint": "engine/dist/index.js",
      "service": "{{SERVICE_KEY}}-engine",
      "alwaysOn": true
    }
  }
}
```

---

## `package.json` (root)

```json
{
  "name": "{{SERVICE_KEY}}",
  "version": "0.1.0",
  "private": true,
  "description": "{{DESCRIPTION}}",
  "scripts": {
    "build": "cd engine && npm run build",
    "start": "node engine/dist/index.js"
  }
}
```

---

## `tsconfig.json` (root, refererar engine)

```json
{
  "files": [],
  "references": [{ "path": "./engine" }]
}
```

---

## `engine/package.json`

```json
{
  "name": "{{SERVICE_KEY}}-engine",
  "version": "0.1.0",
  "private": true,
  "main": "dist/index.js",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "dev": "tsc -p tsconfig.json --watch"
  },
  "dependencies": {
    "express": "^4.21.0",
    "cors": "^2.8.5"
  },
  "devDependencies": {
    "@types/express": "^4.17.21",
    "@types/cors": "^2.8.17",
    "@types/node": "^22.7.0",
    "typescript": "^5.6.0"
  }
}
```

---

## `engine/tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "CommonJS",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*"]
}
```

---

## `engine/src/index.ts`

```ts
import express from 'express';
import { applyCors } from './cors';
import { healthHandler } from './health';
import { loadConfig, saveConfig } from './config';

const PORT = parseInt(process.env.PORT || '3050', 10);
const SERVICE_NAME = '{{SERVICE_KEY}}-engine';

const app = express();
applyCors(app);
app.use(express.json({ limit: '256kb' }));

app.get('/api/health', healthHandler(SERVICE_NAME));

app.get('/api/status', async (_req, res) => {
  const cfg = await loadConfig();
  res.json({ ok: true, config: cfg });
});

app.put('/api/config', async (req, res) => {
  await saveConfig(req.body);
  res.json({ ok: true });
});

const server = app.listen(PORT, () => {
  // Engångs-info vid start. Inga loggar i hot path.
  process.stdout.write(`${SERVICE_NAME} listening on ${PORT}\n`);
});

const shutdown = (signal: string) => {
  process.stdout.write(`${SERVICE_NAME} received ${signal}, shutting down\n`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
```

---

## `engine/src/health.ts`

```ts
import type { Request, Response } from 'express';

const startTime = Date.now();
// eslint-disable-next-line @typescript-eslint/no-var-requires
const pkg = require('../package.json');

export const healthHandler = (serviceName: string) => (_req: Request, res: Response) => {
  const mem = process.memoryUsage();
  const rssMb = Math.round(mem.rss / 1024 / 1024);
  const heapUsedMb = Math.round(mem.heapUsed / 1024 / 1024);
  const heapTotalMb = Math.round(mem.heapTotal / 1024 / 1024);

  // Status: degraded om vi närmar oss MemoryMax.
  // Konservativ: 85% av rapporterad MemoryMax-tröskel = ung. 120MB om limit är 140MB.
  const status: 'ok' | 'degraded' | 'error' = rssMb > 120 ? 'degraded' : 'ok';

  res.status(200).json({
    status,
    service: serviceName,
    version: pkg.version,
    uptime: Math.floor((Date.now() - startTime) / 1000),
    memory: { rss: rssMb, heapUsed: heapUsedMb, heapTotal: heapTotalMb },
    timestamp: new Date().toISOString(),
  });
};
```

---

## `engine/src/cors.ts`

```ts
import type { Express } from 'express';
import cors from 'cors';

// Lokalt nätverk → tillåt allt. Matchar SERVICE-CONTRACT.md §5.2.
export const applyCors = (app: Express): void => {
  app.use(cors({ origin: '*' }));
  app.options('*', cors({ origin: '*' }));
};
```

---

## `engine/src/config.ts`

```ts
import { promises as fs } from 'fs';
import { join } from 'path';

const CONFIG_DIR = process.env.PCC_CONFIG_DIR || '/tmp/{{SERVICE_KEY}}-config';
const CONFIG_FILE = join(CONFIG_DIR, 'settings.json');

export type AppConfig = Record<string, unknown>;

export const loadConfig = async (): Promise<AppConfig> => {
  try {
    const raw = await fs.readFile(CONFIG_FILE, 'utf8');
    return JSON.parse(raw) as AppConfig;
  } catch {
    return {};
  }
};

// Atomic write: skriv till tmp + rename.
export const saveConfig = async (cfg: AppConfig): Promise<void> => {
  await fs.mkdir(CONFIG_DIR, { recursive: true });
  const tmp = `${CONFIG_FILE}.tmp.${process.pid}`;
  await fs.writeFile(tmp, JSON.stringify(cfg, null, 2), 'utf8');
  await fs.rename(tmp, CONFIG_FILE);
};
```

---

## `scripts/install.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fallback-install (används bara om release-flödet misslyckas).
# PCC ger flaggor: --port <ui_port> --core <cpu_core>
# Vi använder dem inte här eftersom service.json + PCC sköter resten.

PORT=""
CORE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --core) CORE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "install.sh: port=${PORT:-?} core=${CORE:-?}"
echo "Bygger engine..."
cd "$(dirname "$0")/.."
npm install --omit=dev --package-lock=false
npm run build
echo "✅ Installation klar"
```

---

## `scripts/update.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Anropas av PCC som fallback om release-baserad update misslyckas.
# PCC sköter omstart efter att vi returnerar 0.

cd "$(dirname "$0")/.."
echo "update.sh: drar senaste main"
git fetch --tags origin main
git reset --hard origin/main
npm install --omit=dev --package-lock=false
npm run build
echo "✅ Update klar"
```

---

## `scripts/uninstall.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Vi rensar bara installDir. PCC sköter systemd-units.
# PCC_CONFIG_DIR / PCC_DATA_DIR / PCC_LOG_DIR bevaras (factory reset rensar dem).

INSTALL_DIR="/opt/{{SERVICE_KEY}}"
if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  echo "✅ {{SERVICE_KEY}} avinstallerad ($INSTALL_DIR)"
fi
```

---

## `.github/workflows/release.yml`

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 24

      - name: Install build deps
        run: |
          cd engine
          npm ci

      - name: Build engine
        run: |
          cd engine
          npm run build

      - name: Install runtime deps (no dev)
        run: |
          cd engine
          rm -rf node_modules
          npm install --omit=dev --package-lock=false

      - name: Write VERSION.json
        run: |
          TAG="${GITHUB_REF_NAME}"
          VERSION="${TAG#v}"
          echo "{\"tag\":\"${TAG}\",\"version\":\"${VERSION}\"}" > VERSION.json

      - name: Create tarball
        run: |
          tar czf dist.tar.gz \
            engine/dist \
            engine/node_modules \
            engine/package.json \
            scripts \
            VERSION.json

      - uses: softprops/action-gh-release@v2
        with:
          files: dist.tar.gz
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## `README.md`

````markdown
# {{SERVICE_NAME}}

{{DESCRIPTION}}

En tjänst för **Pi Control Center** — installeras, uppdateras och avinstalleras via PCC-dashboarden.

## Skapa en ny tjänst från den här templaten

1. Klicka **"Use this template"** på GitHub → skapa nytt repo `<din-tjänst>`.
2. Klona repot i Lovable eller lokalt.
3. Sök/ersätt globalt:
   | Placeholder | Exempel |
   |---|---|
   | `{{SERVICE_KEY}}` | `weather-display` |
   | `{{SERVICE_NAME}}` | `Weather Display` |
   | `{{GITHUB_OWNER}}` | `raagerrd-ship-it` |
   | `{{REPO_NAME}}` | `weather-display` |
   | `{{DESCRIPTION}}` | `Visar väder från SMHI.` |
4. Bygg din funktionalitet i `engine/src/`.
5. Tagga och pusha en release:
   ```bash
   git tag v0.1.0
   git push --tags
   ```
   GitHub Actions bygger och publicerar `dist.tar.gz` automatiskt.
6. Lägg till `service.json`-snippet i PCC-repots `public/services.json`.
7. Push PCC → tryck **"Hämta senaste tjänstkatalog"** i PCC-dashboardens Inställningar.
8. Tjänsten dyker upp i installationsdialogen på alla Pi:er.

## Vad du får ut av lådan

- Express-server med CORS + OPTIONS enligt PCC-kontraktet.
- `/api/health` enligt SERVICE-CONTRACT.md v1.0.
- `/api/status` och `/api/config` (atomic write till `PCC_CONFIG_DIR`).
- SIGTERM-graceful shutdown.
- TypeScript med strict mode.
- GitHub Actions-workflow som bygger med `node_modules` inkluderat (ingen npm install på Pi:n).

## Levande exempel

Tre produktionstjänster som följer samma mönster:

- [lotus-light-link](https://github.com/raagerrd-ship-it/lotus-light-link) — Bluetooth-styrning av Lotus-lampa
- [hromecast](https://github.com/raagerrd-ship-it/hromecast) — Cast-mottagare
- [sonos-gateway](https://github.com/raagerrd-ship-it/sonos-gateway) — Sonos-kontroll via SSDP

## Kontrakt

Den här templaten följer **PCC Service Contract v1.0**.
Se `PCC-CONTRACT-VERSION.txt` för aktuell version.
Fullständigt kontrakt: `public/SERVICE-CONTRACT.md` i PCC-repot.
````
