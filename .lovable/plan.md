## Mål

Stoppa `status_cache_loop` från att bygga `build_status_json` var 4:e sekund i evighet. Cachen ska bara byggas när någon faktiskt tittar på UI:t. När ingen tittar = noll status-arbete.

`health_poll_loop` och `watchdog_loop` (var 30:e sekund) lämnas orörda — de gör nytta även utan UI (auto-heal, auto-restart).

## Bakgrund

Idag i `pi-control-center-api.sh`:

- `status_cache_loop` (rad 1496–1506) bygger `build_status_json` var `CACHE_MAX_AGE`-sekund (default 4s) — ~21 600 builds/dygn även när ingen är inloggad.
- `get_cached_status` (rad 1486–1493) serverar alltid från fil — backgroundloopen är enda som håller den färsk.
- Frontend pollar `/api/status` var 5:e sekund när fliken är synlig och stannar helt när `document.hidden` (redan implementerat i `useSystemStatus.ts`).

Slutsats: backgroundloopen är ren overhead när UI:t är stängt.

## Ändring

Allt i `public/pi-scripts/pi-control-center-api.sh`. Inga UI-ändringar, inget API-kontrakt påverkas.

### 1. Aktivitetsstämpel vid varje statusrequest

Lägg till en `LAST_STATUS_REQUEST_FILE` (t.ex. `$STATUS_DIR/last-request.ts`). I HTTP-handlern för `/api/status` (där `get_cached_status` anropas) skriv `date +%s` till filen innan svaret skickas.

### 2. Lat backgroundloop

Ändra `status_cache_loop` så den:

```text
loop:
  sleep CACHE_MAX_AGE  (4s)
  last=$(cat LAST_STATUS_REQUEST_FILE 2>/dev/null || echo 0)
  now=$(date +%s)
  if (now - last) <= ACTIVE_WINDOW (60s):
    bygg cache
  else:
    fortsätt sova
```

Effekt: så länge UI:t pollat senaste 60s håller loopen cachen varm (oförändrat beteende för användaren). När UI:t stängs slutar loopen bygga inom 60s.

### 3. Synkron build vid kall cache

Ändra `get_cached_status` så att om `LAST_STATUS_REQUEST_FILE` saknas eller är >`ACTIVE_WINDOW` gammal (= första öppningen efter idle):

- bygg `build_status_json` synkront
- skriv till cache
- returnera direkt

Användaren får då vänta ~en bygg-tid (typ 200–500 ms) på första pollen efter att ha öppnat UI:t igen, sen är det varmt och loopen tar över.

Den initiala builden i `status_cache_loop`-start tas bort (onödig — cachen byggs nu lat när någon ber om den).

### 4. Skipa initial cache-build vid daemon-start

Rad 3829 (`status_cache_loop &`) lämnas, men funktionens initial-build (rad 1499–1500) tas bort. Backgroundloopen börjar direkt i sleep-läge.

## Tekniska detaljer

- `ACTIVE_WINDOW=60` (konstant nära `CACHE_MAX_AGE` i toppen av filen). 60s ger bra marginal för UI:ts 5s-poll + ev. backoff utan att bygga i onödan.
- Stämpelfilen ligger redan på tmpfs (`STATUS_DIR` under `/tmp/pi-control-center/`), så ingen disk-IO-overhead.
- `get_cached_status` skriver också `LAST_STATUS_REQUEST_FILE` (om HTTP-handlern råkar gå förbi den). Säkerhetsnät — primär skrivning sker i HTTP-routen.
- `health_poll_loop` och `watchdog_loop` rörs INTE.
- Autoscaler-invarianten påverkas inte (autoscaler trigggas från `watchdog_loop`, inte från status-cachen).

## Verifieringskriterier

1. `bash -n public/pi-scripts/pi-control-center-api.sh` passerar.
2. På Pi:n efter deploy, med UI stängt i 2 minuter:
   - `top -b -n 5 -d 5 -p $(pgrep -f pi-control-center-api)` visar nära 0% CPU för API-processen.
   - `ls -la --time=ctime $STATUS_DIR/status-cache.json` ändras inte oftare än ~var 60–90:e sekund (bara health/watchdog-skrivningar).
3. Öppna UI:t: första pollen tar märkbart längre (200–800 ms istället för instant), efterföljande är instant. Status visar färsk data.
4. Stäng UI:t: inom 60s slutar `status-cache.json` att uppdateras.

## Utanför scope

- Migrera till Python-daemon med in-memory cache (separat större grepp).
- Ändra polling-intervall i frontend.
- Röra `health_poll_loop` eller `watchdog_loop`.
