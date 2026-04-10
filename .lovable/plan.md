

## Plan: Snabbare installation och uppdatering av tjänster

### Problem idag

Varje tjänstinstallation kör `git clone` → `npm install` → `npm run build` direkt på Pi Zero 2. Med 512MB RAM tar detta **5-15 minuter per tjänst** och riskerar OOM-krasch. Samma sak vid uppdatering.

### Lösning: Förbyggda releases via GitHub

Istället för att bygga på Pi:n laddar dashboarden ner **färdigbyggda dist-filer** som GitHub Release-artefakter. Installationen blir: ladda ner tarball → packa upp → starta. ~30 sekunder istället för 10+ minuter.

```text
IDAG:
  git clone → npm install (5 min) → npm run build (5 min) → serve dist/
  
NYTT:
  curl release.tar.gz → tar xzf → serve dist/
```

### Steg

**1. Utöka `services.json` med release-URL-mönster**

Lägg till `releaseUrl`-fält som pekar på senaste release:

```json
{
  "key": "lotus-lantern",
  "name": "Lotus Lantern Control",
  "releaseUrl": "https://api.github.com/repos/raagerrd-ship-it/lotus-light-link/releases/latest",
  "installDir": "/opt/lotus-light",
  "service": "lotus-light",
  "repo": "https://github.com/raagerrd-ship-it/lotus-light-link.git",
  "installScript": "pi/setup-lotus.sh",
  ...
}
```

**2. Ny snabb-installationsfunktion i `pi-dashboard-api.sh`**

`do_install` får en ny snabbväg:
1. Anropa GitHub Releases API → hämta `browser_download_url` för `dist.tar.gz`
2. Om release finns: ladda ner, packa upp till `installDir`, skapa systemd-service med `serve`
3. Om release saknas: fallback till nuvarande `git clone` + `npm install` + `build`

Samma logik för `do_update` — kolla om ny release finns, ladda ner och byt ut `dist/`.

**3. Skapa systemd-service automatiskt (utan installationsskript)**

Dashboarden genererar servicefilen direkt:

```ini
[Service]
WorkingDirectory=/opt/lotus-light
ExecStart=/usr/bin/npx serve dist -l {port} -s
CPUAffinity={core}
```

Inget behov av att varje tjänst har ett eget installationsskript för rena frontend-appar.

**4. Uppdatering = byt dist-mapp**

```text
curl ny-release.tar.gz → tar xzf till /tmp → rsync till installDir/dist/ → restart service
```

Tar ~10 sekunder. Ingen npm install, ingen build.

**5. GitHub Action-mall för tjänsterepon**

Enkel workflow som bygger och publicerar `dist.tar.gz` vid varje push till main:

```yaml
- run: npm ci && npm run build
- run: tar czf dist.tar.gz dist/
- uses: softprops/action-gh-release@v2
  with:
    files: dist.tar.gz
```

### Vad behöver finnas i varje tjänste-repo

- En GitHub Actions workflow som publicerar `dist.tar.gz` som release
- Det är allt. Inget installationsskript behövs för rena frontend-appar.

### Filer som ändras

| Fil | Ändring |
|-----|---------|
| `public/services.json` | Lägg till `releaseUrl` per tjänst |
| `public/pi-scripts/pi-dashboard-api.sh` | Ny `do_install_release()`, uppdaterad `do_install()` med release-fallback, ny `do_update_release()` |
| `public/SERVICE-INTEGRATION.md` | Dokumentera release-baserad installation + GitHub Action-mall |

### Resultat

- Installation: **~30s** istället för 10-15 min
- Uppdatering: **~10s** istället för 5-10 min
- Inget behov av Node.js/npm på Pi:n (förutom `serve` som redan finns)
- Bakåtkompatibelt: om release saknas används gamla flödet

