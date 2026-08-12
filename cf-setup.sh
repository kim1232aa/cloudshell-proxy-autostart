#!/bin/bash
# cf-setup.sh — create a named Cloudflare Tunnel + DNS route for the HA proxy,
# using a locally logged-in cloudflared (no dashboard, no API token needed).
#
# One-time prereq:  cloudflared tunnel login   (browser flow, done by you)
#
# Usage:  ./cf-setup.sh gcs.example.com [tunnel-name]
#
# After it finishes, distribute the printed credentials to every Cloud Shell
# account (they make all replicas join the same tunnel).
set -eu

HOST="${1:?usage: cf-setup.sh <full-hostname> [tunnel-name]}"
NAME="${2:-gcs-proxy}"
command -v cloudflared >/dev/null || { echo "cloudflared not installed" >&2; exit 1; }
[ -f "$HOME/.cloudflared/cert.pem" ] || { echo "run 'cloudflared tunnel login' first" >&2; exit 1; }

# NOTE: a default ~/.cloudflared/config.yml makes 'tunnel route dns' silently
# target the tunnel named in that file instead of the positional argument.
# '--config /dev/null' bypasses that quirk (origin cert is still found).
CF="cloudflared --config /dev/null"

if $CF tunnel list 2>/dev/null | grep -q " $NAME "; then
  echo "[*] tunnel '$NAME' already exists, reusing"
else
  $CF tunnel create "$NAME"
fi

TID=$($CF tunnel list 2>/dev/null | awk -v n="$NAME" '$3==n {print $1; exit}')
[ -z "$TID" ] && TID=$($CF tunnel list 2>/dev/null | grep -w "$NAME" | awk '{print $1; exit}')
[ -z "$TID" ] && { echo "could not resolve tunnel id for '$NAME'" >&2; exit 1; }

$CF tunnel route dns --overwrite-dns "$NAME" "$HOST"

CREDS="$HOME/.cloudflared/$TID.json"
[ -f "$CREDS" ] || { echo "credentials file $CREDS not found" >&2; exit 1; }

cat <<EOF

[+] Tunnel ready: $NAME ($TID)
    DNS: $HOST -> $TID.cfargotunnel.com

Now, in EACH account's Cloud Shell (after running install.sh):

    mkdir -p ~/proxy-bin
    # paste the contents of $CREDS into this file:
    nano ~/proxy-bin/cf-tunnel-creds.json        # or: scp it up
    echo '$HOST' > ~/proxy-bin/cf-hostname
    # copy the first account's ~/proxy-bin/uuid here too (same UUID everywhere)
    bash ~/proxy-start.sh

Watchdog: TUNNEL_HOST=$HOST
EOF
