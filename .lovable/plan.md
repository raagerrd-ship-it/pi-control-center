
## Plan: liten watchdog som skyddar Pi:n från hängda tjänster

Jag lägger till en lättvikts-övervakning i Pi Control Center API:t som körs i bakgrunden och använder redan tillgänglig `/proc` + systemd-data. Målet är att stoppa/restarta tjänster som fastnar i CPU-loopar, tappar sin hälsocheck eller närmar sig/minnesgränsen — utan att belasta Pi Zero 2.

## Vad som byggs

1. **Watchdog-loop i API:t**
   - Kör ungefär var 30:e sekund, bredvid befintlig `health_poll_loop`.
   - Övervakar varje installerad tjänsts engine/UI-komponent.
   - Läser:
     - CPU %
     - RAM MB
     - systemd `MemoryMax`
     - om porten svarar
     - `/api/health` om tjänsten har det
     - antal watchdog-ingripanden senaste tiden

2. **Skydd mot oändliga loopar**
   - Om en engine ligger väldigt högt i CPU under flera mätningar i rad, markeras den som misstänkt hängd.
   - Första åtgärd: restart av tjänsten.
   - Om samma tjänst fortsätter trigga upprepade gånger: stoppas den och märks som skyddsstoppad, så den inte startar om i evig krasch-loop.

3. **Skydd mot minnesläckor**
   - Behåll befintliga `MemoryMax`-gränser.
   - Lägg till preemptiv varning/åtgärd:
     - över ca 85% av sin limit: varning i status
     - över ca 95% under flera mätningar: restart innan Pi:n blir instabil
   - Om systemd själv dödar tjänsten pga `MemoryMax`, UI ska visa att den stoppades pga minne.

4. **Skydd mot hängd men “aktiv” tjänst**
   - Om systemd säger `active` men porten eller `/api/health` inte svarar under flera checks:
     - restart upp till ett litet maxantal
     - sedan skyddsstopp för att undvika loop

5. **Status till UI**
   - Utöka `ServiceStatus`/`ComponentStatus` med watchdog-info, t.ex:
     - `watchdog.status`: `ok | warning | restarting | protected | disabled`
     - `watchdog.reason`: `high_cpu | high_memory | health_timeout | restart_loop`
     - `watchdog.restartCount`
     - `watchdog.lastAction`
   - Visa diskret rad i varje tjänstkort:
     - `Skydd: OK`
     - `Varning: hög RAM`
     - `Restartad av watchdog`
     - `Skyddsstoppad: CPU-loop`

6. **Manuell återställning**
   - När användaren trycker Starta/Restart i UI efter ett skyddsstopp nollställs watchdog-låset för den tjänsten.
   - Alternativt lägga till API-hantering så service action automatiskt rensar watchdog-state.

7. **Säkra defaults**
   - Inga aggressiva restart direkt.
   - Trösklarna görs konservativa:
     - CPU måste vara högt flera mätningar i rad.
     - Minne måste ligga nära limit flera mätningar i rad.
     - Health/port måste faila flera gånger.
   - Watchdog-state sparas i `/tmp/pi-control-center/watchdog/`, så det överlever korta API-förfrågningar men nollställs vid reboot.

## Tekniska ändringar

- `public/pi-scripts/pi-control-center-api.sh`
  - Lägg till `WATCHDOG_DIR`.
  - Lägg till helpers för:
    - läsa `MemoryMax`
    - läsa component PID
    - räkna consecutive failures
    - restart/stop med system/user systemd
    - JSON-state per app/component
  - Lägg till `watchdog_loop &` vid startup.
  - Integrera watchdog-data i `/api/status`.
  - Rensa watchdog-lås vid `POST /api/service/.../start|restart`.
  - Respektera `managed:false` och `manageService:false`:
    - Lotus kan läsas/övervakas
    - men PCC ska inte aggressivt skriva om eller ta bort dess systemd-unit
    - restart/stop sker bara mot korrekt befintlig system/user service

- `src/lib/api.ts`
  - Utöka TypeScript-typer med watchdogfält.

- `src/components/CoreCard.tsx`
  - Visa kort watchdog-status på komponent- eller tjänstnivå.
  - Använd befintlig mörk/terminal UI-stil och svenska texter.

- Eventuellt `mem://features/health-monitoring`
  - Uppdatera minnet med den nya watchdog-regeln så framtida ändringar följer samma modell.

## Resultat

Pi Control Center får en liten “säkerhetsvakt” som:
- fångar CPU-loopar
- fångar minnesläckor innan de kraschar Pi:n
- restartar tjänster som hänger
- stoppar tjänster som fortsätter krascha
- visar tydligt i UI vad som hänt
- gör detta med låg overhead anpassad för Pi Zero 2
