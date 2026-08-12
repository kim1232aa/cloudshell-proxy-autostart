#!/bin/bash
# watchdog.sh — local cron job for multi-account HA.
# Checks the proxy endpoint; when it is down, rotates to the next gcloud
# configuration and triggers a Cloud Shell rebuild (the boot hook on the new
# instance restarts the proxy automatically).
#
# Setup:
#   1. Create one gcloud configuration per Google account:
#        gcloud config configurations create acct-a
#        gcloud config configurations activate acct-a
#        gcloud auth login
#        gcloud cloud-shell ssh --authorize-session   # once per account, registers the SSH key
#      repeat for acct-b, acct-c, ...
#   2. crontab -e:
#        */3 * * * * /path/to/watchdog.sh gcs.example.com >>/tmp/gcs-watchdog.log 2>&1
set -u

HOST="${1:?usage: watchdog.sh <tunnel-hostname>}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/gcs-watchdog"
STATE="$STATE_DIR/current-account"
mkdir -p "$STATE_DIR"

# Alive = the edge returns any HTTP status (tunnel has a live replica).
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$HOST/vless" || echo 000)
if [ "$code" != "000" ]; then
  echo "$(date -u '+%F %T') alive ($code)"
  exit 0
fi

echo "$(date -u '+%F %T') DOWN, rotating account..."

mapfile -t CFGS < <(gcloud config configurations list --format='value(name)' 2>/dev/null | grep -v '^default$' || true)
if [ "${#CFGS[@]}" -eq 0 ]; then
  echo "no gcloud configurations found, create them first"
  exit 1
fi

cur=0
[ -f "$STATE" ] && cur=$(cat "$STATE")
cur=$(( (cur + 1) % ${#CFGS[@]} ))
echo "$cur" > "$STATE"

target="${CFGS[$cur]}"
echo "switching to gcloud configuration: $target"
gcloud config configurations activate "$target" --quiet || exit 1

# Trigger instance provisioning; ~/.customize_environment rebuilds the proxy.
gcloud cloud-shell ssh --command="echo rebuild-triggered $(date -u '+%F %T')" --quiet \
  && echo "rebuild triggered on $target" \
  || echo "rebuild trigger failed on $target"
