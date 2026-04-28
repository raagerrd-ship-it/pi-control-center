## Mål

Två leverabler, i ordning:

1. **(a) Normativt tjänstekontrakt** i PCC-repot — verifierat mot `pi-control-center-api.sh` så templaten (och alla framtida tjänster) bygger på fakta, inte föråldrad docs.
2. **(b) Skiss av `pcc-service-template`-repot** — filstruktur och innehåll, redo att bli ett nytt Lovable-projekt + GitHub template repository.

Det här är ett dokument- och planeringsuppdrag. Ingen kod i `src/`, ingen ändring av runtime-beteende.

---

## Del a — Tjänstekontrakt i PCC

### Bakgrund: gaps mellan nuvarande docs och verklighet

Vid genomgång av `pi-control-center-api.sh` mot `public/SERVICE-INTEGRATION.md` hittade jag följande som måste rättas eller läggas till:

| Område | Docs säger | Koden gör | Åtgärd |
|---|---|---|---|
| `installDir` | `$HOME/.local/share/...` | `/opt/<key>` (alla tre live-tjänster) | Uppdatera docs till `/opt/<key>` som rekommendation |
| `MemoryMax` | Hårdkodat 128M | Dynamiskt via `memoryProfile.levels.{low,balanced,high}` + autoscale 85%↑ / 45%↓ | Dokumentera nya formatet |
| `memoryProfile` | Saknas helt | Krävs i praktiken — driver heap, autoscale, watchdog | Helt nytt avsnitt |
| `writableDirs` | Saknas helt | Läses från registry, PCC chowns `installDir/<dir>` till `pi:pi` efter update | Nytt avsnitt |
| `managed: false` | Saknas | Opt-out från systemd-management | Nytt avsnitt |
| Env-vars | Saknar `NODE_OPTIONS`, `HOME`, `XDG_DATA_HOME`, `NPM_CONFIG_CACHE`, `DBUS_SYSTEM_BUS_ADDRESS` | Sätts av PCC | Komplettera tabellen |
| systemd-unit-mall | Saknas | Faktisk mall finns i koden (rad 1739–1778) | Bifoga som "för referens, generera ej själv" |
| Permissions | Listad ytligt | `bluetooth`/`rfkill`/`audio` triggar `SupplementaryGroups`, `AmbientCapabilities`, `DeviceAllow`, `LimitRTPRIO` | Dokumentera vad varje permission faktiskt ger |
| Heap-storlek | Inte nämnt | `NODE_OPTIONS=--max-old-space-size=<comp_heap_mb>` sätts från memoryProfile | Dokumentera |
| Autoscale-grace | Inte nämnt | 120s grace efter restart, watchdog 98% × 3 strikes | Dokumentera så tjänster vet vad som triggar omstart |

### Leverabel: `public/SERVICE-CONTRACT.md`

Nytt dokument (separat från befintlig `SERVICE-INTEGRATION.md`) som är **det normativa kontraktet**. `SERVICE-INTEGRATION.md` blir guide/tutorial, `SERVICE-CONTRACT.md` blir spec.

Struktur:

```text
1. Scope och versionering (kontraktets version, breaking-change-policy)
2. services.json — fullständigt JSON-schema
   2.1 Tjänstnivåfält (alla, med typer + krav-nivå)
   2.2 components.{engine,ui} — fält + krav
   2.3 memoryProfile — defaultLevel + levels.{low,balanced,high} i MB
   2.4 permissions — exakt lista av tillåtna värden + vad var och en triggar
   2.5 writableDirs — semantik + chown-beteende
   2.6 managed-flaggan
3. Filsystemskontrakt
   3.1 installDir-konvention (/opt/<key>)
   3.2 PCC-ägda kataloger (config/data/log) — sökvägar och livscykel
   3.3 Vad bevaras vid uninstall vs factory reset
4. Process-kontrakt
   4.1 Alla env-vars PCC sätter (komplett tabell)
   4.2 systemd-unit (referens — genereras av PCC, ej av tjänsten)
   4.3 Sandbox-begränsningar (ProtectSystem, ReadWritePaths, AllowedCPUs, MemoryMax)
5. Nätverkskontrakt
   5.1 Portregler (UI = vald, Engine = UI+50)
   5.2 CORS-krav på Engine
   5.3 OPTIONS-hantering
6. Health-kontrakt
   6.1 GET /api/health responsformat
   6.2 Pollingfrekvens (30s) + timeout (5s)
   6.3 Watchdog: 98% × 3 strikes → restart, 5 restarts/6h → protected stop
   6.4 Autoscale-grace (120s efter restart)
7. Release-kontrakt
   7.1 GitHub Release med dist.tar.gz (eller releaseAsset-override)
   7.2 runInstallOnRelease — när och varför
   7.3 Native moduler — npm rebuild på Pi:n
8. Lifecycle-skript
   8.1 install.sh — vad det får/inte får göra
   8.2 update.sh — semantik (PCC sköter restart efteråt)
   8.3 uninstall.sh — vad det rensar (PCC sköter systemd)
9. Versionsupplösning
   9.1 Source of truth: API > VERSION.json > git > package.json
10. Brytande ändringar mot tidigare guide (för befintliga tjänster som behöver migrera)
```

### Implementationsplan för del a

1. **Skapa** `public/SERVICE-CONTRACT.md` med innehåll enligt struktur ovan, alla värden verifierade mot `pi-control-center-api.sh`.
2. **Uppdatera** `public/SERVICE-INTEGRATION.md` med en banner överst: *"Detta är en guide. Det normativa kontraktet finns i SERVICE-CONTRACT.md — vid konflikt vinner kontraktet."* Rätta de specifika felen ovan (installDir, env-vars, MemoryMax) eller stryk dem och länka till kontraktet.
3. **Lägg till** `mem://development/service-contract` som pekar på dokumentet, så framtida AI-sessioner hittar det.

Inga ändringar i `src/`, `pi-control-center-api.sh` eller `services.json`.

---

## Del b — Skiss av `pcc-service-template`

Det här är **bara en skiss/spec** i den här prompten — själva repot skapas i ett separat Lovable-projekt + GitHub-repo (se "Hur du faktiskt skapar repot" nedan).

### Designprinciper

- **Headless som default.** UI är opt-in via en `with-ui`-branch eller separat template. De flesta nya tjänster är headless (Sonos Buddy är de facto headless idag).
- **Inga `examples/`.** Lotus, Sonos, Cast Away är levande exempel i sina egna repon — länka i README istället för att kopiera.
- **Placeholders med tydlig syntax.** `{{SERVICE_KEY}}`, `{{SERVICE_NAME}}`, `{{GITHUB_OWNER}}`, `{{REPO_NAME}}`, `{{DESCRIPTION}}`. Sök/ersätt-säkra (inga kollisioner med JS template literals).
- **Allt fil-innehåll är direkt körbart efter ersättning.** Inga `.template`-suffix — det förstör syntax-highlighting och gör Lovable-utveckling svårare. Använd `{{...}}` direkt i `.json`/`.ts`/`.sh`-filer.
- **Inkluderar GitHub Actions-workflow som faktiskt fungerar** med `node_modules` i tarballen (matchar PCC:s standard).

### Filstruktur

```text
pcc-service-template/
├── README.md                          ← Hur du använder templaten + checklista
├── PCC-CONTRACT-VERSION.txt           ← Vilken version av SERVICE-CONTRACT.md den följer
├── service.json                       ← Snippet att klistra in i PCC:s services.json
├── package.json                       ← Root: orchestrator för engine-bygget
├── tsconfig.json
├── .gitignore
├── .nvmrc                             ← node 24
├── engine/
│   ├── package.json                   ← Engine-deps (express, cors)
│   ├── tsconfig.json
│   └── src/
│       ├── index.ts                   ← HTTP-server + SIGTERM + config-load
│       ├── health.ts                  ← /api/health enligt kontraktet
│       ├── cors.ts                    ← CORS-middleware
│       └── config.ts                  ← Atomic read/write till PCC_CONFIG_DIR
├── scripts/
│   ├── install.sh                     ← Fallback-install (port/core flags)
│   ├── update.sh                      ← Git pull + rebuild
│   └── uninstall.sh                   ← Rensar installDir (ej systemd)
└── .github/
    └── workflows/
        └── release.yml                ← Bygg + tar + release på tag-push
```

### Nyckelfiler — minsta körbara innehåll

**`service.json`** (snippet, ej standalone):
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

**`engine/src/index.ts`** — minimum viable engine:
- Läser `PORT` från env, defaultar till 3050
- CORS + OPTIONS-hantering
- `/api/health` enligt kontrakt (status, service, version, uptime, memory)
- `/api/status` för app-specifik state
- SIGTERM-handler som stänger servern graceful
- Config-laddning från `process.env.PCC_CONFIG_DIR + "/settings.json"` med atomic write
- Inga `console.log` i hot paths

**`scripts/install.sh`** — handlar `--port` och `--core` flags, men gör nästan ingenting (eftersom release-flödet är default).

**`.github/workflows/release.yml`** — exakt mönstret från `SERVICE-INTEGRATION.md` rad 358–389: build → `npm install --omit=dev --package-lock=false` → `tar czf dist.tar.gz engine/dist engine/node_modules engine/package.json scripts/`.

**`README.md`** — checklista och placeholder-tabell:

```text
## Skapa en ny tjänst från templaten

1. Klicka "Use this template" på GitHub → skapa nytt repo `<din-tjänst>`
2. Klona i Lovable eller lokalt
3. Sök/ersätt globalt:
   - {{SERVICE_KEY}}     → din-tjanst (kebab-case, inga mellanslag)
   - {{SERVICE_NAME}}    → "Din Tjänst" (visningsnamn)
   - {{GITHUB_OWNER}}    → ditt-github-namn
   - {{REPO_NAME}}       → din-tjanst
   - {{DESCRIPTION}}     → Kort beskrivning
4. Bygg din funktionalitet i engine/src/
5. Push tag (git tag v0.1.0 && git push --tags) → release skapas automatiskt
6. Lägg till service.json-snippet i PCC-repots public/services.json
7. Push PCC → tryck "Hämta senaste tjänstkatalog" på Pi:n
8. Tjänsten dyker upp i installationsdialogen
```

### Hur du faktiskt skapar repot (manuellt steg, utanför Lovable)

Lovable kan inte skapa nya GitHub-repon från template åt dig. Workflow:

1. **I PCC (det här projektet):** Vi skapar `SERVICE-CONTRACT.md` och en fil `docs/template-skiss.md` med all skissad fil-innehåll, så det är klippbart material.
2. **Manuellt:** Skapa nytt Lovable-projekt → koppla till nytt GitHub-repo `pcc-service-template` → be Lovable skapa filerna baserat på `docs/template-skiss.md` (du kan klistra in skissen).
3. **På GitHub:** Settings → "Template repository" ✅.
4. **Klart.** Nästa gång du vill ha en ny tjänst: "Use this template" → ny repo → klona i Lovable → sök/ersätt placeholders → utveckla.

---

## Vad jag INTE gör

- Skapar inte `pcc-service-template`-repot i den här loopen (kan inte — kräver nytt Lovable-projekt + nytt GitHub-repo).
- Ändrar inte `pi-control-center-api.sh`, `services.json`, eller någon `src/`-fil.
- Tar inte bort `SERVICE-INTEGRATION.md` — den blir kvar som tutorial, men markeras som icke-normativ.
- Lägger inte till någon UI-flik eller knapp i dashboarden för templaten.

---

## Konkreta filer som skapas/ändras

| Fil | Åtgärd |
|---|---|
| `public/SERVICE-CONTRACT.md` | **Ny** — normativt tjänstekontrakt |
| `public/SERVICE-INTEGRATION.md` | **Editera** — banner överst + rätta installDir, env-vars, MemoryMax |
| `docs/template-skiss.md` | **Ny** — komplett skiss/innehåll för `pcc-service-template`-repot, klart att klistra in i ett nytt Lovable-projekt |
| `mem://development/service-contract` | **Ny memory** — pekare så framtida sessioner hittar kontraktet |
| `mem://index.md` | **Editera** — lägg till raden i Memories-listan |

---

## Bekräftelse innan jag kör

Säg till om du vill:
- **Köra hela planen** (a + b-skiss).
- **Bara köra del a** (kontraktet) först, hantera template-skissen separat.
- **Justera scope** — t.ex. utelämna `docs/template-skiss.md` och bara ge skissen i chatten istället.
