# cloudshell-proxy-autostart

Self-healing VLESS+WS proxy on Google Cloud Shell, fronted by Cloudflare Tunnel.
Survives Cloud Shell VM recycling: boot hook rebuilds the whole stack automatically.

> 中文速览：在 Cloud Shell 里跑一行 `install.sh`，自动装好 xray(vless+ws) + cloudflared，
> 输出一条 vless:// 链接导入客户端即可。实例被回收后重开 Cloud Shell 会自启重建。
> 多 Google 账户 + Cloudflare 命名隧道可实现固定域名、掉线自动切换（见下文 Multi-account HA）。

## Architecture

```
client (Clash / v2rayN / Nekoray ...)
   │  vless+ws+tls :443
   ▼
Cloudflare edge  (preferred-IP capable)
   │  cloudflared tunnel (HTTP/2)
   ▼
Cloud Shell VM
   ├─ cloudflared ──► 127.0.0.1:38080
   └─ xray (vless+ws inbound, freedom outbound)
```

- `xray` listens only on loopback; the only ingress is the cloudflared tunnel.
- cloudflared uses `--protocol http2` (measured much faster than QUIC from Cloud Shell egress).
- `$HOME` (5 GB) persists across recycling, so binaries, UUID and the boot hook survive.
- `~/.customize_environment` is the official boot hook — it restarts everything after each rebuild.

## Measured throughput

Single-connection downloads through the proxy, from a residential line behind a CN ISP.
Your numbers will vary with time of day, CF edge and preferred IP.

| Path | Throughput |
|---|---|
| SSH dynamic forwarding (`ssh -D`) | ~0.3 MB/s |
| Quick tunnel, default CF IP | 0.1 – 3 MB/s |
| Quick tunnel, QUIC + preferred IP | 2.6 – 3.3 MB/s |
| **Quick tunnel, HTTP/2 + preferred IP** | **12 – 23 MB/s** |
| Cloud Shell raw egress (reference) | ~26 MB/s single stream |

"Preferred IP" = replace the address after `@` in the vless link with a fast Cloudflare
anycast IP/domain for your ISP; keep `sni`/`host` unchanged.

## Requirements

- A Google account with Cloud Shell access.
- (HA mode) A Cloudflare account + a domain on Cloudflare nameservers.
- Client that speaks vless+ws+tls (Clash-Meta/mihomo, v2rayN, Nekoray, sing-box, ...).

## Quick start (single account, quick tunnel)

Inside [Google Cloud Shell](https://shell.cloud.google.com):

```bash
bash <(curl -sSL https://raw.githubusercontent.com/kim1232aa/cloudshell-proxy-autostart/main/install.sh)
```

It downloads xray + cloudflared into `~/proxy-bin`, installs `~/proxy-start.sh` and the
boot hook, starts everything, and prints your link (also saved to `~/proxy-link.txt`):

```
vless://<uuid>@<random>.trycloudflare.com:443?type=ws&security=tls&...
```

Import it into your client. Done.

### After Cloud Shell recycles the VM

1. Reopen Cloud Shell (web or `gcloud cloud-shell ssh`) — the boot hook rebuilds the proxy.
2. `cat ~/proxy-link.txt` — the quick-tunnel hostname changes every rebuild, so update
   your client with the new link.

Nothing else to do; binaries and UUID are reused from `$HOME`.

## Multi-account HA (named tunnel, fixed hostname)

Quick tunnels give a random hostname per boot — fine for one account, annoying for
failover. A **named Cloudflare Tunnel** gives you one fixed hostname backed by multiple
Cloud Shell replicas (different Google accounts). Whichever replica is alive serves the
hostname; Cloudflare load-balances between connectors automatically.

One-time Cloudflare setup:

1. [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com) → **Networks → Tunnels → Add a tunnel** → type `cloudflared`.
2. Copy the tunnel token (starts with `eyJ...`).
3. Add a **Public Hostname**, e.g. `gcs.example.com`, service = `http://127.0.0.1:38080`.

Per Google account (repeat for each):

```bash
# inside that account's Cloud Shell
bash <(curl -sSL https://raw.githubusercontent.com/kim1232aa/cloudshell-proxy-autostart/main/install.sh)

echo '<tunnel-token>'   > ~/proxy-bin/cf-tunnel-token
echo 'gcs.example.com'  > ~/proxy-bin/cf-hostname

# all accounts MUST share one UUID: copy the file generated on the first account
# (first account: ~/proxy-bin/uuid) into the same path on every other account.

bash ~/proxy-start.sh   # re-join as a named-tunnel replica
cat ~/proxy-link.txt    # same fixed hostname on every account
```

Now every account's Cloud Shell joins the same tunnel. One client config works forever —
no more link updates.

### Watchdog: auto-failover from your machine

`watchdog.sh` (run locally, e.g. WSL/Linux cron) probes the hostname; when the tunnel
stops answering, it rotates to the next gcloud configuration and boots that account's
Cloud Shell — its boot hook rebuilds the proxy and rejoins the tunnel.

```bash
# one gcloud configuration per account:
gcloud config configurations create acct-a
gcloud config configurations activate acct-a
gcloud auth login
gcloud cloud-shell ssh --authorize-session   # once per account, registers the SSH key
# repeat for acct-b, acct-c, ...

# crontab -e:
*/3 * * * * /path/to/watchdog.sh gcs.example.com >>/tmp/gcs-watchdog.log 2>&1
```

Typical failover: 1–3 minutes (detection interval + Cloud Shell provisioning).

## Hard limits (read before relying on this)

- Cloud Shell has a **weekly usage quota (~50 h)** and instances can be recycled at any
  time. Multi-account rotation stretches, not removes, the quota.
- Quick-tunnel hostnames are **random per boot** — use a named tunnel for anything stable.
- Cloud Shell egress is solid (~26 MB/s single stream in tests) but throughput through the
  tunnel depends heavily on your preferred-IP choice.
- Google can throttle or restrict accounts for ToS violations. See below.

## Files

| File | Runs where | Purpose |
|---|---|---|
| `install.sh` | Cloud Shell | One-shot installer (self-contained, embeds the other two scripts) |
| `proxy-start.sh` | Cloud Shell | Rebuilds xray + cloudflared; idempotent; named/quick tunnel auto-detect |
| `.customize_environment` | Cloud Shell | Official boot hook, hands off to `proxy-start.sh` at every boot |
| `watchdog.sh` | Local machine | cron failover across gcloud configurations (HA mode) |

## Disclaimer

For development, testing and learning purposes. Running a persistent proxy on Cloud
Shell may violate the [Google Cloud Shell Terms of Service](https://cloud.google.com/terms/cloud-shell);
Google may throttle, restrict or suspend accounts that do. Use at your own risk.
Cloudflare Tunnel usage is subject to Cloudflare's terms as well.
