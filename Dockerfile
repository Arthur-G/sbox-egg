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
