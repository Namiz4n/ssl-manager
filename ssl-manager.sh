#!/usr/bin/env bash
# =============================================================================
#  SSL Manager v2.0.0
#  Get a free SSL certificate and deploy it to your Xray panel in one run.
#
#  SSL sources : Let's Encrypt, ZeroSSL, Google Trust Services, Buypass,
#                Cloudflare Origin CA, Self-signed
#  Panels      : PasarGuard, Marzban, Remnawave, Marzneshin (+marznode),
#                Rebecca, 3x-ui (Sanaei), Hiddify Manager, Custom path
#
#  Master copy : /root/ssl-manager/<domain>/fullchain.pem + key.pem
#  Usage       : sudo bash ssl-manager.sh          (interactive menu)
#                sudo bash ssl-manager.sh --help   (automation flags)
# =============================================================================
set -uo pipefail

VERSION="2.0.0"

# ---------- colors / logging ----------
if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi
info() { echo "${B}[*]${N} $*"; }
ok()   { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
err()  { echo "${R}[x]${N} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- environment ----------
[ "$(id -u)" -eq 0 ] || die "Please run as root:  sudo bash $0"
HOME="$(getent passwd 0 | cut -d: -f6)"; HOME="${HOME:-/root}"; export HOME
OUT_BASE="${SSLM_DIR:-/root/ssl-manager}"
ACME_HOME="$HOME/.acme.sh"
ACME="$ACME_HOME/acme.sh"

# ---------- state (can be preset by flags) ----------
ACTION=""; CA=""; DOMAINS_RAW=""; EMAIL=""; CHALLENGE=""; WEBROOT=""; DNS_PLUGIN=""
PANELS_RAW=""; PANEL_SSL=""; EAB_KID=""; EAB_HMAC=""; ORIGIN_KEY=""; DAYS=""
CUSTOM_DIR=""; CUSTOM_CERT=""; CUSTOM_KEY=""; CUSTOM_RESTART=""
FORCE=0; ASSUME_YES=0
CF_Token="${CF_Token:-}"; CF_Key="${CF_Key:-}"; CF_Email="${CF_Email:-}"
DOMAINS=(); PANEL_LIST=(); CH_ARGS=(); RESTARTS=()
MAIN=""; DIRNAME=""; OUT_DIR=""; DEPLOY=""

PANEL_IDS=(pasarguard marzban remnawave marzneshin marznode rebecca 3xui hiddify)

reset_state() {
  CA=""; DOMAINS_RAW=""; EMAIL=""; CHALLENGE=""; WEBROOT=""; DNS_PLUGIN=""
  PANELS_RAW=""; PANEL_SSL=""; EAB_KID=""; EAB_HMAC=""; ORIGIN_KEY=""; DAYS=""
  CUSTOM_DIR=""; CUSTOM_CERT=""; CUSTOM_KEY=""; CUSTOM_RESTART=""
  DOMAINS=(); PANEL_LIST=(); CH_ARGS=(); RESTARTS=()
}

usage() {
cat <<EOF
SSL Manager v$VERSION

Interactive:   sudo bash ssl-manager.sh
Status:        sudo bash ssl-manager.sh --status
Renew now:     sudo bash ssl-manager.sh --renew example.com
Panels:        sudo bash ssl-manager.sh --list-panels
Copy to panel: sudo bash ssl-manager.sh --copy example.com --panel pasarguard

Automation flags (any missing value is asked interactively):
  --ca NAME            letsencrypt | zerossl | google | buypass | cf-origin | self-signed
  --domains "a b"      domains separated by space or comma (wildcard: *.example.com)
  --email MAIL         account email for the CA
  --challenge NAME     standalone | alpn | webroot | nginx | apache | cf | dns
  --webroot PATH       for --challenge webroot
  --dns-plugin NAME    for --challenge dns (e.g. dns_aws); export its variables first
  --cf-token TOKEN     Cloudflare API Token (Zone:DNS:Edit)
  --cf-key KEY         Cloudflare Global API Key   (use with --cf-email)
  --cf-email MAIL      Cloudflare account email
  --eab-kid ID --eab-hmac KEY    Google Trust Services EAB credentials
  --origin-key KEY     Cloudflare Origin CA Key (for --ca cf-origin)
  --days N             validity for cf-origin / self-signed
  --panel LIST         pasarguard,marzban,remnawave,marzneshin,marznode,rebecca,
                       3xui,hiddify,custom  (comma separated) or "none"
  --custom-dir DIR  --custom-cert NAME  --custom-key NAME  --custom-restart CMD
  --panel-ssl yes|no   also enable HTTPS on the panel dashboard itself
  --force              force re-issue
  --yes                no confirmation prompts

Example:
  sudo bash ssl-manager.sh --ca letsencrypt --domains "example.com *.example.com" \\
       --challenge cf --cf-token TOKEN --panel pasarguard --yes
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ca) CA="${2:?--ca needs a value}"; shift 2 ;;
    --domains) DOMAINS_RAW="${2:?}"; shift 2 ;;
    --email) EMAIL="${2:?}"; shift 2 ;;
    --challenge) CHALLENGE="${2:?}"; shift 2 ;;
    --webroot) WEBROOT="${2:?}"; shift 2 ;;
    --dns-plugin) DNS_PLUGIN="${2:?}"; shift 2 ;;
    --cf-token) CF_Token="${2:?}"; shift 2 ;;
    --cf-key) CF_Key="${2:?}"; shift 2 ;;
    --cf-email) CF_Email="${2:?}"; shift 2 ;;
    --eab-kid) EAB_KID="${2:?}"; shift 2 ;;
    --eab-hmac) EAB_HMAC="${2:?}"; shift 2 ;;
    --origin-key) ORIGIN_KEY="${2:?}"; shift 2 ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    --panel|--panels) PANELS_RAW="${2:?}"; shift 2 ;;
    --custom-dir) CUSTOM_DIR="${2:?}"; shift 2 ;;
    --custom-cert) CUSTOM_CERT="${2:?}"; shift 2 ;;
    --custom-key) CUSTOM_KEY="${2:?}"; shift 2 ;;
    --custom-restart) CUSTOM_RESTART="${2:?}"; shift 2 ;;
    --panel-ssl) PANEL_SSL="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --status) ACTION="status"; shift ;;
    --list-panels) ACTION="panels"; shift ;;
    --copy) ACTION="copy"; DOMAINS_RAW="${2:?--copy needs a domain}"; shift 2 ;;
    --renew) ACTION="renew"; DOMAINS_RAW="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done
[ -n "$CA" ] && [ -z "$ACTION" ] && ACTION="new"

# ---------- helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
  info "Installing $1 ..."
  if   need_cmd apt-get; then apt-get update -y >/dev/null 2>&1; apt-get install -y "$1" >/dev/null 2>&1
  elif need_cmd dnf;     then dnf install -y "$1" >/dev/null 2>&1
  elif need_cmd yum;     then yum install -y "$1" >/dev/null 2>&1
  elif need_cmd apk;     then apk add --no-cache "$1" >/dev/null 2>&1
  elif need_cmd pacman;  then pacman -Sy --noconfirm "$1" >/dev/null 2>&1
  else return 1
  fi
}

ensure_deps() {
  local c
  for c in curl openssl socat; do
    need_cmd "$c" || pkg_install "$c" || warn "Could not install $c (some methods need it)."
  done
  if ! need_cmd crontab; then
    if need_cmd dnf || need_cmd yum; then pkg_install cronie; else pkg_install cron; fi
    need_cmd systemctl && systemctl enable --now cron crond >/dev/null 2>&1
  fi
}

# ask VAR "Prompt" [default] - skipped when VAR is already set (flags/env)
ask() {
  local var="$1" prompt="$2" def="${3:-}" val
  [ -n "${!var:-}" ] && return 0
  if [ "$ASSUME_YES" = 1 ] && [ -n "$def" ]; then printf -v "$var" '%s' "$def"; return 0; fi
  if [ ! -t 0 ]; then
    [ -n "$def" ] && { printf -v "$var" '%s' "$def"; return 0; }
    die "Missing value for: $prompt (pass it as a flag)"
  fi
  if [ -n "$def" ]; then read -r -p "$prompt [$def]: " val; val="${val:-$def}"
  else read -r -p "$prompt: " val; fi
  printf -v "$var" '%s' "$val"
}

ask_secret() {
  local var="$1" prompt="$2" val ch
  [ -n "${!var:-}" ] && return 0
  [ -t 0 ] || die "Missing value for: $prompt (pass it as a flag)"
  printf '%s (input hidden, shown as *; paste is OK): ' "$prompt"
  val=""
  while IFS= read -r -s -n1 ch; do
    [ -z "$ch" ] && break                       # Enter
    if [ "$ch" = $'\x7f' ] || [ "$ch" = $'\b' ]; then   # Backspace
      if [ -n "$val" ]; then val="${val%?}"; printf '\b \b'; fi
    else
      val+="$ch"; printf '*'
    fi
  done
  echo
  printf -v "$var" '%s' "$val"
}

confirm() {
  local q="$1" def="${2:-y}" a hint="Y/n"
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$def" = n ] && hint="y/N"
  [ -t 0 ] || { [ "$def" = y ]; return $?; }
  read -r -p "$q [$hint]: " a
  a="${a:-$def}"
  [[ "$a" =~ ^[Yy] ]]
}

valid_domain() {
  [[ "$1" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

has_wildcard() {
  local d
  for d in "${DOMAINS[@]}"; do [[ "$d" == \** ]] && return 0; done
  return 1
}

# set KEY = "value" inside an .env file (replaces, un-comments, or appends)
set_env() {
  local f="$1" k="$2" v="$3"
  [ -f "$f" ] || { warn "Env file not found: $f"; return 1; }
  [ -f "$f.ssl-manager.bak" ] || cp -p "$f" "$f.ssl-manager.bak"
  if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f"; then
    sed -i -E "s|^[[:space:]]*${k}[[:space:]]*=.*|${k} = \"${v}\"|" "$f"
  elif grep -qE "^[[:space:]]*#[[:space:]]*${k}[[:space:]]*=" "$f"; then
    sed -i -E "0,/^[[:space:]]*#[[:space:]]*${k}[[:space:]]*=.*/s||${k} = \"${v}\"|" "$f"
  else
    printf '%s = "%s"\n' "$k" "$v" >> "$f"
  fi
}

# ---------- panel registry ----------
# Sets: P_NAME P_DIR ({D} = domain folder) P_CERT P_KEY P_ENV P_RESTART P_KIND P_DETECT
panel_load() {
  P_NAME=""; P_DIR=""; P_CERT="fullchain.pem"; P_KEY="key.pem"
  P_ENV=""; P_RESTART=""; P_KIND="none"; P_DETECT=""
  case "$1" in
    marzban)
      P_NAME="Marzban"; P_DIR="/var/lib/marzban/certs/{D}"; P_ENV="/opt/marzban/.env"
      P_KIND="env"; P_RESTART="marzban restart"; P_DETECT="/opt/marzban /var/lib/marzban" ;;
    marzneshin)
      P_NAME="Marzneshin"; P_DIR="/var/lib/marzneshin/certs/{D}"; P_ENV="/etc/opt/marzneshin/.env"
      P_KIND="env"; P_RESTART="marzneshin restart"; P_DETECT="/etc/opt/marzneshin /var/lib/marzneshin" ;;
    marznode)
      P_NAME="Marznode (Marzneshin node)"; P_DIR="/var/lib/marznode/certs/{D}"
      P_DETECT="/var/lib/marznode" ;;
    pasarguard)
      P_NAME="PasarGuard"; P_DIR="/var/lib/pasarguard/certs/{D}"; P_ENV="/opt/pasarguard/.env"
      P_KIND="env"; P_RESTART="pasarguard restart"; P_DETECT="/opt/pasarguard /var/lib/pasarguard" ;;
    rebecca)
      P_NAME="Rebecca"; P_DIR="/var/lib/rebecca/certs/{D}"; P_ENV="/opt/rebecca/.env"
      P_KIND="env"; P_RESTART="rebecca restart"; P_DETECT="/opt/rebecca /var/lib/rebecca" ;;
    3xui)
      P_NAME="3x-ui (Sanaei)"; P_DIR="/root/cert/{D}"
      P_KIND="xui"; P_RESTART="systemctl restart x-ui"; P_DETECT="/usr/local/x-ui /etc/x-ui" ;;
    hiddify)
      P_NAME="Hiddify Manager"; P_DIR="/opt/hiddify-manager/ssl"
      P_CERT="{D}.crt"; P_KEY="{D}.crt.key"
      P_RESTART="systemctl restart hiddify-haproxy hiddify-singbox"
      P_DETECT="/opt/hiddify-manager" ;;
    remnawave)
      P_NAME="Remnawave (nginx/node ssl dir)"; P_DIR="/opt/remnawave/nginx"; P_KEY="privkey.key"
      P_RESTART="docker exec remnawave-nginx nginx -s reload"; P_DETECT="/opt/remnawave" ;;
    custom)
      P_NAME="Custom path"; P_DIR="$CUSTOM_DIR"; P_CERT="$CUSTOM_CERT"; P_KEY="$CUSTOM_KEY"
      P_RESTART="$CUSTOM_RESTART" ;;
    *) return 1 ;;
  esac
}

# true if any of the panel's marker paths exists (call after panel_load)
panel_installed() {
  local p
  for p in $P_DETECT; do [ -e "$p" ] && return 0; done
  return 1
}

detected_panels() {
  local id out=()
  for id in "${PANEL_IDS[@]}"; do
    panel_load "$id"
    panel_installed && out+=("$id")
  done
  echo "${out[@]:-}"
}

# ---------- menus ----------
pick_ca() {
  case "$CA" in
    letsencrypt|zerossl|google|buypass|cf-origin|self-signed) return 0 ;;
    "") ;;
    *) die "Unknown --ca '$CA'" ;;
  esac
  echo
  echo "${B}Choose the SSL source:${N}"
  echo "  1) Let's Encrypt            free, 90 days, wildcard via DNS, auto-renew"
  echo "  2) ZeroSSL                  free, 90 days, wildcard via DNS, auto-renew"
  echo "  3) Google Trust Services    free, 90 days, needs EAB keys"
  echo "  4) Buypass Go SSL           free, 180 days (service may be discontinued)"
  echo "  5) Cloudflare Origin CA     up to 15 years, trusted by Cloudflare only"
  echo "  6) Self-signed              testing / internal, browsers will warn"
  local c; ask c "Choose" "1"
  case "$c" in
    1) CA=letsencrypt ;; 2) CA=zerossl ;; 3) CA=google ;;
    4) CA=buypass ;; 5) CA=cf-origin ;; 6) CA=self-signed ;;
    *) die "Invalid choice." ;;
  esac
}

parse_domains() {
  local raw parts d
  while true; do
    ask DOMAINS_RAW "Domain(s), space/comma separated (e.g. example.com *.example.com)"
    DOMAINS=(); raw="${DOMAINS_RAW//,/ }"
    read -r -a parts <<< "$raw"
    local bad=0
    for d in "${parts[@]:-}"; do
      d="${d,,}"
      if valid_domain "$d"; then DOMAINS+=("$d"); else err "Invalid domain: $d"; bad=1; fi
    done
    if [ $bad -eq 0 ] && [ ${#DOMAINS[@]} -gt 0 ]; then break; fi
    [ -t 0 ] || exit 1
    DOMAINS_RAW=""
  done
  MAIN="${DOMAINS[0]}"
  DIRNAME="${MAIN//\*/_wildcard}"
  OUT_DIR="$OUT_BASE/$DIRNAME"
}

check_port() {
  local p="$1"
  if need_cmd ss && ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
    warn "Port $p is already in use:"
    ss -ltnpH "sport = :$p" 2>/dev/null | sed 's/^/      /'
    confirm "Continue anyway? (stop that service first or pick another method)" n \
      || die "Aborted."
  fi
}

cf_auth() {
  if [ -z "$CF_Token" ] && { [ -z "$CF_Key" ] || [ -z "$CF_Email" ]; }; then
    echo "  Cloudflare auth type:"
    echo "    1) Global API Key + account email"
    echo "    2) API Token (Zone:DNS:Edit) - more secure"
    local t; ask t "Choose" "1"
    if [ "$t" = "2" ]; then
      ask_secret CF_Token "Cloudflare API Token"
    else
      ask CF_Email "Cloudflare account email"
      ask_secret CF_Key "Cloudflare Global API Key"
    fi
  fi
  if [ -n "$CF_Token" ]; then export CF_Token; else export CF_Key CF_Email; fi
}

pick_challenge() {
  if [ -z "$CHALLENGE" ]; then
    echo
    echo "${B}How do you want to prove domain ownership?${N}"
    echo "  1) Standalone      port 80 must be free (stop nginx/apache first)"
    echo "  2) TLS-ALPN        port 443 must be free"
    echo "  3) Webroot         web server keeps running"
    echo "  4) Nginx plugin"
    echo "  5) Apache plugin"
    echo "  6) DNS - Cloudflare   (wildcard supported)"
    echo "  7) DNS - other provider API (wildcard supported)"
    local c; ask c "Choose" "1"
    case "$c" in
      1) CHALLENGE=standalone ;; 2) CHALLENGE=alpn ;; 3) CHALLENGE=webroot ;;
      4) CHALLENGE=nginx ;; 5) CHALLENGE=apache ;; 6) CHALLENGE=cf ;; 7) CHALLENGE=dns ;;
      *) die "Invalid choice." ;;
    esac
  fi
  case "$CHALLENGE" in
    standalone) CH_ARGS=(--standalone); check_port 80 ;;
    alpn)       CH_ARGS=(--alpn); check_port 443 ;;
    webroot)    ask WEBROOT "Webroot path (e.g. /var/www/html)"
                [ -d "$WEBROOT" ] || die "Directory not found: $WEBROOT"
                CH_ARGS=(-w "$WEBROOT") ;;
    nginx)      CH_ARGS=(--nginx) ;;
    apache)     CH_ARGS=(--apache) ;;
    cf)         cf_auth; CH_ARGS=(--dns dns_cf) ;;
    dns)        ask DNS_PLUGIN "acme.sh DNS plugin (e.g. dns_aws, dns_hetzner)"
                info "Needed variables: https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
                warn "Export them in your shell before running this script."
                CH_ARGS=(--dns "$DNS_PLUGIN") ;;
    *) die "Unknown --challenge '$CHALLENGE'" ;;
  esac
  if has_wildcard && [[ ! "$CHALLENGE" =~ ^(cf|dns)$ ]]; then
    die "Wildcard domains need a DNS challenge (cf or dns)."
  fi
}

# pick_panels [new|copy|move]  - in copy/move mode, 0 means "Back" (PANEL_LIST stays empty)
pick_panels() {
  local mode="${1:-new}"
  PANEL_LIST=()
  local id i tag sel det def="0" tok
  if [ -z "$PANELS_RAW" ]; then
    det=($(detected_panels))
    echo
    echo "${B}Deploy the certificate to which panel?${N} (several: 1,3)"
    i=1
    for id in "${PANEL_IDS[@]}"; do
      panel_load "$id"; tag=""
      if panel_installed; then tag=" ${G}[detected]${N}"; fi
      printf "  %d) %s%s\n" "$i" "$P_NAME" "$tag"
      i=$((i+1))
    done
    echo "  9) Custom path"
    if [ "$mode" = new ]; then
      echo "  0) No panel - only keep files in $OUT_BASE/<domain>/"
    else
      echo "  0) Back"
    fi
    if [ ${#det[@]} -eq 1 ] && [ "$mode" != move ]; then
      for i in "${!PANEL_IDS[@]}"; do [ "${PANEL_IDS[$i]}" = "${det[0]}" ] && def=$((i+1)); done
    fi
    ask sel "Choose" "$def"
    PANELS_RAW="$sel"
  fi
  PANELS_RAW="${PANELS_RAW//,/ }"
  for tok in $PANELS_RAW; do
    tok="${tok,,}"
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      case "$tok" in
        0) continue ;;
        9) tok="custom" ;;
        *) [ "$tok" -ge 1 ] && [ "$tok" -le ${#PANEL_IDS[@]} ] || die "Invalid panel number: $tok"
           tok="${PANEL_IDS[$((tok-1))]}" ;;
      esac
    fi
    case "$tok" in
      none|no) continue ;;
      custom)
        ask CUSTOM_DIR "Target directory (e.g. /etc/ssl/mypanel)"
        ask CUSTOM_CERT "Certificate file name" "fullchain.pem"
        ask CUSTOM_KEY "Private key file name" "key.pem"
        ask CUSTOM_RESTART "Command to reload/restart the service (empty = none)" " "
        [ -n "${CUSTOM_RESTART// /}" ] || CUSTOM_RESTART=""
        PANEL_LIST+=(custom) ;;
      *) panel_load "$tok" || die "Unknown panel: $tok"; PANEL_LIST+=("$tok") ;;
    esac
  done
}

# ---------- deploy script (runs on issue AND on every renewal) ----------
deploy_init() {
  DEPLOY="$OUT_DIR/deploy.sh"; RESTARTS=()
  cat > "$DEPLOY" <<EOF
#!/usr/bin/env bash
# Generated by SSL Manager v$VERSION - runs after every issue/renewal.
SRC="$OUT_DIR"
EOF
}

deploy_add() {   # dir cert key
  cat >> "$DEPLOY" <<EOF
mkdir -p "$1"
cp -f "\$SRC/fullchain.pem" "$1/$2" && chmod 644 "$1/$2"
cp -f "\$SRC/key.pem" "$1/$3" && chmod 600 "$1/$3"
EOF
}

deploy_finish() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] && printf '( %s ) || echo "ssl-manager: command failed: %s"\n' "$c" "$c" >> "$DEPLOY"
  done < <(printf '%s\n' "${RESTARTS[@]:-}" | awk '!s[$0]++')
  chmod 700 "$DEPLOY"
}

# A certificate's deploy targets live in <cert dir>/panels.list (one per line:
# a panel id, or custom|dir|cert|key|restart). deploy.sh is rebuilt from it.
line_for_id() {
  if [ "$1" = custom ]; then echo "custom|$CUSTOM_DIR|$CUSTOM_CERT|$CUSTOM_KEY|$CUSTOM_RESTART"
  else echo "$1"; fi
}

panel_load_line() {
  local line="$1"
  if [[ "$line" == custom\|* ]]; then
    IFS='|' read -r _ CUSTOM_DIR CUSTOM_CERT CUSTOM_KEY CUSTOM_RESTART <<< "$line"
    panel_load custom
  else
    panel_load "$line"
  fi
}

targets_add() {
  local f="$OUT_DIR/panels.list" id line
  touch "$f"
  for id in "${PANEL_LIST[@]:-}"; do
    [ -n "$id" ] || continue
    line="$(line_for_id "$id")"
    grep -qxF -- "$line" "$f" || echo "$line" >> "$f"
  done
}

targets_remove() {
  local f="$OUT_DIR/panels.list"
  grep -vxF -- "$1" "$f" > "$f.tmp"; mv -f "$f.tmp" "$f"
}

build_deploy() {
  local line dir cert key f="$OUT_DIR/panels.list"
  deploy_init
  if [ -f "$f" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      panel_load_line "$line" || continue
      dir="${P_DIR//\{D\}/$DIRNAME}"
      cert="${P_CERT//\{D\}/$MAIN}"
      key="${P_KEY//\{D\}/$MAIN}"
      deploy_add "$dir" "$cert" "$key"
      [ -n "$P_RESTART" ] && RESTARTS+=("$P_RESTART")
    done < "$f"
  fi
  deploy_finish
}

# ---------- panel dashboard HTTPS (optional) ----------
apply_panels() {
  local id any=0 dir cert key xbin
  for id in "${PANEL_LIST[@]:-}"; do
    [ -n "$id" ] || continue
    panel_load "$id"; [ "$P_KIND" != none ] && any=1
  done
  [ $any -eq 1 ] || return 0
  if [ -z "$PANEL_SSL" ]; then
    if [ "$ASSUME_YES" = 1 ]; then PANEL_SSL=no
    elif confirm "Also enable HTTPS on the panel dashboard itself?" n; then PANEL_SSL=yes
    else PANEL_SSL=no; fi
  fi
  [ "$PANEL_SSL" = yes ] || return 0

  for id in "${PANEL_LIST[@]:-}"; do
    [ -n "$id" ] || continue
    panel_load "$id"
    dir="${P_DIR//\{D\}/$DIRNAME}"; cert="$dir/${P_CERT//\{D\}/$MAIN}"; key="$dir/${P_KEY//\{D\}/$MAIN}"
    case "$P_KIND" in
      env)
        info "$P_NAME: writing UVICORN_SSL_* to $P_ENV (backup: .ssl-manager.bak)"
        set_env "$P_ENV" UVICORN_SSL_CERTFILE "$cert" && \
        set_env "$P_ENV" UVICORN_SSL_KEYFILE "$key" || continue
        [ "$CA" = "self-signed" ] && set_env "$P_ENV" UVICORN_SSL_CA_TYPE "private"
        if [ -n "$P_RESTART" ]; then ( eval "$P_RESTART" ) || warn "Restart failed: $P_RESTART"; fi
        ;;
      xui)
        xbin="/usr/local/x-ui/x-ui"; [ -x "$xbin" ] || xbin="$(command -v x-ui || true)"
        if [ -n "$xbin" ]; then
          info "$P_NAME: setting panel certificate paths"
          "$xbin" cert -webCert "$cert" -webCertKey "$key" >/dev/null 2>&1 \
            && ok "$P_NAME configured." || warn "Could not set paths. Set them in panel settings: $cert / $key"
          ( eval "$P_RESTART" ) || warn "Restart failed: $P_RESTART"
        else
          warn "x-ui binary not found. Set in panel settings: $cert / $key"
        fi
        ;;
    esac
  done
}

# ---------- certificate sources ----------
ensure_acme() {
  [ -x "$ACME" ] && return 0
  info "Installing acme.sh ..."
  curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null 2>&1 || die "acme.sh install failed (network?)."
  [ -x "$ACME" ] || die "acme.sh not found after install."
}

acme_prepare() {
  ask EMAIL "Account email" "ssl@${MAIN#\*.}"
  if [ "$CA" = "google" ]; then
    info "Google needs EAB keys:  gcloud publicca external-account-keys create"
    ask EAB_KID "EAB Key ID"
    ask_secret EAB_HMAC "EAB HMAC key"
  fi
  pick_challenge
}

obtain_acme() {
  local server="$CA" d dargs=() extra=() rc
  ensure_acme
  if [ "$CA" = "google" ]; then
    "$ACME" --register-account -m "$EMAIL" --server google \
      --eab-kid "$EAB_KID" --eab-hmac-key "$EAB_HMAC" || die "Google account registration failed."
  else
    "$ACME" --register-account -m "$EMAIL" --server "$server" >/dev/null 2>&1 || true
  fi
  for d in "${DOMAINS[@]}"; do dargs+=(-d "$d"); done
  [ "$FORCE" = 1 ] && extra+=(--force)

  info "Requesting certificate from $server ..."
  "$ACME" --issue --server "$server" "${dargs[@]}" "${CH_ARGS[@]}" ${extra[@]+"${extra[@]}"}
  rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 2 ]; then err "Issue failed (code $rc). See output above."; return 1; fi
  [ $rc -eq 2 ] && warn "Certificate is still valid; using the existing one."

  "$ACME" --install-cert -d "$MAIN" \
    --key-file "$OUT_DIR/key.pem" --fullchain-file "$OUT_DIR/fullchain.pem" \
    --reloadcmd "bash $OUT_DIR/deploy.sh" || { err "install-cert failed."; return 1; }
  chmod 600 "$OUT_DIR/key.pem"
  ok "Auto-renewal is handled by acme.sh (cron); panel copies update automatically."
}

obtain_origin() {
  need_cmd python3 || pkg_install python3 || die "python3 is required for this option."
  warn "Origin certs are trusted ONLY by Cloudflare: domain must be proxied (orange cloud), SSL mode Full (strict)."
  info "Origin CA Key: Cloudflare dashboard > My Profile > API Tokens > Origin CA Key"
  ask_secret ORIGIN_KEY "Origin CA Key (starts with v1.0-)"
  echo "Validity days: 7, 30, 90, 365, 730, 1095, 5475"
  ask DAYS "Validity" "5475"

  openssl req -new -newkey rsa:2048 -nodes -keyout "$OUT_DIR/key.pem" \
    -out "$OUT_DIR/request.csr" -subj "/CN=$MAIN" >/dev/null 2>&1 || { err "CSR generation failed."; return 1; }
  chmod 600 "$OUT_DIR/key.pem"

  local payload="$OUT_DIR/.payload.json" resp="$OUT_DIR/.response.json"
  HOSTS="${DOMAINS[*]}" CSR_FILE="$OUT_DIR/request.csr" VALID="$DAYS" python3 - "$payload" <<'PY'
import json, os, sys
json.dump({"hostnames": os.environ["HOSTS"].split(),
           "requested_validity": int(os.environ["VALID"]),
           "request_type": "origin-rsa",
           "csr": open(os.environ["CSR_FILE"]).read()}, open(sys.argv[1], "w"))
PY
  curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" \
    -H "Content-Type: application/json" \
    -H "X-Auth-User-Service-Key: $ORIGIN_KEY" \
    --data @"$payload" -o "$resp" || { err "API request failed."; rm -f "$payload" "$resp"; return 1; }

  CERT_OUT="$OUT_DIR/fullchain.pem" python3 - "$resp" <<'PY'
import json, os, sys
r = json.load(open(sys.argv[1]))
if not r.get("success"):
    print("Cloudflare error:", json.dumps(r.get("errors"), indent=2)); sys.exit(1)
open(os.environ["CERT_OUT"], "w").write(r["result"]["certificate"])
PY
  local rc=$?
  rm -f "$payload" "$resp" "$OUT_DIR/request.csr"
  [ $rc -eq 0 ] || return 1
  bash "$DEPLOY"
  warn "Origin certs do not auto-renew; run this option again before expiry."
}

obtain_self() {
  local san="" d
  ask DAYS "Validity in days" "365"
  for d in "${DOMAINS[@]}"; do san+="DNS:$d,"; done
  openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
    -keyout "$OUT_DIR/key.pem" -out "$OUT_DIR/fullchain.pem" \
    -subj "/CN=$MAIN" -addext "subjectAltName=${san%,}" >/dev/null 2>&1 \
    || { err "OpenSSL failed (needs OpenSSL 1.1.1+)."; return 1; }
  chmod 600 "$OUT_DIR/key.pem"
  bash "$DEPLOY"
  warn "Self-signed: browsers will warn. For testing/internal use only."
}

# ---------- main flow: new certificate ----------
show_plan() {
  local id names=()
  for id in "${PANEL_LIST[@]:-}"; do [ -n "$id" ] && { panel_load "$id"; names+=("$P_NAME"); }; done
  echo
  echo "${B}----- Plan -----${N}"
  echo "  Source  : $CA"
  echo "  Domains : ${DOMAINS[*]}"
  [ -n "$CHALLENGE" ] && echo "  Method  : $CHALLENGE"
  echo "  Master  : $OUT_DIR/{fullchain.pem,key.pem}"
  echo "  Panels  : ${names[*]:-none}"
  echo
}

summary() {
  local id dir cert key first=""
  echo
  ok "Done. Master copy:"
  echo "    $OUT_DIR/fullchain.pem"
  echo "    $OUT_DIR/key.pem"
  for id in "${PANEL_LIST[@]:-}"; do
    [ -n "$id" ] || continue
    panel_load "$id"
    dir="${P_DIR//\{D\}/$DIRNAME}"; cert="${P_CERT//\{D\}/$MAIN}"; key="${P_KEY//\{D\}/$MAIN}"
    echo "  ${P_NAME}:"
    echo "    $dir/$cert"
    echo "    $dir/$key"
    [ -z "$first" ] && first="$dir|$cert|$key"
  done
  [ -z "$first" ] && first="$OUT_DIR|fullchain.pem|key.pem"
  IFS='|' read -r dir cert key <<< "$first"
  echo
  echo "  Xray inbound (TLS) snippet:"
  echo "    \"certificates\": [{ \"certificateFile\": \"$dir/$cert\", \"keyFile\": \"$dir/$key\" }]"
  echo
  [ -z "$(printf '%s' "${PANEL_LIST[@]:-}")" ] || warn "If you edit inbounds in the panel, use the paths above."
}

new_cert() {
  pick_ca
  parse_domains
  case "$CA" in letsencrypt|zerossl|google|buypass) acme_prepare ;; esac
  pick_panels
  show_plan
  confirm "Proceed?" y || { warn "Cancelled."; return 1; }

  mkdir -p "$OUT_DIR" && chmod 700 "$OUT_DIR" "$OUT_BASE"
  targets_add
  build_deploy
  case "$CA" in
    letsencrypt|zerossl|google|buypass) obtain_acme || return 1 ;;
    cf-origin)    obtain_origin || return 1 ;;
    self-signed)  obtain_self || return 1 ;;
  esac
  apply_panels
  summary
}

# ---------- status / renew / remove ----------
managed_domains() {
  local f
  for f in "$OUT_BASE"/*/fullchain.pem; do
    [ -f "$f" ] && basename "$(dirname "$f")"
  done
}

cert_status() {
  local d f end ts days issuer found=0
  echo
  printf "%-34s %-12s %s\n" "DOMAIN" "DAYS LEFT" "ISSUER"
  while IFS= read -r d; do
    [ -n "$d" ] || continue; found=1
    f="$OUT_BASE/$d/fullchain.pem"
    end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)"
    ts="$(date -d "$end" +%s 2>/dev/null || echo 0)"
    days=$(( (ts - $(date +%s)) / 86400 ))
    issuer="$(openssl x509 -issuer -noout -in "$f" 2>/dev/null | sed -E 's/.*(CN ?= ?|O ?= ?)//' | cut -c1-30)"
    printf "%-34s %-12s %s\n" "$d" "$days" "$issuer"
  done < <(managed_domains)
  [ $found -eq 1 ] || warn "No certificates found in $OUT_BASE"
}

pick_existing() {  # sets SEL_DOMAIN
  local list=() d i=1 n
  while IFS= read -r d; do [ -n "$d" ] && list+=("$d"); done < <(managed_domains)
  [ ${#list[@]} -gt 0 ] || { warn "No certificates found."; return 1; }
  if [ -n "$DOMAINS_RAW" ]; then
    SEL_DOMAIN="${DOMAINS_RAW//\*/_wildcard}"
    [ -f "$OUT_BASE/$SEL_DOMAIN/fullchain.pem" ] || { err "No managed certificate for: $DOMAINS_RAW"; return 1; }
    return 0
  fi
  for d in "${list[@]}"; do echo "  $i) $d"; i=$((i+1)); done
  echo "  0) Back"
  ask n "Choose"
  [ "$n" = 0 ] && return 1
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#list[@]} ] || { err "Invalid choice."; return 1; }
  SEL_DOMAIN="${list[$((n-1))]}"
}

# select an existing managed certificate; sets MAIN DIRNAME OUT_DIR
select_cert() {
  pick_existing || return 1
  DIRNAME="$SEL_DOMAIN"
  MAIN="${DIRNAME/#_wildcard./*.}"
  OUT_DIR="$OUT_BASE/$DIRNAME"
}

cert_is_selfsigned() {
  [ "$(openssl x509 -noout -subject -in "$1" 2>/dev/null | sed 's/^subject= *//')" = \
    "$(openssl x509 -noout -issuer  -in "$1" 2>/dev/null | sed 's/^issuer= *//')" ]
}

panels_overview() {
  local id dom missing=() found=0
  echo
  echo "${B}Panels on this server:${N}"
  for id in "${PANEL_IDS[@]}"; do
    panel_load "$id"
    if panel_installed; then
      found=1
      echo "  ${G}*${N} $P_NAME   (found: $P_DETECT)"
      while IFS= read -r dom; do
        [ -n "$dom" ] || continue
        grep -qxF "$id" "$OUT_BASE/$dom/panels.list" 2>/dev/null && echo "       certificate deployed: $dom"
      done < <(managed_domains)
      if [ "$P_KIND" = env ] && [ -f "$P_ENV" ] && grep -qE '^[[:space:]]*UVICORN_SSL_CERTFILE' "$P_ENV"; then
        echo "       dashboard HTTPS: configured in $P_ENV"
      fi
    else
      missing+=("$P_NAME")
    fi
  done
  [ $found -eq 1 ] || warn "No known panel detected."
  [ ${#missing[@]} -gt 0 ] && echo "  not found: $(IFS=,; echo "${missing[*]}" | sed 's/,/, /g')"
}

copy_cert() {
  select_cert || return 1
  PANELS_RAW="${PANELS_RAW:-}"; PANEL_LIST=()
  pick_panels copy
  [ ${#PANEL_LIST[@]} -gt 0 ] || return 0
  confirm "Copy $DIRNAME to the selected panel(s) and restart them?" y || return 0
  cert_is_selfsigned "$OUT_DIR/fullchain.pem" && CA="self-signed"
  targets_add
  build_deploy
  bash "$DEPLOY"
  apply_panels
  summary
  ok "Future renewals will update these panels automatically."
}

move_cert() {
  local f line i n lines=() src dst
  select_cert || return 1
  f="$OUT_DIR/panels.list"
  [ -s "$f" ] || { warn "$DIRNAME is not deployed to any panel yet. Use 'Copy' instead."; return 1; }
  mapfile -t lines < "$f"
  echo "Currently deployed to:"
  i=1
  for line in "${lines[@]}"; do panel_load_line "$line"; echo "  $i) $P_NAME"; i=$((i+1)); done
  echo "  0) Back"
  n=""; ask n "Move FROM which one?"
  [ "$n" = 0 ] && return 0
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#lines[@]} ] || { err "Invalid choice."; return 1; }
  src="${lines[$((n-1))]}"
  echo
  echo "Now choose the destination panel(s):"
  PANELS_RAW=""; PANEL_LIST=()
  pick_panels move
  [ ${#PANEL_LIST[@]} -gt 0 ] || return 0
  for i in "${PANEL_LIST[@]}"; do
    [ "$(line_for_id "$i")" = "$src" ] && { err "Source and destination are the same panel."; return 1; }
  done
  confirm "Move $DIRNAME and delete its files from the source panel?" y || return 0

  cert_is_selfsigned "$OUT_DIR/fullchain.pem" && CA="self-signed"
  targets_add
  build_deploy
  bash "$DEPLOY"
  apply_panels

  # clean up the source panel
  panel_load_line "$src"
  local sdir="${P_DIR//\{D\}/$DIRNAME}" scert="${P_CERT//\{D\}/$MAIN}" skey="${P_KEY//\{D\}/$MAIN}"
  if [ "$P_KIND" = env ] && [ -f "$P_ENV" ] && grep -qF "$sdir" "$P_ENV"; then
    warn "$P_NAME dashboard HTTPS points to the files being removed."
    if confirm "Comment out UVICORN_SSL_* in $P_ENV so the panel still starts?" y; then
      [ -f "$P_ENV.ssl-manager.bak" ] || cp -p "$P_ENV" "$P_ENV.ssl-manager.bak"
      sed -i -E 's@^([[:space:]]*UVICORN_SSL_(CERTFILE|KEYFILE|CA_TYPE)[[:space:]]*=.*)@# \1@' "$P_ENV"
    fi
  elif [ "$P_KIND" = xui ]; then
    warn "If 3x-ui dashboard uses this certificate, update its panel settings manually."
  fi
  rm -f "$sdir/$scert" "$sdir/$skey"
  rmdir --ignore-fail-on-non-empty "$sdir" 2>/dev/null
  targets_remove "$src"
  build_deploy
  [ -n "$P_RESTART" ] && { ( eval "$P_RESTART" ) || warn "Restart failed: $P_RESTART"; }
  ok "Moved. Files removed from: $sdir"
  summary
}

renew_now() {
  local d
  pick_existing || return 1; d="$SEL_DOMAIN"
  if [ -x "$ACME" ] && "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qxF "${d/_wildcard/\*}"; then
    "$ACME" --renew -d "${d/_wildcard/\*}" --force
  else
    warn "$d was not issued through acme.sh (Origin CA / self-signed). Run 'Get a new certificate' again."
  fi
}

remove_cert() {
  local d
  pick_existing || return 1; d="$SEL_DOMAIN"
  confirm "Delete $OUT_BASE/$d and stop auto-renewal? (panel copies are NOT touched)" n || return 0
  [ -x "$ACME" ] && "$ACME" --remove -d "${d/_wildcard/\*}" >/dev/null 2>&1
  rm -rf "${OUT_BASE:?}/$d"
  ok "Removed."
}

# ---------- entry ----------
main_menu() {
  local c
  while true; do
    echo
    echo "${B}==================== SSL Manager v$VERSION ====================${N}"
    echo "  1) Get a new certificate"
    echo "  2) Certificate status"
    echo "  3) Renew a certificate now"
    echo "  4) Remove a certificate"
    echo "  5) Detected panels"
    echo "  6) Copy a certificate to panel(s)"
    echo "  7) Move a certificate between panels"
    echo "  0) Exit"
    c=""; ask c "Choose"
    case "$c" in
      1) new_cert; reset_state ;;
      2) cert_status ;;
      3) DOMAINS_RAW=""; renew_now ;;
      4) DOMAINS_RAW=""; remove_cert ;;
      5) panels_overview ;;
      6) DOMAINS_RAW=""; PANELS_RAW=""; copy_cert; reset_state ;;
      7) DOMAINS_RAW=""; PANELS_RAW=""; move_cert; reset_state ;;
      0|q|Q) exit 0 ;;
      *) err "Invalid choice." ;;
    esac
  done
}

ensure_deps
case "$ACTION" in
  new)    new_cert; exit $? ;;
  status) cert_status ;;
  renew)  renew_now ;;
  panels) panels_overview ;;
  copy)   copy_cert ;;
  "")     main_menu ;;
esac
