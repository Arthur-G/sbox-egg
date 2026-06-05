# sbox-egg — image s&box (Debian + Wine) pour OuiHeberg

Image Docker autonome pour héberger des serveurs **s&box** (successeur de Garry's Mod par
Facepunch, moteur Source 2, binaire serveur Windows exécuté sous **Wine** sur Debian) via
**Pterodactyl Panel**.

Elle remplace l'image tierce `ghcr.io/gameforgegg/sbox-egg` pour deux raisons :

1. **Auto-update SteamCMD fonctionnel** — l'image d'origine cherche un binaire `windows/steamcmd`
   inexistant ; le moteur restait périmé et la compilation des gamemodes échouait. Ici SteamCMD
   provient du **tarball Valve officiel** (`/opt/steamcmd`) → l'auto-update runtime marche.
2. **Aucune télémétrie** — l'image d'origine envoyait toutes les 10 s (UUID serveur, IP, et la
   liste des joueurs SteamID64 + pseudo) vers un tiers. Ce bloc est **supprimé**.

> Contexte complet, diagnostic et décisions : voir [`CONTEXT.md`](CONTEXT.md).

**Image publiée :** `ghcr.io/arthur-g/sbox-egg:latest`

## Contenu du repo

| Fichier | Rôle |
|---|---|
| `Dockerfile` | Image `debian:bookworm-slim` + winehq-stable + SteamCMD (tarball Valve) + .NET Windows x64 |
| `start-sbox` | Launcher réel : seed, init wineprefix au 1er boot, update SteamCMD, lancement sous wine |
| `entrypoint.sh` | Wrapper Pterodactyl (expand des `{{VARS}}` du Startup Command) |
| `egg-s-box-ouiheberg.json` | Egg à importer dans le panel Pterodactyl |
| `CONTEXT.md` | Document de passation (diagnostic, décisions, TODO) |
| `.github/workflows/build.yml` | CI : build + push vers GHCR sur push `main` |

## Build & publication

Le push sur `main` déclenche le workflow GitHub Actions qui build et pousse
`ghcr.io/arthur-g/sbox-egg:latest` (via le `GITHUB_TOKEN` natif, aucun PAT).

Build local (optionnel) :

```bash
docker build -t ghcr.io/arthur-g/sbox-egg:latest .
```

Puis importer `egg-s-box-ouiheberg.json` dans Pterodactyl et faire un **Reinstall** sur le
serveur (nouvelle image + retéléchargement d'un moteur frais au premier boot).

## Variables de l'egg

| Variable | Défaut | Visible / Éditable | Description |
|---|---|---|---|
| `GAME` | `facepunch.sandbox` | oui / oui | Identifiant du package de jeu (`org.package`). |
| `SERVER_NAME` | `OuiHeberg Sandbox Server` | oui / oui | Nom public affiché dans le browser s&box. |
| `MAP` | *(vide)* | oui / oui | Map/package chargé après `+game`. |
| `SBOX_PROJECT` | *(vide)* | oui / oui | `.sbproj` local sous `/home/container/projects/`. |
| `SBOX_EXTRA_ARGS` | *(vide)* | oui / oui | Arguments supplémentaires passés au serveur. |
| `MAX_PLAYERS` | *(vide)* | oui / oui | Nombre max de joueurs (1–256). |
| `SBOX_AUTO_UPDATE` | `1` | oui / oui | Update SteamCMD à chaque boot (1/0). 1er boot télécharge toujours. |
| `QUERY_PORT` | *(vide)* | oui / oui | Port de query pour Direct Connect (expérimental). |
| `ENABLE_DIRECT_CONNECT` | `0` | oui / oui | Connexion directe IP+port au lieu du relais Steam (expérimental). |
| `TOKEN` | *(vide)* | oui / oui | Game Server Token Steam (`+net_game_server_token`). |
| `SBOX_BRANCH` | *(vide)* | oui / oui | Branche beta Steam pour les updates. |
| `SBOX_STEAMCMD_TIMEOUT` | `600` | non / non | Timeout (s) par appel SteamCMD (0 = illimité). |
| `RUNTIME_MODE` | `wine` | non / non | Backend : `wine` (recommandé), `proton`, `linux`. |
| `STEAMCMD_EXTRA_ARGS` | *(vide)* | non / non | Arguments supplémentaires pour SteamCMD. |

## À valider avant prod

Voir la section 6 de `CONTEXT.md`. En résumé :

1. **`WIN_DOTNET_VERSION`** (`10.0.0` dans le `Dockerfile`) est un **placeholder** — confirmer
   la version .NET ciblée par s&box et la pin.
2. Wine `stable` vs `staging` selon les besoins du moteur.
3. UID de l'utilisateur `container` selon la version de Wings.
4. Réseau de build : winehq.org, builds.dotnet.microsoft.com, steamcdn-a.akamaihd.net joignables.
5. Premier boot lent (init wineprefix + download du moteur) — normal, une seule fois.
