## Mål

Sänk CPU-baseline och fork-trycket på Pi Zero 2 W genom att ta bort de mest frekventa subprocess-anropen i `pi-control-center-api.sh`. Samma princip som Jules-PR:n: cacha + kombinera istället för att starta nya processer i varje varv. Inga funktionella ändringar.

## Bakgrund

Per `build_status_json` (körs varje gång UI:t pollar status, ~var 2:a sekund) forkas idag uppskattningsvis 50–80 processer för 3 appar med components. Hetast:

- `service_is_active` + `get_service_pid` + `get_service_ram` = **3 separata `systemctl show`** per service (×2 components × N appar).
- Health-blocket (rad 1376–1378) gör **3 separata `jq`-anrop** på samma JSON.
- 8 `for app in $(registry_keys)`-loopar utanför `build_status_json` saknar `_REGISTRY_CACHE_JSON` → varje `_registry_jq` faller tillbaka till diskläsning.
- `assignment_get_core` (rad 545–554) forkar `jq` upp till 3 gånger per anrop (read + 2 typkontroller).
- `installed_release_version` (rad 460–468) forkar `jq` upp till 3 gånger.

## Ändringar

Allt sker i `public/pi-scripts/pi-control-center-api.sh`. Inga UI-ändringar, inget API-kontrakt påverkas.

### 1. Slå ihop systemctl-anrop per service

Ersätt `service_is_active`, `get_service_pid`, `get_service_ram` med en gemensam `_service_show <svc>` som gör **ett** anrop:

```text
systemctl show svc.service -p ActiveState,MainPID,MemoryCurrent
```

…och cachar resultatet i en assoc-array per `build_status_json`-varv. Befintliga wrappers behålls som tunna läsare av cachen för bakåtkompatibilitet med övriga callsites. Fallback till `user_systemctl` som idag när system-scopet inte har servicen.

**Win:** ~3× färre systemctl-forks per service (engine + ui + dashboard + nginx).

### 2. En `jq` för health-JSON

Rad 1376–1378: ersätt tre `jq -r` med ett enda anrop som tab-separerar:

```text
read -r health_status health_uptime health_mem_rss < <(echo "$health_json" | jq -r '[.status//"unknown", .uptime//0, .memory.rss//0] | @tsv')
```

**Win:** 2 färre forks per app per status-varv.

### 3. Sätt `_REGISTRY_CACHE_JSON` runt alla registry-loopar

8 loopar utanför `build_status_json` / `health_poll_loop` / `watchdog_loop` läser `services.json` från disk via `_registry_jq`-fallback varje gång. Wrappa varje `for app in $(registry_keys); do … done` med:

```text
_REGISTRY_CACHE_JSON=$(cat "$REGISTRY_FILE" 2>/dev/null)
for app in $(registry_keys); do …; done
unset _REGISTRY_CACHE_JSON
```

Berör rad 2073, 2104, 2170, 2941, 3610, 3701, 3756. Funktioner som anropar dessa loopar i sin tur ärver redan cachen.

### 4. Kollapsa `assignment_get_core`

Rad 545–554 → ett `jq` med inbyggd typhantering:

```text
jq -r --arg k "$1" '
  (.[$k] // empty) as $v
  | if ($v | type) == "number" then $v
    elif ($v | type) == "object" then ($v.core // empty)
    else empty end
' "$ASSIGNMENTS_FILE"
```

**Win:** 1–3 forks ner till 1 per anrop. Kallas inuti varje status-varv per app.

### 5. Kollapsa `installed_release_version`

Rad 460–468 → ett `jq -s` över de tre filerna med fallback-pipeline:

```text
jq -rs 'first(.[] | (.tag // .version // .name) | select(.))' \
  "$install_dir/VERSION.json" "$install_dir/package.json" "$install_dir/engine/package.json" 2>/dev/null
```

(Filtrera bort filer som inte finns med pre-check; behåll tom-string-retur när inga finns.)

## Tekniska detaljer

- Alla ändringar är interna i `pi-control-center-api.sh`. Inga sudoers-ändringar, inga nya systemd-units, inga UI-ändringar.
- `_service_show`-cachen scope:as till en `build_status_json`-iteration (precis som `_REGISTRY_CACHE_JSON` idag) så stale data aldrig läcker mellan polls.
- Behåll alla befintliga funktionssignaturer (`service_is_active`, `get_service_pid`, `get_service_ram`) så övriga callsites (CLI-routes, watchdog, autoscaler) fungerar oförändrat — de blir bara billigare.
- `assignment_get_core` används av autoscaler/watchdog/build_status_json — kontrollera att jq-uttrycket returnerar exakt samma sträng som idag (siffra utan citationstecken / tom rad).

## Verifieringskriterier

1. `bash -n public/pi-scripts/pi-control-center-api.sh` passerar.
2. Manuell sanity: kör `build_status_json` lokalt mot en testfixture (om möjligt via Pi:n) och jämför JSON-output före/efter — ska vara byte-identisk.
3. Ingen regression i autoscaler-invarianten (live_change-gating i `auto_adjust_memory_limit`) — den koden rörs inte.
4. På Pi:n: `top -b -n 5 -d 2 -p $(pgrep -f pi-control-center-api)` visar lägre genomsnitts-CPU för API-processen efter deploy.

## Utanför scope

- Migrera `pi-control-center-api.sh` → Python (för stort grepp, separat diskussion).
- Ändra polling-intervall (UI-beteende).
- Röra autoscaler-logik eller BLE-permissions.
