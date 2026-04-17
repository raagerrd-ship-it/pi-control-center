# Pi Control Center — Installation

> **Rekommendation:** Vid problem, börja alltid från en ren Pi OS-installation.
> Det löser nästan alltid drift-relaterade fel (fel ägarskap, gamla `node_modules`,
> halvkörda builds, sudoers-permissions).

---

## Ren installation (rekommenderad)

### 1. Flasha SD-kort

Använd [Raspberry Pi Imager](https://www.raspberrypi.com/software/):

- **OS:** Raspberry Pi OS Lite (64-bit, Bookworm)
- **Användarnamn:** `pi` (rekommenderat)
- **Lösenord:** valfritt
- **WiFi:** ditt hemnätverk
- **SSH:** aktivera

### 2. Boota Pi:n och SSH in

```bash
ssh pi@<pi-ip>
```

> Hitta IP via routern eller prova `pi@raspberrypi.local`.

### 3. Kör installations-one-linern

```bash
curl -sL https://raw.githubusercontent.com/raagerrd-ship-it/pi-control-center/main/public/pi-scripts/first-boot-setup.sh | sudo bash
```

Vänta ~10 min. LED visar status:
- 🔵 Långsam blink → väntar på nätverk
- 🔵 Snabb blink → installerar
- 🔵 Fast sken → klart!

### 4. Öppna dashboarden

```
http://<pi-ip>
```

### 5. Installera tjänsterna

I dashboarden, installera (i valfri ordning):

- **Lotus Lantern Control**
- **Cast Away Web**
- **Sonos Gateway**

Klart.

---

## Reset to clean state (utan ominstallation)

Om du absolut inte vill flasha om SD-kortet kan du försöka reparera en befintlig
installation. Detta är **inte** lika tillförlitligt som en ren install:

```bash
# Fixa ägarskap (vanlig orsak till "Permission denied" under update)
sudo chown -R pi:pi /home/pi/pi-control-center

# Nuke build-artefakter
rm -rf /home/pi/pi-control-center/node_modules
rm -rf /home/pi/pi-control-center/dist

# Kör om update
cd / && bash /home/pi/pi-control-center/public/pi-scripts/update-control-center.sh
```

Om det fortfarande inte fungerar → flasha om SD-kortet och kör ren install.

---

## Felsökning

| Problem | Lösning |
|---------|---------|
| Installation fastnade | `cat /var/log/pi-control-center-setup.log` |
| Kör om installationen | `sudo rm /opt/.pi-control-center-installed && curl -sL https://raw.githubusercontent.com/raagerrd-ship-it/pi-control-center/main/public/pi-scripts/first-boot-setup.sh \| sudo bash` |
| Permission denied vid update | Se "Reset to clean state" ovan |
| LED blinkar långsamt länge | Scriptet väntar på WiFi — kontrollera nätverket |
