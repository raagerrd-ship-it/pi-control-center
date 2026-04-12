

## Plan: Skapa komplett SERVICE-INTEGRATION.md

Skriva om `public/SERVICE-INTEGRATION.md` till en utförlig, komplett integrationsguide som täcker hela livscykeln för en tjänst i Pi Control Center — från arkitekturfilosofi till GitHub Actions-workflow.

### Huvudinnehåll

1. **Filosofi** — Pi Control Center = OS, tjänster = program. Motorn är det stabila hjärtat, UI:t är en fjärrkontroll
2. **Motor/UI-separation** — varför, hur, portkonvention (UI=vald port, Motor=+50)
3. **services.json-format** — båda formaten (legacy + components) med fullständiga exempel
4. **Sandboxing & isolering** — AllowedCPUs, MemoryMax, ProtectSystem etc.
5. **Release-baserad installation** — GitHub Actions-workflows för static och node
6. **Installskript** — vad de får/inte får göra, flaggor (--port, --core)
7. **Avinstallationsskript** — mall för legacy och component-baserade
8. **Uppdateringsflöde** — hur dashboard hanterar uppdateringar
9. **Checklista** — krav för att en tjänst ska vara kompatibel

### Fil som ändras

| Fil | Ändring |
|-----|---------|
| `public/SERVICE-INTEGRATION.md` | Omskriven från grunden — utförlig guide (~400 rader) |

### Tekniska detaljer

- Portkonvention: om användaren väljer port 3002 → UI lyssnar på 3002, Motor på 3052
- Miljövariabler som sätts automatiskt: `PORT`, `ENGINE_PORT`, `UI_PORT`
- Systemd-unit genereras av `pi-dashboard-api.sh`, inte av tjänsten själv
- Tjänster kör som user-services via `systemctl --user`
- Motorn har `Restart=always` (alwaysOn), UI har `Restart=on-failure`

