

## Pi Control Center — Tjänsteisolering och Backend/Frontend-separation

### Problem idag

1. **Ingen strikt CPU-isolering** — `CPUAffinity` i systemd är en *önskan*, inte ett hårdt krav. Processer kan fortfarande sprida sig.
2. **Tjänster kan påverka systemet** — installskript kör med sudo och kan ändra hostname, /etc/hosts etc.
3. **Monolitiska tjänster** — om du uppdaterar eller startar om en tjänst tappar du både backend-logik och UI samtidigt.

### Lösning

#### 1. Strikt CPU-isolering via cgroups

Använd `AllowedCPUs=` i systemd (cgroups v2) istället för enbart `CPUAffinity`. Detta är en hård begränsning — processen *kan inte* köra på andra kärnor.

```text
[Service]
CPUAffinity=2          # önskan (scheduling hint)
AllowedCPUs=2          # hård gräns (cgroup)
MemoryMax=128M         # minnestak per tjänst
```

Ändring i `pi-dashboard-api.sh` → `do_install_release()` och legacy-installationen, där systemd-unit-filen genereras.

#### 2. Sandboxad installation — begränsa vad tjänster får göra

Lägg till systemd-sandboxing i genererade service-filer:

```text
ProtectSystem=strict          # /usr, /boot, /etc skrivskyddade
ProtectHome=read-only         # $HOME skrivskyddat (utom WorkingDirectory)
ReadWritePaths={installDir}   # bara sin egen katalog
PrivateTmp=true               # isolerat /tmp
NoNewPrivileges=true          # kan inte eskalera rättigheter
```

Tjänstens installskript körs fortfarande med fulla rättigheter under installation, men **den körande tjänsten** kan inte ändra hostname, /etc/hosts eller andra systemfiler.

#### 3. Backend/Frontend-separation i services.json

Utöka `services.json` med stöd för tjänster som har separata backend- och frontend-komponenter:

```json
{
  "key": "lotus-light",
  "name": "Lotus Light Link",
  "components": {
    "engine": {
      "type": "node",
      "entrypoint": "pi/start-lotus.js",
      "service": "lotus-light-engine",
      "alwaysOn": true
    },
    "ui": {
      "type": "static",
      "entrypoint": "dist/",
      "service": "lotus-light-ui",
      "alwaysOn": false
    }
  },
  "repo": "...",
  "installDir": "/opt/lotus-light"
}
```

- **engine** — kör alltid, startar om automatiskt, uppdateras separat
- **ui** — kan stoppas/startas/uppdateras utan att motorn påverkas
- Bakåtkompatibelt: tjänster utan `components` behandlas som idag (en enda process)

#### 4. UI-ändringar i dashboarden

Varje tjänstekort visar **två rader** om tjänsten har components:

```text
┌─────────────────────────────┐
│  Lotus Light Link           │
│  ● Motor    v1.2  [↻] [⏹]  │
│  ○ UI       v1.2  [↻] [▶]  │
│  CPU: 2.1%   RAM: 45MB      │
└─────────────────────────────┘
```

- Motorn och UI:t kan startas/stoppas/uppdateras oberoende
- "Uppdatera" på motorn gör en mjuk omstart (graceful restart)

### Filer som ändras

| Fil | Ändring |
|-----|---------|
| `public/services.json` | Nytt `components`-format (bakåtkompatibelt) |
| `public/SERVICE-INTEGRATION.md` | Dokumentation för backend/frontend-mönstret + isoleringsregler |
| `public/pi-scripts/pi-dashboard-api.sh` | Generera sandboxade systemd-units med `AllowedCPUs`, `ProtectSystem`, stöd för dubbla services per tjänst |
| `src/lib/api.ts` | Utöka `SystemStatus.services` med component-info (engine/ui status) |
| `src/components/CoreCard.tsx` | Visa motor + UI separat med individuella kontroller |
| `src/pages/Index.tsx` | Hantera per-component actions |

### Prioriteringsordning

1. **CPU-isolering + sandboxing** i systemd-generering (backend-skript)
2. **Backend/frontend-separation** i services.json + API
3. **UI-uppdateringar** i dashboarden

Vill du att jag kör igenom detta?

