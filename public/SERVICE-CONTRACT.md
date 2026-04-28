# Pi Control Center — Service Contract

**Kontraktsversion:** 1.0 (2026-04-28)
**Källa:** Verifierat mot `public/pi-scripts/pi-control-center-api.sh`.
**Status:** Normativt. Vid konflikt med `SERVICE-INTEGRATION.md` vinner detta dokument.

> Det här är spec:en — ett kontrakt mellan PCC (operativsystemet) och tjänster (programmen).
> `SERVICE-INTEGRATION.md` är en tutorial som visar *hur* man bygger en tjänst.
> Det här dokumentet definierar *vad* en tjänst måste uppfylla för att fungera.

---

## 1. Scope och versionering

### 1.1 Vad kontraktet täcker

- Schemat för `services.json` (registry-format)
- Sökvägar och kataloger PCC äger åt tjänsten
- Miljövariabler PCC sätter
- Sandbox-begränsningar i den genererade systemd-uniten
- Nätverk, portar och CORS-krav
- Health-endpointens format och pollingbeteende
- Watchdog/autoscale-tröskelvärden
- Release-, install-, update- och uninstall-flöden

### 1.2 Vad kontraktet INTE täcker

- Tjänstens interna affärslogik
- Val av webserver, ORM, etc. inuti tjänsten
- Frontend-ramverk för UI-komponenten

### 1.3 Breaking-change-policy

PCC siktar på *systemrenhet före bakåtkompatibilitet* (core memory). Brytande ändringar i kontraktet bumpar kontraktsversionen och dokumenteras i avsnitt 10. Tjänster ska inkludera `PCC-CONTRACT-VERSION.txt` i sitt repo som anger vilken kontraktsversion de följer.

---

## 2. services.json — fullständigt schema

`services.json` är en JSON-array av tjänsteobjekt. Filen ligger i PCC-repots `public/services.json` och deployas till `/var/www/pi-control-center/services.json` på Pi:n. Den kan också uppdateras isolerat via "Hämta senaste tjänstkatalog"-knappen.

### 2.1 Tjänstnivåfält

| Fält | Typ | Krav | Beskrivning |
|---|---|---|---|
| `key` | `string` | ✅ | Unikt ID. Endast `[a-zA-Z0-9_-]`. Används som prefix i alla genererade resurser. |
| `name` | `string` | ✅ | Visningsnamn i dashboarden. |
| `repo` | `string` | ✅ | Git-klon-URL. Används som fallback om `releaseUrl` inte finns eller misslyckas. |
| `releaseUrl` | `string` | ⭐ | GitHub Releases API-URL för förbyggda nedladdningar. Format: `https://api.github.com/repos/<owner>/<repo>/releases/latest`. |
| `releaseAsset` | `string` | 🔹 | Filnamn på asset att ladda ner. Default: `dist.tar.gz`. |
| `installDir` | `string` | ✅ | Absolut sökväg. **Konvention: `/opt/<key>`.** Måste vara skrivbar för `pi:pi`. |
| `runInstallOnRelease` | `boolean` | 🔹 | `true` = PCC kör `npm install --omit=dev` (eller `npm rebuild`) efter uppackning. Sätt till `true` om motorn har **native moduler** (Bluetooth, sharp, sqlite3) som måste kompileras för Pi:ns ARM/Node-version. |
| `permissions` | `string[]` | 🔹 | OS-behov tjänsten behöver. Se 2.4. |
| `writableDirs` | `string[]` | 🔹 | Sökvägar relativa `installDir` som PCC `chown:ar` till `pi:pi` efter varje update. Se 2.5. |
| `memoryProfile` | `object` | ⭐ | Minnesprofiler. Se 2.3. |
| `managed` | `boolean` | 🔹 | Default `true`. Sätt till `false` för att opt:a ut från PCC:s systemd-management. |
| `installScript` | `string` | ✅ | Sökväg relativt repo-root. Körs vid fallback-install (om release inte finns). |
| `updateScript` | `string` | ✅ | **Absolut** sökväg på Pi:n (finns efter installation). Typiskt `/opt/<key>/scripts/update.sh`. |
| `uninstallScript` | `string` | ✅ | Sökväg relativt repo-root. |
| `components` | `object` | ⭐ | Engine/UI-definition. Se 2.2. |
| `type` / `entrypoint` / `service` | `string` | 🔸 | Endast legacy (icke-component-baserade tjänster). Använd `components` istället. |

✅ = krävs · ⭐ = starkt rekommenderat · 🔹 = valfritt · 🔸 = legacy

### 2.2 components.{engine,ui}

| Fält | Typ | Krav | Beskrivning |
|---|---|---|---|
| `type` | `"node"` \| `"static"` | ✅ | `node` för engine, `static` för UI. |
| `entrypoint` | `string` | ✅ | För `node`: sökväg relativt `installDir` till JS-filen (`engine/dist/index.js`). För `static`: sökväg till katalog (`dist/`). |
| `service` | `string` | ✅ | systemd-tjänstnamn, t.ex. `<key>-engine` eller `<key>-ui`. |
| `alwaysOn` | `boolean` | ✅ | `true` → `Restart=always`. `false` → `Restart=on-failure`. Engine ska vara `true`, UI typiskt `false`. |
| `healthEndpoint` | `string` | 🔹 | Default `/api/health`. |

### 2.3 memoryProfile

```json
"memoryProfile": {
  "defaultLevel": "balanced",
  "levels": { "low": 100, "balanced": 140, "high": 200 }
}
```

| Fält | Krav | Beskrivning |
|---|---|---|
| `defaultLevel` | ✅ | En av `levels`-nycklarna. Tjänsten startar på denna nivå. |
| `levels` | ✅ | Map från nivånamn till **MB**. Måste innehålla minst `low`, `balanced`, `high`. |

**Vad PCC gör med profilen:**
- Sätter `MemoryMax=<nivå>M` i systemd-uniten.
- Sätter `NODE_OPTIONS=--max-old-space-size=<nivå>` (heap = MemoryMax i MB; PCC kan justera nedåt för overhead).
- Autoscale flyttar tjänsten upp/ner mellan nivåer baserat på användning (se 6.4).
- **Minsta tillåtna värde:** `MIN_MEMORY_MB = 80`. Värden under detta klampas upp.

### 2.4 permissions

Tillåtna värden och vad var och en triggar i systemd-uniten:

| Permission | Triggar |
|---|---|
| `network` | Inga extra inställningar (default-tillstånd). Deklarativt. |
| `multicast` | Deklarativt — för UI-visning av krav. |
| `bluetooth` | `SupplementaryGroups=netdev bluetooth audio`, `NoNewPrivileges=false`, `AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_SYS_NICE`, `DeviceAllow=/dev/rfkill rw` |
| `rfkill` | Som `bluetooth` (samma capability-set) |
| `audio` | `SupplementaryGroups` inkluderar `audio`, `DeviceAllow=char-alsa rw`, `DeviceAllow=/dev/snd rw`, `LimitRTPRIO=99`, `LimitNICE=-20` |
| `usb` | Deklarativt. |

Permissions exponeras till tjänsten som `PCC_PERMISSIONS=bluetooth,multicast` (kommaseparerad).

### 2.5 writableDirs

```json
"writableDirs": ["pi/data", "cache"]
```

Sökvägar **relativa `installDir`**. Efter varje install/update kör PCC:
```bash
chown -R pi:pi "${installDir}/${dir}"
```

Använd för katalogen **inom kodtreet** som måste vara skrivbar i runtime (t.ex. om en native-modul förväntar sig skrivrättigheter i sin egen katalog).

> För användardata: använd hellre `PCC_DATA_DIR` (se 4.1). Det är **utanför** `installDir` och bevaras vid uppdateringar.

### 2.6 managed-flaggan

```json
"managed": false
```

När `false`:
- PCC genererar **inga** systemd-units.
- PCC startar/stoppar/restartar **inte** tjänsten automatiskt.
- Tjänsten ansvarar själv för sin lifecycle.
- Health-polling och watchdog stängs av.

Default är `true` (managed). Använd bara `false` för specialfall där en extern komponent äger lifecycle.

---

## 3. Filsystemskontrakt

### 3.1 installDir

- **Konvention:** `/opt/<key>`
- Skrivbar för `pi:pi`.
- Ersätts (delvis eller helt) vid varje update — **lagra inget persistent här**.
- Tjänsten ser den som `ReadWritePaths=<installDir>` i sandboxen.

### 3.2 PCC-ägda kataloger

PCC skapar och äger tre kataloger per tjänst, **utanför `installDir`**, som överlever uppdateringar:

| Katalog | Sökväg | Syfte |
|---|---|---|
| Config | `/etc/pi-control-center/apps/<key>` | Inställningar, secrets, parade enheter |
| Data | `/var/lib/pi-control-center/apps/<key>` | State, sparfiler, cache som ska överleva uppdateringar |
| Log | `/var/log/pi-control-center/apps/<key>` | Applikationsloggar |

Alla tre exponeras som env-vars (se 4.1) och ingår i `ReadWritePaths` i sandboxen.

### 3.3 Bevarande vid uninstall vs factory reset

| Operation | installDir | Config | Data | Log |
|---|---|---|---|---|
| Update | Ersätts | Bevaras | Bevaras | Bevaras |
| Uninstall (vanlig) | Tas bort | **Bevaras** | **Bevaras** | **Bevaras** |
| Factory reset | Tas bort | Tas bort | Tas bort | Tas bort |

Det betyder att en användare kan avinstallera och installera om en tjänst utan att förlora inställningar.

---

## 4. Process-kontrakt

### 4.1 Miljövariabler

PCC sätter följande env-vars på alla managed tjänster:

| Variabel | Värde | Notering |
|---|---|---|
| `PORT` | Komponentens egen port | UI = vald port; engine = vald port + 50 |
| `ENGINE_PORT` | Engine-porten | Sätts på båda komponenterna |
| `UI_PORT` | UI-porten | Sätts på båda komponenterna |
| `NODE_ENV` | `production` | Endast på `node`-komponenter |
| `NODE_OPTIONS` | `--max-old-space-size=<heap_mb>` | Heap från `memoryProfile`, endast `node` |
| `PCC_APP_KEY` | Tjänstens `key` | Identifierar tjänsten |
| `PCC_CONFIG_DIR` | `/etc/pi-control-center/apps/<key>` | Persistent config |
| `PCC_DATA_DIR` | `/var/lib/pi-control-center/apps/<key>` | Persistent data |
| `PCC_LOG_DIR` | `/var/log/pi-control-center/apps/<key>` | Loggkatalog |
| `PCC_PERMISSIONS` | t.ex. `bluetooth,multicast` | Kommaseparerad |
| `HOME` | `<PCC_DATA_DIR>/home` | Isolerad HOME per tjänst |
| `XDG_DATA_HOME` | `<PCC_DATA_DIR>/home/.local/share` | XDG-standard |
| `NPM_CONFIG_CACHE` | `<installDir>/.npm-cache` | Lokal npm-cache |
| `DBUS_SYSTEM_BUS_ADDRESS` | `unix:path=/run/dbus/system_bus_socket` | Endast på engines |

### 4.2 systemd-unit (referens)

PCC genererar denna unit. **Tjänster ska inte skapa egna systemd-units.** Visas här bara så du förstår körmiljön:

```ini
[Unit]
Description=<key> <component> service
After=network.target

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=<installDir eller subkatalog>
ExecStart=<node|python3 ...>
Environment=...                    # se 4.1
CPUAffinity=<core>
AllowedCPUs=<core>                 # hård cgroup-gräns
MemoryMax=<level>M                 # från memoryProfile
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=<installDir>
ReadWritePaths=<PCC_CONFIG_DIR>
ReadWritePaths=<PCC_DATA_DIR>
ReadWritePaths=<PCC_LOG_DIR>
PrivateTmp=true
NoNewPrivileges=true               # false om bluetooth/rfkill
StandardOutput=append:<PCC_LOG_DIR>/<component>.log
StandardError=append:<PCC_LOG_DIR>/<component>.log
Restart=always|on-failure          # från alwaysOn
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 4.3 Sandbox-begränsningar

| Begränsning | Effekt |
|---|---|
| `ProtectSystem=strict` | `/usr`, `/boot`, `/etc` är read-only (utom egen `PCC_CONFIG_DIR`) |
| `ProtectHome=read-only` | Riktiga `$HOME` (`/home/pi`) är read-only — använd `PCC_DATA_DIR` |
| `ReadWritePaths` | Endast `installDir` + PCC-kataloger är skrivbara |
| `PrivateTmp=true` | Isolerat `/tmp` per tjänst |
| `NoNewPrivileges=true` | Kan inte eskalera (utom om `bluetooth`/`rfkill`-permission) |
| `AllowedCPUs=<core>` | Hård cgroup-pinning. Kärna 0 är reserverad för PCC + UI:er. Engines pinnas till kärnor 1–3. |
| `MemoryMax=<level>M` | OOM-killer dödar processen vid överskridning. Autoscale försöker undvika det. |

---

## 5. Nätverkskontrakt

### 5.1 Portregler

Användaren väljer en port i installationsdialogen. Båda komponenterna får sina portar deterministiskt:

| Komponent | Port |
|---|---|
| UI | Vald port (t.ex. `3002`) |
| Engine | Vald port + 50 (t.ex. `3052`) |

Portarna är även satta som `UI_PORT` och `ENGINE_PORT` på båda komponenterna — använd dem hellre än att räkna själv.

### 5.2 CORS-krav (engine)

Engine **måste** svara med:
- `Access-Control-Allow-Origin: *` på alla responses (även fel)
- Hantera `OPTIONS` preflight med `204`
- `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type`

Anledning: UI:t serveras från en annan port (Python SPA-server) → cross-origin från webbläsarens perspektiv.

### 5.3 OPTIONS-hantering

`OPTIONS <vilken som helst>` → `204 No Content` med CORS-headers. Express med `cors`-paketet hanterar detta automatiskt.

---

## 6. Health-kontrakt

### 6.1 Endpoint och responsformat

```
GET <healthEndpoint, default /api/health>
→ 200 OK
```

```json
{
  "status": "ok" | "degraded" | "error",
  "service": "<key>-engine",
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

| Fält | Krav | Notering |
|---|---|---|
| `status` | ✅ | `ok` = grön, `degraded` = gul, `error` = röd. Svara alltid HTTP `200` — PCC tolkar fältet, inte status-koden. |
| `service` | ✅ | Måste matcha `components.engine.service` från registry. |
| `version` | ✅ | Semver. Used för version-resolution (se 9). |
| `uptime` | ✅ | Sekunder sedan processen startade. |
| `memory.rss` | ⭐ | MB. Visas i UI; jämförs mot `MemoryMax`. |
| `timestamp` | ⭐ | ISO 8601. |

### 6.2 Polling

- **Intervall:** 30 sekunder.
- **Timeout:** 5 sekunder. Vid timeout markeras komponenten som `health_timeout`.
- **Fallback:** Om endpointen helt saknas faller PCC tillbaka på `systemctl is-active` + portcheck.

### 6.3 Watchdog-tröskelvärden

Värden från `pi-control-center-api.sh` (verifierat 2026-04-28):

| Konstant | Värde | Vad det betyder |
|---|---|---|
| `WATCHDOG_INTERVAL` | 30s | Hur ofta watchdog kör |
| `WATCHDOG_CPU_LIMIT` | 85% | Trösklen för "hög CPU" |
| `WATCHDOG_MEM_WARN` | 85% | Visar gul varning |
| `WATCHDOG_MEM_RESTART` | 95% | Räknar som "minne-strike" |
| `WATCHDOG_STRIKES` | 3 | Antal strikes innan restart |
| `WATCHDOG_MAX_RESTARTS` | 3 | Max restarts inom watchdog-fönster innan protected stop |

Ett "strike" = en watchdog-tick (30s) där tröskelvärdet överskrids. 3 strikes = 90s sammanhängande problem.

### 6.4 Autoscale-tröskelvärden

| Konstant | Värde | Vad det betyder |
|---|---|---|
| `MEMORY_AUTOSCALE_UP_PCT` | 85% | Trösklen för uppskalning |
| `MEMORY_AUTOSCALE_DOWN_PCT` | 45% | Trösklen för nedskalning |
| `MEMORY_AUTOSCALE_UP_STRIKES` | 2 | 2 strikes (60s) innan upp-bump |
| `MEMORY_AUTOSCALE_DOWN_STRIKES` | 6 | 6 strikes (3min) innan ned-bump |
| `MEMORY_AUTOSCALE_COOLDOWN_SECONDS` | 120s | Cooldown mellan profiländringar |
| `MIN_MEMORY_MB` | 80 | Lägsta tillåtna MemoryMax |

Autoscale flyttar tjänsten mellan nivåerna i `memoryProfile.levels`. Watchdog-restart sker bara om en tjänst slår i taket även på `high`.

---

## 7. Release-kontrakt

### 7.1 GitHub Release-format

PCC förväntar sig en **prebuilt asset** publicerad på GitHub Releases:

- Endpoint: värdet i `releaseUrl` (typiskt `.../releases/latest`)
- Default asset-namn: `dist.tar.gz` (override med `releaseAsset`)
- Innehåll: en tarball som extraheras direkt i `installDir`

Tarballens **rotnivå** ska matcha vad `entrypoint` pekar på. Exempel: om `engine.entrypoint = "engine/dist/index.js"` ska tarballen innehålla `engine/dist/index.js` på rotnivå (inte i en wrapping-mapp).

### 7.2 runInstallOnRelease

| Värde | När använda |
|---|---|
| `false` (default) | Tarballen innehåller redan `node_modules` (rekommenderat — Pi:n behöver inte köra npm install) |
| `true` | Native moduler (Bluetooth, sharp, sqlite3) — PCC kör `npm install --omit=dev` eller `npm rebuild` på Pi:n efter uppackning |

### 7.3 Native moduler

Om någon dependency har `binding.gyp` eller native bindings:
1. Sätt `runInstallOnRelease: true`.
2. PCC söker rekursivt efter `package.json` och kör `npm rebuild` (eller `npm install --omit=dev` om noll moduler installerade).
3. Bygget körs i en transient systemd-scope med `MemoryMax=256M`, `nice -n 15`, `ionice -c 3`.

---

## 8. Lifecycle-skript

Alla skript måste:
- Vara körbara (`chmod +x`)
- Ha **LF**-radslut (PCC konverterar CRLF→LF automatiskt, men bättre att leverera korrekt)
- Returnera exit code `0` vid framgång

### 8.1 install.sh (fallback)

Anropas med:
```bash
./scripts/install.sh --port <ui_port> --core <cpu_core>
```

**Får göra:** `npm install`, `npm run build`, skapa filer i `installDir`.
**Får INTE göra:** Skapa egna systemd-units, ändra systemfiler, ändra hostname, installera systempaket utan användarens vetskap.

### 8.2 update.sh

Anropas av PCC som fallback om release-baserad update misslyckas. Skriptet ansvarar för att hämta ny kod och bygga. **PCC sköter restart efteråt** — skriptet ska inte starta om systemd-tjänsten själv.

### 8.3 uninstall.sh

**Får göra:** `rm -rf "$INSTALL_DIR"`.
**Får INTE göra:** Stoppa/ta bort systemd-units (PCC sköter det), röra `PCC_CONFIG_DIR`/`PCC_DATA_DIR` (factory reset sköter det).

---

## 9. Versionsupplösning

PCC bestämmer "installerad version" enligt denna prioritet:

1. **Engine API:** `version`-fältet från `/api/health` (om engine kör)
2. **`VERSION.json`** i `installDir`: `{ "tag": "...", "version": "...", "name": "..." }` (första matchande fältet vinner)
3. **Git-metadata:** `git describe --tags` i `installDir` om det är ett git-arbetsträd
4. **`package.json`:** `version`-fältet i närmaste `package.json`

CI bör skriva `VERSION.json` vid release (enklare än att stödja git inuti tarballen):
```json
{ "tag": "v1.2.0", "version": "1.2.0" }
```

Update-knappen visas när lokal version != senaste GitHub release-tag.

---

## 10. Brytande ändringar

### 1.0 (2026-04-28)

Initial version av kontraktet. Klargör:
- `installDir` ska vara `/opt/<key>` (inte `$HOME/.local/share/...` som tidigare guide föreslog).
- `MemoryMax` är **dynamisk** via `memoryProfile`, inte hårdkodad till 128M.
- `memoryProfile`, `writableDirs`, `managed` är nu del av schemat.
- Komplett env-var-tabell inkluderar `PCC_DATA_DIR`, `NODE_OPTIONS`, `HOME`, `XDG_DATA_HOME`, `NPM_CONFIG_CACHE`, `DBUS_SYSTEM_BUS_ADDRESS`.
- `PCC_DATA_DIR` är ny — använd den för persistent data, inte `installDir`.

Existerande tjänster (Lotus Light, Cast Away, Sonos Buddy) följer redan kontraktet.
