# CONTEXT — Image s&box dédiée (Debian + Wine) pour OuiHeberg

> Document de passation pour Claude Code. Il contient **tout le contexte** (diagnostic,
> décisions, TODO) **et le contenu complet des 4 fichiers** du projet. L'agent qui
> reprend n'a pas accès à la conversation d'origine : ce fichier fait foi.

---

## 1. But du projet

Construire une **image Docker autonome** pour héberger des serveurs **s&box** (le successeur
de Garry's Mod par Facepunch, moteur Source 2, binaire serveur Windows tournant sous **Wine**
sur Debian) via **Pterodactyl Panel**.

Cette image **remplace** l'image tierce `ghcr.io/gameforgegg/sbox-egg:latest`, pour deux
raisons développées plus bas : son auto-update SteamCMD est cassé, et elle embarque de la
**télémétrie codée en dur** vers un tiers.

Cible de publication : `ghcr.io/ouiheberg/sbox-egg:latest` (à adapter).

---

## 2. Contexte / problème d'origine

Serveur concerné : **Lithera RP** (`+game litherastudio.litherarp`, map `thieves.rpdowntown3t`),
hébergé sous Pterodactyl avec l'egg/image `gameforgegg`.

Symptôme : le serveur démarre mais la **compilation du gamemode échoue** :

```
02:41:54 Compiler Broken Reference: package.base (the compiler failed)
02:41:54 Error | The type name 'PackageFlair' does not exist in the type 'Package'
02:41:54 Error | 'Package' does not contain a definition for 'Flair' ...
02:41:54 Compile of 'litherastudio.litherarp' Failed:
```

Précédé systématiquement de :

```
steamcmd.sh[20]: Couldn't find steamcmd at /home/container/.local/share/Steam/steamcmd/windows/steamcmd, exiting
WARN: SteamCMD runtime probe failed; cannot run auto-update
WARN: continuing startup with existing server files because .../sbox-server.exe already exists
```

### Mécanique du bug (important)

Sur s&box, les deux moitiés se mettent à jour par des canaux **différents** :

- le **moteur** (`sbox-server.exe`) se met à jour via **SteamCMD** (app Steam **1892930**) ;
- les **packages de jeu** (le gamemode `litherarp` + sa dépendance `base`) se mettent à jour
  **séparément depuis le cloud sbox.game**, automatiquement au redémarrage.

Au boot : les packages se sont auto-mis à jour (donc ils réclament l'API récente
`Package.Flair` / `PackageFlair`), mais le moteur **n'a pas** été mis à jour parce que la
sonde SteamCMD a échoué → fallback sur un `sbox-server.exe` périmé → l'API ne correspond plus
→ échec de compilation. (Note : une build stable du moteur est sortie le 27 mai 2026 ; un
binaire périmé est tout à fait plausible.)

---

## 3. Diagnostic racine

### 3.1 — SteamCMD de l'image gameforge est cassé

Dans leur `entrypoint.sh`, `resolve_steamcmd_binary` ne cherche le binaire qu'à
`/usr/bin/steamcmd` et `/usr/games/steamcmd` (donc **dans l'image**, pas dans le volume).
C'est le **package Debian `steamcmd`**, dont le wrapper bootstrap tente de localiser un
exécutable sous `.../steamcmd/windows/steamcmd` — chemin qui n'existe pas.

Point clé : **SteamCMD tourne toujours en binaire Linux**. L'option
`+@sSteamCmdForcePlatformType windows` ne change que **les fichiers téléchargés** (la build
Windows du serveur), pas l'exécutable lancé. Un lookup vers `windows/steamcmd` signifie donc
que le bootstrap SteamCMD de l'image est mal configuré (figé sur une plateforme windows).
C'est interne à l'image → **non corrigeable depuis le JSON de l'egg**, seulement contournable.

**Correctif retenu** : ne plus utiliser le package Debian. Décompresser le **tarball Valve
officiel** (`steamcmd_linux.tar.gz`) dans `/opt/steamcmd` et l'appeler directement. Le
`steamcmd.sh` de Valve lance toujours `linux32/steamcmd` et accepte `force platform windows`
pour le seul téléchargement → l'auto-update runtime fonctionne réellement.

### 3.2 — Télémétrie codée en dur (exfiltration de données)

Toujours dans leur `entrypoint.sh`, un bloc « egg-metrics » :

```
EGG_METRICS_URL="http://185.242.225.133:2458"
EGG_METRICS_ENABLED="1"
EGG_METRICS_INTERVAL="10"
```

Toutes les 10 s, POST vers cette IP : UUID du serveur, IP, CPU/RAM/réseau, **et la liste des
joueurs (SteamID64 + pseudo)**. Valeurs **assignées en dur** (pas en `${VAR:-...}`), donc elles
**écrasent l'environnement** : impossible de désactiver via les variables de l'egg.

Pour un hébergeur (OuiHeberg, SARL française), cela exfiltre les données des clients **et de
leurs joueurs** vers un tiers non déclaré. SteamID64 + pseudo + IP = données personnelles →
**enjeu RGPD** (ceci n'est pas un avis juridique ; à faire valider).

**Correctif retenu** : tout le bloc egg-metrics est **supprimé** du `start-sbox`. Plus aucun
appel sortant vers un tiers.

---

## 4. Décisions d'architecture

- **Image Debian autonome** (`debian:bookworm-slim`), buildée et poussée par OuiHeberg.
- **Wine** : `winehq-stable` (bascule possible vers `winehq-staging` si besoin).
- **SteamCMD** : tarball Valve dans `/opt/steamcmd` (pas le package Debian).
- **.NET (Windows x64)** baked dans `/opt/sbox-dotnet`, exposé à Wine en `Z:\opt\sbox-dotnet`
  via `DOTNET_ROOT` (comportement repris de l'image gameforge, qui faisait pareil).
- **Télémétrie** : retirée.
- **Egg** : `SBOX_AUTO_UPDATE=1` par défaut (l'auto-update runtime marche désormais) ; le
  script d'installation se contente de créer les dossiers, le moteur est téléchargé au premier
  boot par l'entrypoint.
- **Wineprefix** : initialisé au **premier boot** (`wineboot -i`), car Pterodactyl monte le
  volume par-dessus `/home/container` et écrase tout ce qui serait baked à cet emplacement.

---

## 5. Arborescence attendue du repo

```
sbox-egg/
├── CONTEXT.md                  <- ce fichier
├── Dockerfile
├── start-sbox                  <- launcher s&box (entrypoint réel, sur PATH dans l'image)
├── entrypoint.sh               <- wrapper Pterodactyl (CMD de l'image)
└── egg-s-box-ouiheberg.json    <- egg à importer dans le panel
```

---

## 6. TODO à valider AU BUILD (points de risque)

1. **Version .NET** — `WIN_DOTNET_VERSION=10.0.0` dans le Dockerfile est un **placeholder**.
   La doc officielle (https://sbox.game/dev/doc/networking/dedicated-servers/) dit seulement
   « le serveur tourne sur .NET, il faut le .NET Runtime installé » — **sans préciser la
   version**. À confirmer : lancer le serveur une fois, lire l'erreur wine de runtime manquant
   le cas échéant, et pin la version exacte (et vérifier si le runtime de base suffit ou s'il
   faut le runtime desktop/ASP.NET). Source possible : changelogs Facepunch / `Facepunch/sbox-public`.
2. **Version Wine** — `winehq-stable`. Si s&box réclame des fonctions plus récentes, passer à
   `winehq-staging`.
3. **UID de l'utilisateur `container`** — le `useradd` suit la convention Pterodactyl, mais
   selon la version de Wings l'UID attendu peut différer. En cas de souci de permissions sur
   le volume, ajuster l'UID/GID.
4. **Réseau de build** — winehq.org, builds.dotnet.microsoft.com et steamcdn-a.akamaihd.net
   doivent être joignables depuis la machine de build.
5. **Premier boot lent** — init du wineprefix + download du moteur : normal, une seule fois.

---

## 7. Build & publication

```bash
docker build -t ghcr.io/ouiheberg/sbox-egg:latest .
echo "$GHCR_TOKEN" | docker login ghcr.io -u ouiheberg --password-stdin   # token: scope write:packages
docker push ghcr.io/ouiheberg/sbox-egg:latest
```

Puis importer `egg-s-box-ouiheberg.json` dans Pterodactyl et faire un **Reinstall** sur le
serveur Lithera (nouvelle image + retéléchargement d'un moteur frais au premier boot).
Rendre le package GHCR **public** si les nodes doivent le tirer sans auth (sinon configurer
les credentials de pull sur Wings).

**Ne jamais committer de secret** (token, etc.) dans le repo. Les 4 fichiers ci-dessous sont
clean (aucun secret en dur — contrairement à l'egg d'origine).

---

## 8. Tâches suggérées pour Claude Code

- [ ] Initialiser le repo Git, committer les 4 fichiers + ce CONTEXT.md.
- [ ] Ajouter un `.gitignore` (au minimum : artefacts locaux, `*.log`, `.env`).
- [ ] Ajouter un `README.md` (résumé d'usage + le tableau des variables de l'egg).
- [ ] Ajouter `.github/workflows/build.yml` : build + push vers GHCR sur push `main`
      (utiliser le `GITHUB_TOKEN` natif, scope `packages: write` ; **pas** de PAT en dur).
- [ ] Vérifier que le `Dockerfile` build (`docker build`), corriger si winehq/.NET cassent.
- [ ] (Optionnel) `docker-compose.yml` de test hors Pterodactyl pour valider l'image isolée.
- [ ] Valider les 5 points de la section 6.

---

# 9. Contenu complet des 4 fichiers

> Source de vérité. Si un fichier du repo diverge de ce qui suit, c'est le fichier du repo
> qui prime (il a pu être corrigé depuis) — mais en cas de doute, ceci est l'état initial validé.


## 9.1 `Dockerfile`

```dockerfile
# =============================================================================
# OuiHeberg — s&box dedicated server runtime (Debian + Wine, self-contained)
# Replaces ghcr.io/gameforgegg/sbox-egg. No third-party telemetry.
#
# Build:   docker build -t ghcr.io/ouiheberg/sbox-egg:latest .
# Push:    docker push ghcr.io/ouiheberg/sbox-egg:latest
#
# VERIFY BEFORE PROD:
#   * WIN_DOTNET_VERSION must match the .NET build s&box targets. 10.0.0 is a
#     placeholder. If the server fails with a missing-runtime error under wine,
#     check sbox-server's required version and pin it here.
#   * Wine version: winehq-stable is used. If sbox needs features only in a
#     newer build, switch to winehq-staging.
# =============================================================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    WINEDEBUG=-all \
    WINEPREFIX=/home/container/.wine \
    STEAMCMD_DIR=/opt/steamcmd \
    SBOX_DOTNET_DIR=/opt/sbox-dotnet

# .NET Windows runtime version to bake (see note above).
ARG WIN_DOTNET_VERSION=10.0.0

# --- base deps + i386 (wine + steamcmd both need 32-bit) ---------------------
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg xz-utils tar unzip \
        procps tini locales tzdata \
        lib32gcc-s1 libgcc-s1 libfreetype6 libfreetype6:i386 \
 && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*

# --- WineHQ stable ----------------------------------------------------------
RUN mkdir -p /etc/apt/keyrings \
 && wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && wget -qNP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
 && apt-get update \
 && apt-get install -y --install-recommends winehq-stable \
 && rm -rf /var/lib/apt/lists/*

# --- SteamCMD (Valve tarball — NOT the broken Debian package bootstrap) ------
RUN mkdir -p "${STEAMCMD_DIR}" \
 && curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
      | tar zxf - -C "${STEAMCMD_DIR}" \
 && chmod +x "${STEAMCMD_DIR}/steamcmd.sh"

# --- .NET (Windows x64) for wine --------------------------------------------
# Exposed to wine as Z:\opt\sbox-dotnet via DOTNET_ROOT in start-sbox.
RUN curl -sSL -o /tmp/dotnet.zip \
      "https://builds.dotnet.microsoft.com/dotnet/Runtime/${WIN_DOTNET_VERSION}/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64.zip" \
 && mkdir -p "${SBOX_DOTNET_DIR}" \
 && unzip -q /tmp/dotnet.zip -d "${SBOX_DOTNET_DIR}" \
 && rm -f /tmp/dotnet.zip

# --- Pterodactyl container user ---------------------------------------------
RUN useradd -m -d /home/container -s /bin/bash container
ENV USER=container HOME=/home/container

# --- scripts ----------------------------------------------------------------
COPY start-sbox /usr/local/bin/start-sbox
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/start-sbox /entrypoint.sh

USER container
WORKDIR /home/container

STOPSIGNAL SIGINT
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/entrypoint.sh"]

```

## 9.2 `start-sbox`

```bash
#!/usr/bin/env bash
# =============================================================================
# start-sbox  —  s&box dedicated server launcher (OuiHeberg image)
# Derived from GameForgeGG/sbox-egg, with two changes:
#   * SteamCMD resolved from /opt/steamcmd (baked Valve tarball, not the broken
#     Debian package bootstrap) -> runtime auto-update actually works.
#   * All "egg-metrics" telemetry removed (no phone-home to a third party).
# =============================================================================
set -euo pipefail

CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
export WINEPREFIX
export WINEDEBUG="${WINEDEBUG:--all}"

# Where the Valve SteamCMD tarball was unpacked in the image.
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"

# s&box specifics
SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
SBOX_STEAMCMD_TIMEOUT="${SBOX_STEAMCMD_TIMEOUT:-600}"
STEAMCMD_EXTRA_ARGS="${STEAMCMD_EXTRA_ARGS:-}"

# Server config
GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${SERVER_NAME:-}"
QUERY_PORT="${QUERY_PORT:-}"
MAX_PLAYERS="${MAX_PLAYERS:-}"
ENABLE_DIRECT_CONNECT="${ENABLE_DIRECT_CONNECT:-0}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_PROJECTS_DIR="${SBOX_PROJECTS_DIR:-${CONTAINER_HOME}/projects}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"
RUNTIME_MODE="${RUNTIME_MODE:-wine}"

# .NET (Windows build) shipped in the image at /opt/sbox-dotnet (drive Z: in wine)
SBOX_DOTNET_DIR="${SBOX_DOTNET_DIR:-/opt/sbox-dotnet}"

LOG_DIR="${CONTAINER_HOME}/logs"
UPDATE_LOG="${LOG_DIR}/sbox-update.log"
mkdir -p "${LOG_DIR}"

log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# =============================================================================
# RUNTIME SEEDING / WINE PREFIX
# =============================================================================
seed_runtime_files() {
    mkdir -p "${WINEPREFIX}" "${SBOX_INSTALL_DIR}"
}

ensure_wineprefix() {
    # Pterodactyl mounts the volume over /home/container, so the prefix can't be
    # baked into the image — initialise it on first boot if it's empty.
    if [ ! -f "${WINEPREFIX}/system.reg" ]; then
        log_info "initialising wine prefix at ${WINEPREFIX} (first boot, this can take a moment)"
        WINEDLLOVERRIDES="mscoree=d;mshtml=d" wineboot -i >/dev/null 2>&1 || \
            log_warn "wineboot returned non-zero; continuing anyway"
        wineserver -w 2>/dev/null || true
    fi
}

# =============================================================================
# PATH HELPERS (local .sbproj support — unchanged from upstream)
# =============================================================================
canonicalize_existing_path() {
    local input_path="$1" input_dir input_base
    if [ -z "${input_path}" ] || [ ! -e "${input_path}" ]; then return 1; fi
    input_dir="$(dirname "${input_path}")"
    input_base="$(basename "${input_path}")"
    ( cd "${input_dir}" 2>/dev/null || exit 1; printf '%s/%s' "$(pwd -P)" "${input_base}" )
}

path_is_within_root() {
    local candidate_path="$1" root_path="$2"
    case "${candidate_path}" in
        "${root_path}"|"${root_path}"/*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_project_target() {
    local projects_root candidate resolved_candidate project_target=""
    if [ -z "${SBOX_PROJECT}" ]; then printf '%s' ""; return 0; fi
    projects_root="$(canonicalize_existing_path "${SBOX_PROJECTS_DIR}" || true)"
    if [ -z "${projects_root}" ]; then printf '%s' ""; return 0; fi
    if [[ "${SBOX_PROJECT}" = /* ]]; then candidate="${SBOX_PROJECT}"; else candidate="${SBOX_PROJECTS_DIR}/${SBOX_PROJECT}"; fi
    if [ -f "${candidate}" ]; then
        resolved_candidate="$(canonicalize_existing_path "${candidate}" || true)"
        if [ -n "${resolved_candidate}" ] && [[ "${resolved_candidate}" = *.sbproj ]] && path_is_within_root "${resolved_candidate}" "${projects_root}"; then
            project_target="${resolved_candidate}"
        fi
    fi
    if [ -z "${project_target}" ] && [[ "${candidate}" != *.sbproj ]] && [ -f "${candidate}.sbproj" ]; then
        resolved_candidate="$(canonicalize_existing_path "${candidate}.sbproj" || true)"
        if [ -n "${resolved_candidate}" ] && path_is_within_root "${resolved_candidate}" "${projects_root}"; then
            project_target="${resolved_candidate}"
        fi
    fi
    printf '%s' "${project_target}"
}

ensure_project_libraries_dir() {
    local project_target="$1" project_path projects_root project_dir libraries_dir
    [ -z "${project_target}" ] && return 0
    if [[ "${project_target}" = /* ]]; then project_path="${project_target}"; else project_path="${SBOX_PROJECTS_DIR}/${project_target}"; fi
    [ ! -f "${project_path}" ] && return 1
    projects_root="$(canonicalize_existing_path "${SBOX_PROJECTS_DIR}" || true)"
    project_path="$(canonicalize_existing_path "${project_path}" || true)"
    { [ -z "${projects_root}" ] || [ -z "${project_path}" ]; } && return 1
    { [[ "${project_path}" != *.sbproj ]] || ! path_is_within_root "${project_path}" "${projects_root}"; } && return 1
    project_dir="$(dirname "${project_path}")"
    path_is_within_root "${project_dir}" "${projects_root}" || return 1
    libraries_dir="${project_dir}/Libraries"
    [ ! -d "${libraries_dir}" ] && { mkdir -p "${libraries_dir}"; log_info "created local project folder ${libraries_dir}"; }
}

# =============================================================================
# STEAMCMD
# =============================================================================
resolve_steamcmd_binary() {
    local candidate
    for candidate in \
        "${STEAMCMD_DIR}/steamcmd.sh" \
        "/opt/steamcmd/steamcmd.sh" \
        "/usr/games/steamcmd" \
        "/usr/bin/steamcmd"
    do
        if [ -f "${candidate}" ]; then printf '%s' "${candidate}"; return 0; fi
    done
    return 1
}

run_steamcmd_with_timeout() {
    local timeout_seconds="$1"; shift
    local -a args=("$@")
    local steamcmd_bin
    steamcmd_bin="$(resolve_steamcmd_binary || true)"
    if [ -z "${steamcmd_bin}" ]; then
        log_warn "SteamCMD binary not found (expected ${STEAMCMD_DIR}/steamcmd.sh)"
        return 1
    fi
    [[ "${timeout_seconds}" == *.* ]] && timeout_seconds="${timeout_seconds%%.*}"
    [ -z "${timeout_seconds}" ] && timeout_seconds=0

    # The Valve tarball steamcmd.sh always runs the linux32 client; the forced
    # platform type only affects which *content* is downloaded — no windows/
    # binary lookup, so the upstream bootstrap bug does not apply here.
    if [ "${timeout_seconds}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        HOME="${CONTAINER_HOME}" timeout "${timeout_seconds}" bash "${steamcmd_bin}" "${args[@]}"
        return $?
    fi
    HOME="${CONTAINER_HOME}" bash "${steamcmd_bin}" "${args[@]}"
}

# =============================================================================
# UPDATE
# =============================================================================
update_sbox() {
    local -a steam_args steam_args_retry probe_args
    local force_platform="windows"
    local steamcmd_status=0

    : > "${UPDATE_LOG}"

    probe_args=( +@ShutdownOnFailedCommand 1 +@NoPromptForPassword 1 +quit )

    steam_args=(
        +@ShutdownOnFailedCommand 1
        +@NoPromptForPassword 1
        +@sSteamCmdForcePlatformType "${force_platform}"
    )
    if [ -n "${STEAMCMD_EXTRA_ARGS}" ]; then
        read -ra _extra_args <<< "${STEAMCMD_EXTRA_ARGS}"
        steam_args+=( "${_extra_args[@]}" )
    fi
    steam_args+=( +force_install_dir "${SBOX_INSTALL_DIR}" +login anonymous +app_update "${SBOX_APP_ID}" )
    [ -n "${SBOX_BRANCH}" ] && steam_args+=( -beta "${SBOX_BRANCH}" )

    steam_args_retry=("${steam_args[@]}")
    steam_args+=( validate +quit )
    steam_args_retry+=( +quit )

    set +e
    run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${probe_args[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
    steamcmd_status=${PIPESTATUS[0]}
    set -e
    if [ "${steamcmd_status}" -ne 0 ]; then
        log_warn "SteamCMD runtime probe failed; cannot run auto-update"
        [ "${steamcmd_status}" -eq 124 ] && log_warn "probe timed out after ${SBOX_STEAMCMD_TIMEOUT}s"
        log_warn "see ${UPDATE_LOG} for details"
        if [ ! -f "${SBOX_SERVER_EXE}" ]; then
            log_error "${SBOX_SERVER_EXE} was not found and SteamCMD is unavailable"
            return 1
        fi
        log_warn "continuing with existing server files (${SBOX_SERVER_EXE} exists)"
        return 0
    fi

    log_info "running SteamCMD app_update ${SBOX_APP_ID} (platform=${force_platform}${SBOX_BRANCH:+, branch=${SBOX_BRANCH}})"
    set +e
    run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${steam_args[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
    steamcmd_status=${PIPESTATUS[0]}
    set -e
    if [ "${steamcmd_status}" -ne 0 ]; then
        if grep -q "Missing configuration" "${UPDATE_LOG}"; then
            log_warn "missing configuration reported; retrying once without validate"
            set +e
            run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${steam_args_retry[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
            steamcmd_status=${PIPESTATUS[0]}
            set -e
        fi
        if [ "${steamcmd_status}" -eq 0 ]; then log_info "SteamCMD retry succeeded"; return 0; fi
        log_warn "SteamCMD update failed (status ${steamcmd_status})"
        [ "${steamcmd_status}" -eq 124 ] && log_warn "update timed out after ${SBOX_STEAMCMD_TIMEOUT}s"
        if [ -f "${SBOX_SERVER_EXE}" ]; then
            log_warn "continuing with existing server files (${SBOX_SERVER_EXE} exists)"
            return 0
        fi
        return 1
    fi
}

# =============================================================================
# LAUNCH
# =============================================================================
run_sbox() {
    local -a cli_args=("$@")
    local -a args=() extra=() launch_env=() redacted_args=()
    local project_target="" resolved_server_name="${SERVER_NAME}"
    local cli_has_game_flag=0 cli_arg="" server_status=0 i arg

    if [ ! -f "${SBOX_SERVER_EXE}" ]; then
        log_error "${SBOX_SERVER_EXE} not found. Cannot start. (Delete /home/container/sbox and restart to re-download.)"
        exit 1
    fi

    project_target="$(resolve_project_target)"

    for cli_arg in "${cli_args[@]}"; do
        [ "${cli_arg}" = "+game" ] && { cli_has_game_flag=1; break; }
    done

    if [ -n "${project_target}" ]; then
        ensure_project_libraries_dir "${project_target}"
        args+=( +game "${project_target}" )
        [ -n "${MAP}" ] && args+=( "${MAP}" )
    elif [ -n "${GAME}" ]; then
        args+=( +game "${GAME}" )
        [ -n "${MAP}" ] && args+=( "${MAP}" )
    elif [ "${cli_has_game_flag}" = "1" ]; then
        :
    else
        log_error "missing startup target; set SBOX_PROJECT or GAME (+ optional MAP)"
        exit 1
    fi

    [ -n "${TOKEN}" ] && args+=( +net_game_server_token "${TOKEN}" )
    if [ -n "${MAX_PLAYERS}" ] && [ "${MAX_PLAYERS}" -gt 0 ] 2>/dev/null; then
        args+=( +maxplayers "${MAX_PLAYERS}" )
    fi
    [ "${ENABLE_DIRECT_CONNECT}" = "1" ] && args+=( +net_hide_address 0 +port "${SERVER_PORT:-27015}" )
    [ -n "${QUERY_PORT:-}" ] && args+=( +net_query_port "${QUERY_PORT}" )
    if [ -n "${SBOX_EXTRA_ARGS}" ]; then read -ra extra <<< "${SBOX_EXTRA_ARGS}"; args+=( "${extra[@]}" ); fi
    [ "${#cli_args[@]}" -gt 0 ] && args+=( "${cli_args[@]}" )
    [ -n "${resolved_server_name}" ] && args+=( +hostname "${resolved_server_name}" )

    launch_env=(
        DOTNET_EnableWriteXorExecute=0
        DOTNET_TieredCompilation=0
        DOTNET_ReadyToRun=0
        DOTNET_ZapDisable=1
        DOTNET_ROOT_X64=Z:${SBOX_DOTNET_DIR//\//\\}
        DOTNET_ROOT=Z:${SBOX_DOTNET_DIR//\//\\}
    )

    # Redact token / quote hostname for the log line.
    i=0
    while [ $i -lt ${#args[@]} ]; do
        arg="${args[$i]}"
        if [[ "$arg" == "+net_game_server_token" ]]; then
            redacted_args+=( "+net_game_server_token" "[REDACTED]" ); i=$((i+2)); continue
        fi
        if [[ "$arg" == "+hostname" && $((i+1)) -lt ${#args[@]} ]]; then
            redacted_args+=( "+hostname" "\"${args[$((i+1))]}\"" ); i=$((i+2)); continue
        fi
        redacted_args+=( "$arg" ); i=$((i+1))
    done

    if [ "${ENABLE_DIRECT_CONNECT}" = "1" ]; then
        log_info "Starting s&box in direct-connect mode (port=${SERVER_PORT:-27015}, query_port=${QUERY_PORT:-unset})"
    else
        log_info "Starting s&box in Steam relay mode"
    fi
    log_info "Command: ${RUNTIME_MODE} \"${SBOX_SERVER_EXE}\" ${redacted_args[*]}"

    cd "${SBOX_INSTALL_DIR}"

    if [ "${RUNTIME_MODE}" = "proton" ]; then
        if [ -x "/home/container/.local/share/Proton/proton" ]; then
            launch_env+=( STEAM_COMPAT_DATA_PATH="${WINEPREFIX}" )
            exec "/home/container/.local/share/Proton/proton" run "${SBOX_SERVER_EXE}" "${args[@]}"
        fi
        log_error "Proton selected but not found"; exit 1
    elif [ "${RUNTIME_MODE}" = "linux" ]; then
        log_error "Linux native runtime not supported; use wine"; exit 1
    else
        set +e
        env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}"
        server_status=$?
        set -e
    fi

    if [ "${server_status}" -ne 0 ] && [ "${server_status}" -ne 130 ] && [ "${server_status}" -ne 143 ]; then
        log_error "sbox-server exited with status ${server_status}"
    fi
    exit "${server_status}"
}

# =============================================================================
# MAIN
# =============================================================================
[ "${1:-}" = "start-sbox" ] && shift

seed_runtime_files

if [ "${1:-}" = "" ] || [[ "${1}" = +* ]]; then
    ensure_wineprefix
    if [ "${SBOX_AUTO_UPDATE}" = "1" ] || [ ! -f "${SBOX_SERVER_EXE}" ]; then
        log_info "updating s&box server files on boot..."
        update_sbox
    fi
    run_sbox "$@"
fi

exec "$@"

```

## 9.3 `entrypoint.sh`

```bash
#!/bin/bash
# Standard Pterodactyl container entrypoint wrapper.
# It cd's into the server dir, expands {{VARS}} in the panel Startup Command,
# and execs it. The egg's Startup Command is "start-sbox", which resolves to
# /usr/local/bin/start-sbox (the real launcher).
cd /home/container || exit 1

# Print a small banner (optional, handy in the panel console).
echo "OuiHeberg s&box runtime | $(wine --version 2>/dev/null || echo 'wine: n/a')"

# Convert {{VAR}} placeholders from the panel into ${VAR}, then expand.
MODIFIED_STARTUP=$(echo -e "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"

# shellcheck disable=SC2086
eval ${MODIFIED_STARTUP}

```

## 9.4 `egg-s-box-ouiheberg.json`

```json
{
    "_comment": "OuiHeberg s&box egg — self-contained Debian/Wine image, no third-party telemetry.",
    "meta": {
        "version": "PTDL_v2",
        "update_url": null
    },
    "exported_at": "2026-06-05T17:30:00+02:00",
    "name": "s&box Game Server (OuiHeberg)",
    "author": "noc@ouiheberg.com",
    "description": "s&box dedicated server on a self-contained Debian + Wine image. SteamCMD runtime auto-update works; no external metrics reporting.",
    "features": [],
    "docker_images": {
        "ghcr.io/ouiheberg/sbox-egg:latest": "ghcr.io/ouiheberg/sbox-egg:latest"
    },
    "file_denylist": [],
    "startup": "start-sbox",
    "config": {
        "files": "{}",
        "startup": "{\r\n    \"done\": \"Loading game|Server started\"\r\n}",
        "logs": "{\r\n    \"custom\": false,\r\n    \"location\": \"logs/*.log\"\r\n}",
        "stop": "^C"
    },
    "scripts": {
        "installation": {
            "script": "#!/bin/bash\n# Runtime image downloads/validates the engine on first boot via SteamCMD\n# (SBOX_AUTO_UPDATE=1). Nothing to fetch here — just seed the dirs.\nmkdir -p /mnt/server/sbox /mnt/server/projects /mnt/server/logs\necho \"[install] s&box server directory seeded. Engine downloads on first boot.\"\n",
            "container": "debian:bookworm-slim",
            "entrypoint": "bash"
        }
    },
    "variables": [
        {
            "name": "Game",
            "description": "Game package identifier, typically org.package (for example: facepunch.walker).",
            "env_variable": "GAME",
            "default_value": "facepunch.sandbox",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:64",
            "field_type": "text"
        },
        {
            "name": "Server Name",
            "description": "Public server name shown in the s&box server browser and listings.",
            "env_variable": "SERVER_NAME",
            "default_value": "OuiHeberg Sandbox Server",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:128",
            "field_type": "text"
        },
        {
            "name": "Map",
            "description": "Optional map/package identifier loaded after +game.",
            "env_variable": "MAP",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:128",
            "field_type": "text"
        },
        {
            "name": "Local Project (.sbproj)",
            "description": "Optional local .sbproj target for +game. File must exist under /home/container/projects/; enter only relative folder/file (for example: richman/richman.sbproj).",
            "env_variable": "SBOX_PROJECT",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:255",
            "field_type": "text"
        },
        {
            "name": "Extra Args",
            "description": "Optional extra arguments. Use with caution.",
            "env_variable": "SBOX_EXTRA_ARGS",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:512",
            "field_type": "text"
        },
        {
            "name": "Max Players",
            "description": "Maximum number of players allowed on the server. (Depending on the game mode, this may cause issues if set too high)",
            "env_variable": "MAX_PLAYERS",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|numeric|between:1,256",
            "field_type": "text"
        },
        {
            "name": "Auto Update",
            "description": "Run a SteamCMD update/validate on every container boot (1=enabled, 0=disabled). On this image the runtime SteamCMD works, so 1 is fine and keeps the engine current. First boot always downloads the engine regardless of this value.",
            "env_variable": "SBOX_AUTO_UPDATE",
            "default_value": "1",
            "user_viewable": true,
            "user_editable": true,
            "rules": "required|in:0,1",
            "field_type": "text"
        },
        {
            "name": "Query Port",
            "description": "Server query port for Direct Connect. (Experimental)",
            "env_variable": "QUERY_PORT",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|numeric|between:1024,65535",
            "field_type": "text"
        },
        {
            "name": "Direct Connect (No Steam Relay)",
            "description": "EXPERIMENTAL: Allow direct connection via IP+Port instead of Steam relay.",
            "env_variable": "ENABLE_DIRECT_CONNECT",
            "default_value": "0",
            "user_viewable": true,
            "user_editable": true,
            "rules": "required|in:0,1",
            "field_type": "text"
        },
        {
            "name": "Game Server Token",
            "description": "Optional Steam game server token passed as +net_game_server_token, get your token here: https://steamcommunity.com/dev/managegameservers",
            "env_variable": "TOKEN",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|alpha_num|min:24|max:64",
            "field_type": "text"
        },
        {
            "name": "Branch",
            "description": "Optional Steam beta branch name used for updates (for example: staging).",
            "env_variable": "SBOX_BRANCH",
            "default_value": "",
            "user_viewable": true,
            "user_editable": true,
            "rules": "nullable|string|max:64",
            "field_type": "text"
        },
        {
            "name": "SteamCMD Timeout (seconds)",
            "description": "Maximum time to wait for each SteamCMD probe/update call before continuing startup (0 disables timeout).",
            "env_variable": "SBOX_STEAMCMD_TIMEOUT",
            "default_value": "600",
            "user_viewable": false,
            "user_editable": false,
            "rules": "required|numeric|between:0,7200",
            "field_type": "text"
        },
        {
            "name": "Runtime Mode",
            "description": "Select runtime backend: wine (recommended), proton (experimental), or linux (reserved).",
            "env_variable": "RUNTIME_MODE",
            "default_value": "wine",
            "user_viewable": false,
            "user_editable": false,
            "rules": "required|in:wine,proton,linux",
            "field_type": "text"
        },
        {
            "name": "SteamCMD Extra Args",
            "description": "Optional extra arguments passed to SteamCMD on update.",
            "env_variable": "STEAMCMD_EXTRA_ARGS",
            "default_value": "",
            "user_viewable": false,
            "user_editable": false,
            "rules": "nullable|string|max:256",
            "field_type": "text"
        }
    ]
}

```
