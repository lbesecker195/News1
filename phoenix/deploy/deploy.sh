#!/usr/bin/env bash
#
# RNews1 (Phoenix) — the one deploy script. Install or upgrade the whole stack
# on one Ubuntu/Debian server, as a release. Idempotent: rerun to deploy.
#
#   From your laptop (or CI):  phoenix/deploy/deploy.sh
#                              phoenix/deploy/deploy.sh user@host [VAR=value ...]
#   On the server, as root:    bash deploy/deploy.sh
#
# Run anywhere but as root on the server, it syncs phoenix/ to the target
# (DEPLOY_TARGET, default the ssh alias actuallyHostThemAll) and runs itself
# there; VAR=value arguments travel with it (your local environment does not).
# First time on a new box:  deploy.sh user@host PORT=4030 DOMAIN=rnews1.com
#
# The same shape as the Node deploy: /opt/rnews1 (release), /var/lib/rnews1
# (PDFs), /etc/rnews1/env (secrets; same variable names), systemd `rnews1`,
# Caddy with on-demand TLS, optional nginx page cache. One service now — the
# release runs the web app and the worker loops in one VM (WORKER=0 for a
# web-only node).

set -Eeuo pipefail

# ------------------------------------------------------------ laptop / CI side
# A first argument that is not VAR=value names the server. With no argument,
# root on Linux means "this is the server"; anything else is a laptop.
if [[ -n "${1:-}" && "$1" != *=* ]]; then
  TARGET="$1"; shift
elif [[ "$(uname -s)" != Linux || $EUID -ne 0 ]]; then
  TARGET="${DEPLOY_TARGET:-actuallyHostThemAll}"
else
  TARGET=""
  # VAR=value arguments on the server are the same thing as environment.
  for pair in "$@"; do [[ "$pair" == *=* ]] && export "${pair?}"; done
fi

if [[ -n "$TARGET" ]]; then
  REMOTE_DIR="${REMOTE_DIR:-/srv/rnews1-phoenix}"
  LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '==> %s → %s:%s\n' "$LOCAL_SRC" "$TARGET" "$REMOTE_DIR"
  # P: a checkout without the secrets or the content dump (CI) never deletes
  # the server's copies.
  rsync -az --delete --exclude _build --exclude deps --exclude .DS_Store --exclude tmp \
    --filter 'P /.env' --filter 'P /deploy/content.csv.gz' \
    "$LOCAL_SRC/" "$TARGET:$REMOTE_DIR/"
  remote_env=""; for pair in "$@"; do remote_env+=" $(printf '%q' "$pair")"; done
  tty=""; [[ -t 0 ]] && tty="-t"   # a plain string: macOS bash 3.2 trips on empty arrays under set -u
  # shellcheck disable=SC2029,SC2086
  exec ssh $tty "$TARGET" "cd '$REMOTE_DIR' && sudo env$remote_env bash deploy/deploy.sh"
fi

# ---------------------------------------------------------------- server side

DOMAIN="${DOMAIN:-rnews1.com}"
APP_HOST="${APP_HOST:-app.$DOMAIN}"
ARCHIVE_HOST="${ARCHIVE_HOST:-www.$DOMAIN}"
ACME_EMAIL="${ACME_EMAIL:-}"
APP_DIR="${APP_DIR:-/opt/rnews1}"
DATA_DIR="${DATA_DIR:-/var/lib/rnews1}"
ENV_FILE="${ENV_FILE:-/etc/rnews1/env}"
SERVICE_USER="${SERVICE_USER:-rnews1}"
CACHE="${CACHE:-auto}"
CACHE_PORT="${CACHE_PORT:-8080}"

# The daily journal: one story per section, in every language, written by the
# release itself (Rnews1.CLI.content) from a cron entry. CONTENT_HOUR is the UTC
# hour it starts, kept ahead of DIGEST_HOUR so the day's mail can draw on it.
# CONTENT_HOUR=off removes the job.
CONTENT_HOUR="${CONTENT_HOUR:-5}"

# Who terminates TLS. caddy: this script installs and configures Caddy with
# on-demand certificates (the default on an empty box). none: something else
# already owns :443 on this box (an nginx serving other sites, say); the app
# is left on 127.0.0.1:PORT for that edge to proxy to. auto picks between them.
EDGE="${EDGE:-auto}"

# Two Phoenix apps on one box both want :4000. PORT is ours; the Caddy and
# nginx configs are rendered from it, and the env file records it. On a rerun
# the env file wins unless PORT is passed explicitly, so the port never drifts
# away from what the running service was told.
PORT_ARG="${PORT:-}"
PORT="${PORT:-4000}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
SEED_ENV="${SEED_ENV:-$SRC/.env}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f "$SRC/mix.exs" ]] || die "mix.exs not found next to this script."
export DEBIAN_FRONTEND=noninteractive
FIRST_RUN=0; [[ -f "$ENV_FILE" ]] || FIRST_RUN=1

log "System packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg git rsync openssl build-essential cron \
  postgresql postgresql-contrib debian-keyring debian-archive-keyring apt-transport-https \
  fonts-liberation fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji >/dev/null
# A browser for the PDF renderer. Ubuntu 24.04+ ships Chromium only as a snap,
# which a locked-down service cannot run; without one the app simply reports
# PDFs unavailable and everything else works.
if ! command -v chromium chromium-browser google-chrome google-chrome-stable >/dev/null 2>&1; then
  installed=0
  for pkg in chromium-browser chromium; do
    # Ubuntu's chromium debs are shims that install the snap; skip those.
    if apt-cache show "$pkg" 2>/dev/null | grep -qiE "^(Description|Depends).*snap"; then continue; fi
    if apt-cache policy "$pkg" 2>/dev/null | grep -q "Candidate: [0-9]"; then
      apt-get install -y -qq "$pkg" >/dev/null 2>&1 && installed=1 && break
    fi
  done
  [[ $installed -eq 1 ]] || warn "no real Chromium package for this release; PDFs will be unavailable (install Chrome and set CHROME_EXECUTABLE)"
fi

if [[ "$EDGE" == auto ]]; then
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]443$' && ! systemctl is-active --quiet caddy; then
    EDGE=none; note "another server owns :443 on this box — EDGE=none (pass EDGE=caddy to take over the edge)"
  else
    EDGE=caddy
  fi
fi

# Erlang/Elixir: whatever the box has, if it has one (another Phoenix app's,
# say); otherwise Erlang Solutions' packages. A release built here runs here.
if ! command -v elixir >/dev/null; then
  log "Erlang + Elixir"
  curl -fsSL https://binaries2.erlang-solutions.com/GPG-KEY-pmanager.asc | gpg --dearmor -o /usr/share/keyrings/erlang-solutions.gpg
  echo "deb [signed-by=/usr/share/keyrings/erlang-solutions.gpg] https://binaries2.erlang-solutions.com/ubuntu/ $(. /etc/os-release; echo "$VERSION_CODENAME") contrib" > /etc/apt/sources.list.d/erlang-solutions.list
  apt-get update -qq && apt-get install -y -qq esl-erlang elixir >/dev/null
fi
note "$(elixir --version | tail -1)"

if [[ "$EDGE" == caddy ]] && ! command -v caddy >/dev/null; then
  log "Caddy"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq && apt-get install -y -qq caddy >/dev/null
fi

log "Service user and directories"
id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
mkdir -p "$APP_DIR" "$DATA_DIR/pdfs" "$(dirname "$ENV_FILE")"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"

seed() { if [[ -f "$SEED_ENV" ]] && grep -q "^$1=" "$SEED_ENV"; then sed -n "s/^$1=//p" "$SEED_ENV" | head -1; else echo "${2:-}"; fi; }
ensure_key() { grep -q "^$1=" "$ENV_FILE" || echo "$1=$2" >> "$ENV_FILE"; }
set_key() { if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi; }

if [[ $FIRST_RUN -eq 1 ]]; then
  log "Writing $ENV_FILE"
  DB_PASS="$(openssl rand -hex 24)"
  umask 077
  cat > "$ENV_FILE" <<ENV
# RNews1 production environment (Phoenix release). Same names as the Node app.
PHX_SERVER=true
PORT=$PORT
BIND_HOST=127.0.0.1
TRUST_PROXY=1
APP_ORIGIN=https://$APP_HOST
SITES_DOMAIN=$DOMAIN
ARCHIVE_ORIGIN=https://$ARCHIVE_HOST
ARCHIVE_TENANT_EMAIL=$(seed ARCHIVE_TENANT_EMAIL)
DATA_DIR=$DATA_DIR
DATABASE_URL=postgres://$SERVICE_USER:$DB_PASS@127.0.0.1:5432/rnews1
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')
CHROME_NO_SANDBOX=1
SUPPORT_EMAIL=$(seed SUPPORT_EMAIL "support@$DOMAIN")
BUSINESS_ADDRESS=$(seed BUSINESS_ADDRESS)
PAYPAL_MODE=$(seed PAYPAL_MODE live)
PAYPAL_CLIENT_ID=$(seed PAYPAL_CLIENT_ID)
PAYPAL_CLIENT_SECRET=$(seed PAYPAL_CLIENT_SECRET)
PAYPAL_WEBHOOK_ID=$(seed PAYPAL_WEBHOOK_ID)
MAILGUN_API_KEY=$(seed MAILGUN_API_KEY)
MAILGUN_DOMAIN=$(seed MAILGUN_DOMAIN)
MAILGUN_FROM=$(seed MAILGUN_FROM)
MAILGUN_WEBHOOK_SIGNING_KEY=$(seed MAILGUN_WEBHOOK_SIGNING_KEY)
MAILGUN_API_BASE=$(seed MAILGUN_API_BASE https://api.mailgun.net)
TREG_TOKEN=$(seed TREG_TOKEN)
NEWS_PROVIDER=$(seed NEWS_PROVIDER exa)
OPENAI_API_KEY=$(seed OPENAI_API_KEY)
OPENAI_MODEL=$(seed OPENAI_MODEL gpt-5.6-luna)
SSA_ACCOUNT_ID=$(seed SSA_ACCOUNT_ID)
DIGEST_HOUR=$(seed DIGEST_HOUR 13)
ENV
  umask 022
else
  log "Keeping $ENV_FILE"
  ensure_key PHX_SERVER true
  ensure_key SECRET_KEY_BASE "$(openssl rand -base64 48 | tr -d '\n')"
  ensure_key CHROME_NO_SANDBOX 1
  ensure_key SSA_ACCOUNT_ID ""
fi

if [[ -z "$PORT_ARG" ]] && grep -q "^PORT=" "$ENV_FILE"; then
  PORT="$(sed -n 's/^PORT=//p' "$ENV_FILE" | head -1)"
else
  set_key PORT "$PORT"
fi
chown "root:$SERVICE_USER" "$ENV_FILE"; chmod 640 "$ENV_FILE"
[[ -f "$SEED_ENV" ]] && chmod 600 "$SEED_ENV"
# Read the env file the way systemd does — KEY=VALUE, the value verbatim —
# rather than sourcing it: an address with spaces or a From header with
# angle brackets is data here, not shell.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
  key="${line%%=*}"; value="${line#*=}"
  printf -v "$key" '%s' "$value"; export "${key?}"
done < "$ENV_FILE"

# Release commands run as the service user with the service's environment.
# sudo resets the environment, so the env file's entries are passed as
# arguments to env(1) — one argument each, so values with spaces survive.
as_app() {
  local -a app_env
  mapfile -t app_env < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE")
  sudo -u "$SERVICE_USER" -H env HOME="$DATA_DIR" LANG=C.UTF-8 "${app_env[@]}" "$@"
}
ACME_EMAIL="${ACME_EMAIL:-$SUPPORT_EMAIL}"

log "PostgreSQL"
systemctl enable --now postgresql >/dev/null
DB_PASS="$(sed -n 's#^DATABASE_URL=postgres://[^:]*:\([^@]*\)@.*#\1#p' "$ENV_FILE")"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$SERVICE_USER'" | grep -q 1 || sudo -u postgres psql -qc "CREATE ROLE $SERVICE_USER LOGIN PASSWORD '$DB_PASS'"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='rnews1'" | grep -q 1 || sudo -u postgres psql -qc "CREATE DATABASE rnews1 OWNER $SERVICE_USER"
sudo -u postgres psql -q -d rnews1 -c "CREATE EXTENSION IF NOT EXISTS citext; CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null

log "Build the release"
BUILD_DIR="$APP_DIR/src"
mkdir -p "$BUILD_DIR"
rsync -a --delete --exclude _build --exclude deps --exclude .env --exclude '.DS_Store' "$SRC/" "$BUILD_DIR/"
chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"
( cd "$BUILD_DIR" && sudo -u "$SERVICE_USER" -H env HOME="$DATA_DIR" MIX_ENV=prod HEX_HOME="$DATA_DIR/.hex" MIX_HOME="$DATA_DIR/.mix" \
    bash -c 'mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get --only prod >/dev/null && mix release --overwrite >/dev/null' )
RELEASE="$BUILD_DIR/_build/prod/rel/rnews1"
note "release at $RELEASE"

log "Migrations"
as_app "$RELEASE/bin/rnews1" eval "Rnews1.Release.migrate()"
if [[ -f "$BUILD_DIR/deploy/content.csv.gz" ]]; then
  as_app "$RELEASE/bin/rnews1" eval "Rnews1.Release.load_content(\"$BUILD_DIR/deploy/content.csv.gz\")"
fi

log "systemd"
cat > /etc/systemd/system/rnews1.service <<UNIT
[Unit]
Description=RNews1 (Phoenix: web + worker)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$RELEASE
EnvironmentFile=$ENV_FILE
Environment=HOME=$DATA_DIR
Environment=LANG=C.UTF-8
ExecStart=$RELEASE/bin/rnews1 start
ExecStop=$RELEASE/bin/rnews1 stop
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR $RELEASE/tmp

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$RELEASE/tmp"; chown "$SERVICE_USER:$SERVICE_USER" "$RELEASE/tmp"

# The port must be ours. Another app may hold it right now, or may be between
# restarts with its nginx site still pointing at it — either way, starting
# here would crash-loop, and could take the port from that app when it next
# restarts.
holder="$(ss -lntpH "( sport = :$PORT )" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
if [[ -n "$holder" ]] && [[ "$(ps -o user= -p "$holder" | tr -d ' ')" != "$SERVICE_USER" ]]; then
  die "port $PORT is in use by $(ps -o user=,comm= -p "$holder" | xargs). Rerun with PORT=<a free port>."
fi
claimed="$(grep -RlsE "(127\.0\.0\.1|localhost|\[::1\]):$PORT([^0-9]|$)" /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/caddy 2>/dev/null | xargs -r grep -Ls "rnews1" || true)"
[[ -z "$claimed" ]] || die "port $PORT is another site's upstream ($(echo "$claimed" | xargs)). Rerun with PORT=<a free port>."

# A box that ran the Node version: its two services stop for good before the
# release starts, so one worker — not two — drives the same database.
for unit in rnews1-web rnews1-worker; do
  if systemctl list-unit-files "$unit.service" 2>/dev/null | grep -q "^$unit.service"; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    note "stopped the Node service $unit — the release replaces it"
  fi
done

systemctl daemon-reload
systemctl enable rnews1 >/dev/null 2>&1
systemctl restart rnews1

# Cron only says when; a oneshot unit does the work. systemd reads the env file
# verbatim (the same way as the service), logs to the journal, and refuses a
# second start while a run is still going, so a slow night never overlaps the next.
log "Daily content"
if [[ "$CONTENT_HOUR" == off ]]; then
  rm -f /etc/cron.d/rnews1-content /etc/systemd/system/rnews1-content.service
  systemctl daemon-reload
  note "no daily content job (CONTENT_HOUR=off)"
else
  [[ "$CONTENT_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || die "CONTENT_HOUR must be a UTC hour, 0-23, or off (got '$CONTENT_HOUR')."
  hh="$(printf '%02d' "$((10#$CONTENT_HOUR))")"
  cat > /etc/systemd/system/rnews1-content.service <<UNIT
[Unit]
Description=RNews1 daily content (one story per section, every language)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$RELEASE
EnvironmentFile=$ENV_FILE
Environment=HOME=$DATA_DIR
Environment=LANG=C.UTF-8
ExecStart=$RELEASE/bin/rnews1 eval "Rnews1.Release.cli(:content, [])"
TimeoutStartSec=3h
Nice=10
MemoryMax=1500M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR $RELEASE/tmp
UNIT
  # This cron has no CRON_TZ, so it wakes hourly at :17 and starts the job only
  # when the UTC hour matches. (% is special in a crontab, hence the backslash.)
  cat > /etc/cron.d/rnews1-content <<CRON
# RNews1: write the day's journal. Installed by phoenix/deploy/deploy.sh;
# change CONTENT_HOUR there and redeploy rather than editing this file.
SHELL=/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
17 * * * * root [ "\$(date -u +\\%H)" = "$hh" ] && systemctl start --no-block rnews1-content.service
CRON
  chmod 644 /etc/cron.d/rnews1-content
  systemctl daemon-reload
  systemctl enable --now cron >/dev/null 2>&1 || true
  note "journal written daily at $hh:17 UTC — logs: journalctl -u rnews1-content"
fi

UPSTREAM="127.0.0.1:$PORT"
if [[ "$EDGE" == caddy ]] && { [[ "$CACHE" == nginx ]] || { [[ "$CACHE" == auto ]] && command -v nginx >/dev/null; }; }; then
  log "nginx cache"
  command -v nginx >/dev/null || apt-get install -y -qq nginx >/dev/null
  mkdir -p /var/cache/nginx/rnews1; chown -R www-data:www-data /var/cache/nginx/rnews1
  sed -e "s/127\.0\.0\.1:8080/127.0.0.1:$CACHE_PORT/" -e "s/127\.0\.0\.1:4000/127.0.0.1:$PORT/" "$BUILD_DIR/deploy/nginx-rnews1-cache.conf" > /etc/nginx/conf.d/rnews1-cache.conf
  if nginx -t >/dev/null 2>&1; then
    rm -rf /var/cache/nginx/rnews1/*; systemctl enable --now nginx >/dev/null; systemctl reload nginx
    UPSTREAM="127.0.0.1:$CACHE_PORT"; ensure_key TRUST_PROXY_HOPS 2
    note "public pages cached 1h at 127.0.0.1:$CACHE_PORT"
  else
    rm -f /etc/nginx/conf.d/rnews1-cache.conf; warn "nginx rejected the cache config; Caddy talks to the app directly"
  fi
fi

if [[ "$EDGE" == caddy ]]; then
log "Caddy"
[[ -n "$ACME_EMAIL" ]] || die "ACME_EMAIL is required on the first run."

# Our site blocks go in a snippet of their own, so another application on this
# box keeps its Caddy configuration. The main Caddyfile only needs two things:
# the on-demand TLS `ask` in its global block, and an import of the snippets.
mkdir -p /etc/caddy/sites
RENDERED="$(sed -e "s/app\.rnews1\.com/$APP_HOST/g" -e "s/www\.rnews1\.com/$ARCHIVE_HOST/g" -e "s/rnews1\.com/$DOMAIN/g" \
    -e "s/ops@$DOMAIN/$ACME_EMAIL/" -e "s#reverse_proxy 127\.0\.0\.1:4000#reverse_proxy $UPSTREAM#g" \
    -e "s#127\.0\.0\.1:4000/\.well-known#127.0.0.1:$PORT/.well-known#" "$BUILD_DIR/deploy/Caddyfile")"

# The template opens with a global options block; split it from the sites.
# (The global block is the first `{` on a line of its own; comments may precede it.)
GLOBAL_BLOCK="$(printf '%s\n' "$RENDERED" | awk '!seen && $0 ~ /^\{[[:space:]]*$/ {inblock=1; seen=1} inblock {print} inblock && $0 ~ /^\}/ {exit}')"
printf '%s\n' "$RENDERED" | awk 'BEGIN{skip=0; seen=0} !seen && $0 ~ /^\{[[:space:]]*$/ {skip=1; seen=1} skip {if ($0 ~ /^\}/) {skip=0}; next} {print}' > /etc/caddy/sites/rnews1.caddy

MAIN=/etc/caddy/Caddyfile
if [[ ! -s "$MAIN" ]] || grep -q "/usr/share/caddy" "$MAIN" || grep -q "^# Rnews1 edge" "$MAIN"; then
  # Absent, the stock placeholder that ships with the package, or the whole-file
  # Caddyfile the Node deploy wrote (ours; its site blocks would duplicate the
  # snippet's). A copy is kept beside it.
  [[ -s "$MAIN" ]] && cp "$MAIN" "$MAIN.before-rnews1"
  printf '%s\n\nimport /etc/caddy/sites/*.caddy\n' "$GLOBAL_BLOCK" > "$MAIN"
  note "wrote $MAIN (global options + import of /etc/caddy/sites/*.caddy)"
else
  grep -q "import /etc/caddy/sites/" "$MAIN" || { printf '\nimport /etc/caddy/sites/*.caddy\n' >> "$MAIN"; note "added the sites import to your existing $MAIN"; }
  if ! grep -q "on_demand_tls" "$MAIN"; then
    if grep -q '^{' "$MAIN"; then
      warn "$MAIN already has a global block; add to it:  on_demand_tls { ask http://127.0.0.1:$PORT/.well-known/tls-ask }"
    else
      printf '%s\n\n%s\n' "$GLOBAL_BLOCK" "$(cat "$MAIN")" > "$MAIN"
      note "prepended the on-demand TLS global block to your existing $MAIN"
    fi
  fi
fi
caddy fmt --overwrite "$MAIN" >/dev/null 2>&1 || true
caddy validate --config "$MAIN" --adapter caddyfile >/dev/null || die "Caddy rejected $MAIN — see: caddy validate --config $MAIN --adapter caddyfile"
systemctl enable --now caddy >/dev/null; systemctl reload caddy
note "sites: /etc/caddy/sites/rnews1.caddy → $UPSTREAM"
else
  note "edge: none — proxy your own edge to http://$UPSTREAM (send Host, X-Forwarded-For and X-Forwarded-Proto)"
fi

# The firewall is only ever adjusted, never switched on: a box shared with
# other services has its own rules, and turning ufw on here would cut them off.
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
fi

log "Health"
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$PORT/health" && echo || warn "app not answering; journalctl -u rnews1 -n 50"
note "rnews1: $(systemctl is-active rnews1)   edge: $EDGE$([[ "$EDGE" == caddy ]] && echo " ($(systemctl is-active caddy))")"
cat <<NEXT

Done. By hand:
  1. DNS  A records for $DOMAIN and *.$DOMAIN → this server.
  2. Secrets  edit $ENV_FILE (blank values), then: systemctl restart rnews1
  3. Webhooks  PayPal → https://$APP_HOST/webhooks/paypal   Mailgun → https://$APP_HOST/webhooks/mailgun
  4. Admin  $RELEASE/bin/rnews1 eval 'Rnews1.CLI.create_admin(["you@$DOMAIN","a password","--comp"])'
  5. Check  https://$APP_HOST  https://$ARCHIVE_HOST
Logs: journalctl -u rnews1 -f
Daily content: $([[ "$CONTENT_HOUR" == off ]] && echo "off" || echo "$hh:17 UTC (cron → rnews1-content.service)")   Run now: systemctl start rnews1-content   Logs: journalctl -u rnews1-content
NEXT
