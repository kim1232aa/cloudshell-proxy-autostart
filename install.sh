#!/bin/bash
# install.sh — one-shot installer, run inside Google Cloud Shell:
#   bash <(curl -sSL https://raw.githubusercontent.com/kim1232aa/cloudshell-proxy-autostart/main/install.sh)
#
# Optional HA mode: before re-running proxy-start.sh, drop your named-tunnel
# credentials into place:
#   echo "<tunnel-token>" > ~/proxy-bin/cf-tunnel-token
#   echo "gcs.example.com" > ~/proxy-bin/cf-hostname
set -eu

echo "[*] Preparing ~/proxy-bin (persistent across recycling)..."
mkdir -p ~/proxy-bin
cd ~/proxy-bin

if [ ! -x xray ]; then
  echo "[*] Downloading xray..."
  wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -O xray.zip
  unzip -qo xray.zip xray && chmod +x xray && rm -f xray.zip
fi

if [ ! -x cloudflared ]; then
  echo "[*] Downloading cloudflared..."
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared
  chmod +x cloudflared
fi

echo "[*] Installing proxy-start.sh ..."
cat > ~/proxy-start.sh <<'PROXY_EOF'
#!/bin/bash
# proxy-start.sh — rebuild the proxy stack on a fresh Cloud Shell instance.
#
# Two modes:
#   named-tunnel (HA):   if ~/proxy-bin/cf-tunnel-token exists, join the fixed
#                        named tunnel (multi-instance replicas, stable hostname)
#   quick-tunnel (solo): otherwise, open an ephemeral *.trycloudflare.com tunnel
#
# Idempotent: safe to re-run; already-running components are left untouched.
# Invoked automatically at boot by ~/.customize_environment.
set -u

HOME_DIR="$HOME"
BIN="$HOME_DIR/proxy-bin"
LOG="$HOME_DIR/proxy-runtime.log"
UUID_FILE="$BIN/uuid"
LINK="$HOME_DIR/proxy-link.txt"
TOKEN_FILE="$BIN/cf-tunnel-token"
HOST_FILE="$BIN/cf-hostname"
CREDS_FILE="$BIN/cf-tunnel-creds.json"
CF_CONFIG="$BIN/cf-config.yml"
VLESS_PORT=38080
WS_PATH="/vless"

mkdir -p "$BIN"

# Fast path: proxy already running with a valid link — reprint and exit.
# (never clobber a good link file just because the URL isn't in the log anymore)
if pgrep -x xray >/dev/null 2>&1 && pgrep -f "cloudflared tunnel" >/dev/null 2>&1 \
   && [ -f "$LINK" ] && grep -q '^vless://' "$LINK" 2>/dev/null; then
  grep '^vless://' "$LINK" | head -1
  echo "PROXY_READY (already running)"
  exit 0
fi

# Wait for outbound network (early boot may have no connectivity yet)
for _ in $(seq 1 30); do
  curl -s -m 3 -o /dev/null https://github.com && break
  sleep 2
done

# Binaries are cached in $HOME (persistent across recycling); download only if missing
if [ ! -x "$BIN/xray" ]; then
  (cd "$BIN" && wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -O xray.zip && unzip -qo xray.zip xray && chmod +x xray && rm -f xray.zip)
fi
if [ ! -x "$BIN/cloudflared" ]; then
  (cd "$BIN" && wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared && chmod +x cloudflared)
fi

# Stable per-install UUID: generated once, persisted in $HOME.
# For multi-account HA, copy the same uuid file to every account's Cloud Shell.
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" > "$UUID_FILE"
fi

cat > "$BIN/xray.json" <<EOF
{"inbounds":[{"listen":"127.0.0.1","port":$VLESS_PORT,"protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$WS_PATH"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF

# Start xray (idempotent)
pgrep -x xray >/dev/null 2>&1 || nohup "$BIN/xray" run -c "$BIN/xray.json" >>"$LOG" 2>&1 &

# Start cloudflared (idempotent; rotate log so we never read a stale quick-tunnel URL)
# named-tunnel priority: credentials-file mode (cf-setup.sh) > token mode (dashboard)
if ! pgrep -f "cloudflared tunnel" >/dev/null 2>&1; then
  [ -f "$LOG" ] && mv "$LOG" "$LOG.old"
  if [ -s "$CREDS_FILE" ]; then
    TID=$(grep -oE '"TunnelID"[ ]*:[ ]*"[^"]+"' "$CREDS_FILE" | cut -d'"' -f4)
    cat > "$CF_CONFIG" <<EOF2
tunnel: $TID
credentials-file: $CREDS_FILE
ingress:
  - service: http://127.0.0.1:$VLESS_PORT
EOF2
    nohup "$BIN/cloudflared" tunnel --config "$CF_CONFIG" --no-autoupdate --protocol http2 run >>"$LOG" 2>&1 &
  elif [ -s "$TOKEN_FILE" ]; then
    nohup "$BIN/cloudflared" tunnel --no-autoupdate --protocol http2 --token "$(cat "$TOKEN_FILE")" run >>"$LOG" 2>&1 &
  else
    nohup "$BIN/cloudflared" tunnel --url "http://127.0.0.1:$VLESS_PORT" --no-autoupdate --protocol http2 >>"$LOG" 2>&1 &
  fi
fi

HOST=""
if [ -s "$CREDS_FILE" ] || [ -s "$TOKEN_FILE" ]; then
  # named-tunnel mode: hostname is fixed, configured in Cloudflare dashboard
  if [ ! -s "$HOST_FILE" ]; then
    echo "FAILED $(date -u '+%F %T'): $HOST_FILE missing (write your tunnel public hostname into it)" > "$LINK"
    echo "PROXY_FAIL no cf-hostname"
    exit 1
  fi
  HOST=$(cat "$HOST_FILE")
  # wait until the edge answers (any HTTP status means a live replica)
  for _ in $(seq 1 20); do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "https://$HOST$WS_PATH" || echo 000)
    [ "$code" != "000" ] && break
    sleep 3
  done
else
  # quick-tunnel mode: scrape the ephemeral URL from the log
  URL=""
  for _ in $(seq 1 20); do
    URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$LOG" 2>/dev/null | tail -1)
    [ -n "$URL" ] && break
    sleep 3
  done
  [ -n "$URL" ] && HOST="${URL#https://}"
fi

if [ -n "$HOST" ]; then
  {
    echo "vless://$UUID@$HOST:443?type=ws&security=tls&sni=$HOST&fp=chrome&path=%2F${WS_PATH#/}&host=$HOST&encryption=none#CloudShell-auto"
    echo "# generated(UTC): $(date -u '+%F %T')"
    echo "# tip: replace the address after @ with a preferred Cloudflare IP/domain; keep sni/host unchanged"
  } > "$LINK"
  echo "PROXY_READY $HOST"
else
  echo "FAILED $(date -u '+%F %T'): tunnel URL not found, see $LOG" > "$LINK"
  echo "PROXY_FAIL"
fi

PROXY_EOF
chmod +x ~/proxy-start.sh

echo "[*] Installing ~/.customize_environment boot hook ..."
cat > ~/.customize_environment <<'HOOK_EOF'
#!/bin/bash
# Cloud Shell boot hook — runs automatically as root when the instance boots.
USER_HOME=$(ls -d /home/*/ 2>/dev/null | head -1)
[ -z "$USER_HOME" ] && exit 0
USER_NAME=$(basename "$USER_HOME")
su - "$USER_NAME" -c "nohup $USER_HOME/proxy-start.sh >/dev/null 2>&1 &"
HOOK_EOF
chmod +x ~/.customize_environment

echo "[*] Starting proxy ..."
bash ~/proxy-start.sh

echo
echo "[+] Done. Your proxy link (also at ~/proxy-link.txt):"
cat ~/proxy-link.txt
