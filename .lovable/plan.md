## Mål
Snabba upp `update-control-center.sh` genom att hoppa över onödiga steg när inget faktiskt ändrats. Idag tas `node_modules` bort och `npm install` körs varje gång — även om `package.json`/`package-lock.json` är identiska. Likadant körs `npm run build` även om koden inte ändrats sedan förra builden.

PCC själv har inte noble som dependency, men samma princip — "kolla först, installera bara vid förändring" — gäller här.

## Ändringar i `public/pi-scripts/update-control-center.sh`

### 1. Hoppa över `npm install` om dependencies är oförändrade
Före git pull: spara hash av `package.json` + `package-lock.json`.
Efter git pull: jämför hashen.

```text
[2/6] Installing dependencies...
  ↳ package.json oförändrad sedan förra installen — hoppar över npm install
```

- Ta bort `rm -rf node_modules` ovillkorligt — gör det bara om hashen ändrats eller om `node_modules` saknas.
- Spara hashen i `node_modules/.pcc-deps-hash` efter lyckad install.

### 2. Hoppa över `npm run build` om inget byggs om
Spara nuvarande git-commit + deps-hash i `dist/.pcc-build-stamp` efter build. Om commit och deps-hash är samma som senast — och `$NGINX_DIR/index.html` redan finns — hoppa över både build och deploy-kopiering.

```text
[3/6] Building...
  ↳ Källkoden oförändrad sedan förra builden — hoppar över
[4/6] Deploying to Nginx...
  ↳ Nginx redan i synk — hoppar bara scripts/services.json
```

### 3. Behåll `node_modules` mellan körningar
Ta bort den slutliga `rm -rf node_modules` i `[6/6] Cleaning up`. Den gör att nästa update alltid blir maxlångsam. Pi Zero 2 har ont om disk men `node_modules` för PCC är ~150 MB — acceptabelt vs. ~5 min installtid per update. Lägg istället `npm cache clean --force` (redan där).

  - Alternativ om diskutrymme är ett problem: behåll `rm -rf node_modules` men gör snabb install via `npm ci --prefer-offline` — kräver dock att lock-filen finns med i repot.

### 4. Force-flagga via UI
Lägg till stöd för `FORCE=1` env-variabel som kringgår alla skip-checks (för felsökning). API:t behöver inte ändras nu — kan triggas via SSH om det behövs.

## Frågor som fortfarande är öppna
- Ska vi behålla `node_modules` permanent (snabbast, ~150 MB disk), eller köra `npm ci` varje gång (säkrare, ~1 min)? Default: behåll.
- Inget API-flöde ändras — UI-knappen "Uppdatera Dashboard" beter sig som idag, bara snabbare.

## Förväntad effekt
- Update utan kodändringar: **~10–20 sek** (git fetch + nginx-sync) istället för 3–5 min.
- Update med små UI-ändringar (ingen deps-ändring): **~1–2 min** (bara build) istället för 3–5 min.
- Update med deps-ändring: oförändrad tid.
