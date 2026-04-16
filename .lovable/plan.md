

## Problem: Dashboard tappar anslutning under operationer

### Orsak
När Pi:n kör tunga operationer (npm install, vite build) spikar CPU/RAM. API:ts `/api/status`-endpoint svarar inte inom 4-sekunders-timeouten. Status-pollern markerar direkt "offline" efter ett enda misslyckat anrop, och skickar dessutom en extra ping-request som belastar Pi:n ytterligare.

### Plan

**1. Grace period innan offline-status**
Kräv 3 misslyckade polls i rad innan connection ändras från `connected` till `offline`/`busy`. Ett enstaka timeout ska inte flippa UI:t.

**2. Längre timeout under aktiva operationer**
Öka `fetchSystemStatus`-timeout från 4s till 8s när en installation eller uppdatering pågår. Exponera en `isBusy`-signal från `useServiceUpdate` som `useSystemStatus` kan använda.

**3. Långsammare polling under last**  
Öka `BASE_INTERVAL` till 10s när en operation är aktiv. Pi:n behöver inte rapportera status var 5:e sekund under en build.

**4. Skippa ping vid känd operation**
Om vi vet att en install/update körs, skippa extra `fetchPing()`-anropet vid statusfel — vi vet redan att Pi:n är upptagen.

### Filer som ändras

- **`src/hooks/useSystemStatus.ts`** — Grace period (3 fails), dynamiskt intervall, skippa ping vid busy
- **`src/lib/api.ts`** — Acceptera valfri timeout-parameter i `fetchSystemStatus`
- **`src/pages/Index.tsx`** — Skicka `isBusy`-flagga från useServiceUpdate till useSystemStatus

### Teknisk detalj

```text
Poll OK  → connection = connected, failCount = 0
Poll FAIL #1 → behåll senaste connection-state  
Poll FAIL #2 → behåll senaste connection-state
Poll FAIL #3 → ping → busy/offline
Operation aktiv → interval 10s, timeout 8s, skippa ping
```

