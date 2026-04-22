
## Mål

Göra så att varje tjänst får en permanent plats för inställningar och sparfiler som inte ligger i `/opt/<app>` och därför överlever uppdateringar.

Standard:

```text
/opt/<app>                              = appens kod, får ersättas vid update
/etc/pi-control-center/apps/<app>       = appens konfiguration/inställningar
/var/lib/pi-control-center/apps/<app>   = appens sparfiler/state/data
/var/log/pi-control-center/apps/<app>   = appens loggar
```

## Plan

1. **Införa permanent data-katalog per tjänst**
   - Lägg till stöd i PCC API:t för:
     - `/var/lib/pi-control-center/apps/<app>`
   - Skapa katalogen automatiskt vid installation/start.
   - Sätt ägare till Pi-användaren.
   - Sätt säkra rättigheter:
     - config/data: `700`
     - loggar: `755`

2. **Exponera katalogerna till alla tjänster**
   - Alla systemd-servicefiler som PCC skapar ska få:
     - `PCC_CONFIG_DIR=/etc/pi-control-center/apps/<app>`
     - `PCC_DATA_DIR=/var/lib/pi-control-center/apps/<app>`
     - `PCC_LOG_DIR=/var/log/pi-control-center/apps/<app>`

3. **Tillåt skrivning trots systemd-skydd**
   - Behåll hårdningen med `ProtectSystem=strict`.
   - Lägg till:
     - `ReadWritePaths=/var/lib/pi-control-center/apps/<app>`
   - Då kan tjänsten skriva sina sparfiler där, men inte fritt i systemet.

4. **Uppdateringar ska aldrig ta bort sparfiler**
   - Uppdatering ska bara ersätta:
     - `/opt/<app>`
   - Följande ska lämnas kvar:
     - `/etc/pi-control-center/apps/<app>`
     - `/var/lib/pi-control-center/apps/<app>`
     - `/var/log/pi-control-center/apps/<app>`

5. **Avinstallation ska bevara användardata**
   - Vanlig avinstallation tar bort:
     - systemd-service
     - `/opt/<app>`
     - core assignment
   - Men sparar:
     - config
     - data/state
     - loggar
   - Det gör att man kan installera om utan att tappa inställningar.

6. **Factory reset får rensa allt**
   - Full återställning ska radera även:
     - `/etc/pi-control-center/apps`
     - `/var/lib/pi-control-center/apps`
     - `/var/log/pi-control-center/apps`
   - Det motsvarar “börja om från noll”.

7. **Visa data-sökvägen i UI**
   - Lägg till “Data” på tjänstekorten så man ser var sparfilerna ligger:
     - `Data: /var/lib/pi-control-center/apps/<app>`

8. **Uppdatera sudo-regler och installationsskript**
   - Uppdatera `install.sh` och first-boot-script så PCC får lösenordsfri sudo för att skapa och hantera:
     - `/var/lib/pi-control-center/apps`
     - `/var/lib/pi-control-center/apps/*`
   - Lägg till nödvändiga regler för `mkdir`, `chown`, `chmod` och liknande där PCC redan hanterar `/etc` och `/var/log`.

9. **Dokumentera app-standarden**
   - Appar ska använda:
     - `PCC_CONFIG_DIR` för inställningar
     - `PCC_DATA_DIR` för sparfiler/state
     - `PCC_LOG_DIR` för loggar
   - Om en app redan sparar inne i `/opt/<app>` behöver appen senare justeras separat för att använda `PCC_DATA_DIR`.

## Teknisk detalj

PCC har redan början på detta med config och loggar:

```text
/etc/pi-control-center/apps/<app>
/var/log/pi-control-center/apps/<app>
```

Det som saknas är en tydlig persistent data/state-katalog och att den skickas till alla tjänster via systemd.

Efter ändringen blir `/opt/<app>` ren programkod och kan tryggt bytas ut vid uppdatering utan att inställningar eller sparfiler försvinner.
