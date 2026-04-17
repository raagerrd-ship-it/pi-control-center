

## Bedömning: Ja, en ren ominstallation är rätt väg

De senaste felen (root-ägt `node_modules`, trasig cwd, sudoers mode 750/755, saknade pi-scripts-symlinks) är alla **ackumulerad drift** från manuella SSH-fix under utvecklingen. En ren Pi OS + `first-boot-setup.sh` ger:

- Korrekt ägarskap från start (`pi:pi` överallt)
- Korrekta sudoers-permissions (750)
- `fix-sudo.sh` körs proaktivt innan första `apt`
- Symlinks för Lotus/Cast Away/Sonos läggs på rätt plats direkt
- Inga lager av gamla `node_modules`, npm-cacher, eller halvkörda builds

**Det löser troligen alla nuvarande symptom.** Det enda som kan kvarstå är buggar i själva `first-boot-setup.sh` — men de upptäcks då i en ren miljö istället för att maskeras av drift.

## Vad jag föreslår att vi rensar i koden

Eftersom en ren install gör vissa "self-healing" guards onödiga, kan vi förenkla:

### 1. `update-control-center.sh` — ta bort drift-guards
- **Ta bort cwd-guarden** (`if ! pwd ...; then cd /`) — behövs bara om man kör scriptet från en raderad mapp, vilket inte händer i ren install
- **Ta bort "PREV_HASH" / `.package-hash`-logiken** — onödig komplexitet, gör alltid ren `npm install` om `package.json` ändrats via enkel `git diff`-koll, eller ännu enklare: alltid `npm ci` om lockfilen ändrats
- **Ta bort low-disk node_modules-cleanup** — Pi Zero 2 har alltid ont om disk, alltid städa

### 2. `first-boot-setup.sh` — granska om något är defensivt utan anledning
- Behåll `fix-sudo.sh`-anropet (det är legitim OS-hygien)
- Behåll LED-feedback
- Behåll swap-setup
- Granska om vissa fallbacks (t.ex. `polkitd` || `policykit-1`) faktiskt behövs på senaste Pi OS — om inte, förenkla

### 3. Dokumentera "ren install"-flödet
Kort sektion i `README.md` eller ny `INSTALL.md`:
1. Flasha Pi OS Lite (Bookworm) med Pi Imager — sätt user `pi`, WiFi, SSH
2. SSH in och kör one-liner med `first-boot-setup.sh`
3. Vänta ~10 min, öppna `http://<pi-ip>`
4. Installera Lotus / Cast Away / Sonos via dashboarden

## Vad jag INTE föreslår att vi rör

- `fix-sudo.sh` — den är ny och korrekt, behövs både i ren install och som självläkning för befintliga installationer
- `pi-control-center-api.sh` — fungerar som det ska
- `services.json` — pekar rätt
- Symlink-skapandet i `first-boot-setup.sh` (`/var/www/pi-dashboard/pi-scripts`) — krävs för Lotus-wrappern

## Plan att utföra (när du godkänner)

1. **Förenkla `update-control-center.sh`**: ta bort cwd-guard, hash-cache, disk-conditional cleanup → kortare, deterministisk
2. **Lägg till `INSTALL.md`** i repo-roten med ren-install-flödet och rekommendation att alltid börja från ren Pi OS vid problem
3. **Lägg till en kort "Reset to clean state"-sektion** med kommandona för att nuke `node_modules` + `chown -R pi:pi` om någon ändå vill reparera utan ominstallation

Sedan: du flashar SD-kortet, kör one-linern, och vi verifierar att allt funkar i ren miljö.

