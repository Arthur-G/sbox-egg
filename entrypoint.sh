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
