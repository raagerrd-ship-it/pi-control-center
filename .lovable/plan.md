
## Rekommendation: ja till gemensam Node-runtime, nej till gemensam Node-process

Jag tycker idén är bra om vi menar:

**En Node.js-installation som PCC äger och alla tjänster startas med.**

Jag skulle däremot inte lägga Sonos, Lotus och Cast Away i **samma Node-process**, eftersom det tar bort isoleringen. Om Lotus får minnesläcka eller hamnar i loop kan den då påverka de andra direkt. Dagens modell med separata systemd-tjänster är säkrare för Pi:n.

Rätt modell blir:

```text
PCC installerar/äger Node.js v24
        │
        ├── Sonos engine körs som egen systemd-tjänst
        ├── Lotus engine körs som egen systemd-tjänst
        └── Cast Away engine körs som egen systemd-tjänst

Alla använder samma node-binär,
men har egna node_modules, egna portar, egen CPU-kärna, egen MemoryMax.
```

## Varför detta är bättre

- Mindre risk för olika Node-versioner mellan appar.
- Enklare felsökning: PCC kan visa exakt vilken Node-version alla tjänster kör på.
- Mindre installationsstrul.
- Bättre kontroll över minnesgränser via gemensamma `NODE_OPTIONS`.
- Vi behåller sandboxing, watchdog, CPU-pinning och systemd-isolering.

## Viktig gräns

Jag skulle **inte** dela `node_modules` globalt mellan tjänsterna.

Sonos, Lotus och Cast Away har olika beroenden:

- Sonos: egna bild/UPnP-relaterade moduler.
- Lotus: BLE/native-moduler som måste matcha Pi/Node-version.
- Cast Away: Chromecast/mDNS-relaterade moduler.

Delade dependencies kan ge versionskrockar och konstiga fel. Varje app bör fortfarande paketera eller installera sina egna produktionsberoenden.

## Plan: PCC-ägd Node-runtime för alla tjänster

### 1. Gör Node v24 till PCC:s systemruntime

Uppdatera installer/update-flödet så PCC säkerställer att rätt Node-version finns på Pi:n.

- Ändra från nuvarande Node 20-installation till Node 24.
- Lägg till tydlig kontroll:
  - om Node saknas: installera Node v24
  - om fel major-version finns: uppgradera till Node v24
- Logga versionen i install-output.

Målet är att Pi:n alltid har en stabil, gemensam `/usr/bin/node` som PCC kontrollerar.

### 2. Lägg till runtime-helper i API-skriptet

I `pi-control-center-api.sh` läggs helpers till:

- `get_node_bin`
- `get_node_version`
- `assert_node_runtime`
- eventuellt `node_runtime_json`

Dessa används både vid installation och när systemd-units skapas.

### 3. Ändra genererade systemd-units

När PCC skapar engine-tjänster ska de använda PCC:s Node-runtime explicit.

I stället för hårdkodat:

```ini
ExecStart=/usr/bin/node /opt/app/engine/index.js
```

ska PCC generera något i stil med:

```ini
ExecStart=/usr/bin/node --max-old-space-size=96 /opt/app/engine/index.js
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=96
```

Exakt minnesvärde kan styras konservativt per engine.

### 4. Behåll separata tjänster och separata dependencies

PCC ska fortfarande skapa:

- en engine-service per app
- en UI-service per app
- separata `node_modules` per app om appen behöver det
- separat `MemoryMax`
- separat watchdog-state

Detta bevarar nuvarande säkerhetsmodell.

### 5. Justera release/install-regeln

Uppdatera dokumentationen och appstandarden:

- Appar ska inte installera egen Node.
- Appar ska anta att `node` finns via PCC.
- Releases ska fortfarande innehålla produktionsberoenden om möjligt.
- Native-moduler får byggas/rebuildas mot PCC:s Node-version vid installation.

Detta passar särskilt Lotus, eftersom BLE/native-moduler måste matcha runtime-versionen.

### 6. Visa Node-runtime i UI/status

Utöka `/api/status` med runtime-info:

```json
{
  "runtime": {
    "nodeVersion": "v24.x.x",
    "nodePath": "/usr/bin/node"
  }
}
```

UI kan visa detta diskret i systempanelen eller inställningar:

```text
Node-runtime: v24.x.x
```

### 7. Uppdatera dokumentationen

Uppdatera:

- `SERVICE-INTEGRATION.md`
- `SERVICE-ARCHITECTURE.md`
- projektminnet för standards/arkitektur

Ny regel:

```text
PCC äger Node.js-runtime. Tjänster får använda node, men ska inte installera egen Node-version.
```

## Det jag inte skulle bygga nu

Jag skulle inte bygga en gemensam “app-host” där alla tjänster laddas in i en och samma Node-process.

Det skulle spara lite RAM, men kostnaden är för hög:

- sämre isolering
- en app kan krascha alla
- svårare watchdog
- svårare MemoryMax per app
- svårare BLE/mDNS/Chromecast-felsökning
- större risk att Pi:n låser sig

## Resultat

Efter ändringen får vi:

- en gemensam, kontrollerad Node v24-runtime
- mindre versionsstrul
- fortsatt isolering per tjänst
- bättre stabilitet på Pi Zero 2
- enklare appstandard för Sonos, Lotus och Cast Away
- ingen risk att en trasig app drar med sig resten
