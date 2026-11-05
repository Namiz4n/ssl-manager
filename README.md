# SSL Manager

**One script: get a free SSL certificate and deploy it straight into your Xray panel.**
**یک اسکریپت: دریافت SSL رایگان و قرار دادن خودکار آن در مسیر پنل شما.**

## Quick start / شروع سریع

```bash
curl -fsSL https://raw.githubusercontent.com/Namiz4n/ssl-manager/main/ssl-manager.sh -o ssl-manager.sh
sudo bash ssl-manager.sh
```

## SSL sources / منابع SSL

| # | Source | Notes |
|---|--------|-------|
| 1 | Let's Encrypt | 90 days, wildcard via DNS, auto-renew |
| 2 | ZeroSSL | 90 days, wildcard via DNS, auto-renew |
| 3 | Google Trust Services | needs EAB keys (`gcloud publicca external-account-keys create`) |
| 4 | Buypass Go SSL | service may be discontinued |
| 5 | Cloudflare Origin CA | up to 15 years, trusted by Cloudflare only, no auto-renew |
| 6 | Self-signed | testing only |

ACME sources (1–4) support: standalone (80), TLS-ALPN (443), webroot, nginx, apache,
Cloudflare DNS (Global API Key or Token) and any other acme.sh DNS plugin.

## Supported panels / پنل‌های پشتیبانی‌شده

| Panel | Certificate folder | Restart |
|-------|--------------------|---------|
| [PasarGuard](https://github.com/PasarGuard/panel) | `/var/lib/pasarguard/certs/<domain>/` | `pasarguard restart` |
| [Marzban](https://github.com/Gozargah/Marzban) | `/var/lib/marzban/certs/<domain>/` | `marzban restart` |
| [Remnawave](https://github.com/remnawave/panel) | `/opt/remnawave/nginx/` (`fullchain.pem`, `privkey.key`) | reloads `remnawave-nginx` |
| [Marzneshin](https://github.com/marzneshin/marzneshin) | `/var/lib/marzneshin/certs/<domain>/` | `marzneshin restart` |
| [Marznode](https://github.com/marzneshin/marznode) | `/var/lib/marznode/certs/<domain>/` | manual |
| [Rebecca](https://github.com/rebeccapanel/Rebecca) | `/var/lib/rebecca/certs/<domain>/` | `rebecca restart` |
| [3x-ui (Sanaei)](https://github.com/MHSanaei/3x-ui) | `/root/cert/<domain>/` | `systemctl restart x-ui` |
| [Hiddify Manager](https://github.com/hiddify/Hiddify-Manager) | `/opt/hiddify-manager/ssl/<domain>.crt(.key)` | restarts haproxy + singbox |
| Custom | any path / file names / restart command | your command |
| None | only the master copy | – |

Every run also keeps a **master copy**:

```
/root/ssl-manager/<domain>/fullchain.pem
/root/ssl-manager/<domain>/key.pem
/root/ssl-manager/<domain>/deploy.sh   # copies files to panels + restarts; runs on every renewal
```

Auto-renewal (ACME sources): acme.sh renews via cron and runs `deploy.sh`,
so panel copies stay current.

## Menu / منو

```
1) Get a new certificate
2) Certificate status
3) Renew a certificate now
4) Remove a certificate
5) Detected panels            <- which panels are installed + which certs they use
6) Copy a certificate to panel(s)
7) Move a certificate between panels
```

Chose "No panel" first? No problem: later use **5** to see what is installed on the server,
**6** to copy the certificate into one or more panels, or **7** to move it from one panel to another
(source files are removed and the source panel is restarted).
Deploy targets are remembered in `/root/ssl-manager/<domain>/panels.list`, so auto-renewal keeps every panel up to date.

## Panel dashboard HTTPS

Optionally the script enables HTTPS on the panel itself:
`UVICORN_SSL_CERTFILE / UVICORN_SSL_KEYFILE` in the panel `.env` (a `.ssl-manager.bak` backup is made),
or `x-ui cert` for 3x-ui. Default is **no**, because the certificate is most often used for TLS inbounds.
Do not enable it if the panel already sits behind nginx/caddy with its own TLS.

## Automation / اتوماسیون

```bash
sudo bash ssl-manager.sh --ca letsencrypt --domains "example.com *.example.com" \
     --challenge cf --cf-token TOKEN --panel pasarguard --yes

sudo bash ssl-manager.sh --status
sudo bash ssl-manager.sh --renew example.com
sudo bash ssl-manager.sh --list-panels
sudo bash ssl-manager.sh --copy example.com --panel pasarguard,marzban
sudo bash ssl-manager.sh --help
```

## Notes

- Must run as root. Needs `curl`, `openssl`; installs `socat`, `cron` automatically.
- Domain must point to the server (A/AAAA) for HTTP/ALPN challenges.
- Hiddify manages its own certificates and may overwrite files for domains it controls; add the domain in Hiddify first.
- Remnawave file names follow the official nginx guide; the script overwrites those two files.
