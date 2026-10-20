#!/usr/bin/env bash
# radio.kawaii.uz: Kawaii Radio sahifasini serverga o'rnatadi.
#
#   sudo ./deploy.sh            (kawaii.uz serverida, shu papka ichida)
#
# Nima qiladi:
#   1. Rust bo'lmasa o'rnatadi (rustup), sahifa serverini yig'adi (cargo build --release)
#   2. uni systemd servisi qilib ishga tushiradi: 127.0.0.1:$PORT
#   3. nginx'ni sozlaydi: faqat "/" va "/site/*" shu servisga boradi, qolgan HAMMASI (musiqa, chat,
#      ilova yangilanishlari, Kawaii ID) avvalgidek Cloudflare Worker'ga proxy bo'ladi — ilova buzilmaydi
#   4. nginx -t xato bersa, eski sozlamani qaytaradi
# Qayta ishga tushirish xavfsiz: yangi versiyani o'rnatish uchun ham shu buyruq.
#
# Sozlash (ixtiyoriy):  PORT=8096 CERT=/yo'l/cert.pem KEY=/yo'l/key.pem sudo -E ./deploy.sh
set -euo pipefail

DOMAIN="${DOMAIN:-radio.kawaii.uz}"
PORT="${PORT:-8095}"
WORKER="${WORKER:-kawaii-radio.kawaii-radio-cloud.workers.dev}"
CERT="${CERT:-/etc/ssl/kawaii/cert.pem}"
KEY="${KEY:-/etc/ssl/kawaii/key.pem}"
APP_DIR="/opt/kawaii-radio-site"
SERVICE="kawaii-radio-site"
SITE="/etc/nginx/sites-available/radio_kawaii"

say() { printf '\033[1;35m▸ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✕ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "root kerak: sudo ./deploy.sh"
cd "$(dirname "$(readlink -f "$0")")"
[ -f Cargo.toml ] || die "Cargo.toml topilmadi: skriptni sayt papkasidan ishga tushiring"
command -v nginx >/dev/null || die "nginx topilmadi"
[ -f "$CERT" ] && [ -f "$KEY" ] || die "SSL sertifikat topilmadi: $CERT, $KEY (CERT=… KEY=… bilan ko'rsating)"

# the port must be ours (or free)
if ss -ltnH "sport = :$PORT" | grep -q . && ! systemctl is-active --quiet "$SERVICE"; then
  die "$PORT port band. Boshqasini tanlang: PORT=8096 sudo -E ./deploy.sh"
fi

# ── 1. Rust
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cc >/dev/null || ! command -v curl >/dev/null; then
  say "build-essential va curl o'rnatilmoqda"
  apt-get update -qq && apt-get install -y -qq build-essential curl
fi
if ! command -v cargo >/dev/null; then
  say "Rust o'rnatilmoqda (rustup)"
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# ── 2. build
say "Yig'ilmoqda: cargo build --release (birinchi marta bir necha daqiqa)"
cargo build --release --locked
install -d -m 755 "$APP_DIR"
install -m 755 target/release/kawaii-radio-site "$APP_DIR/kawaii-radio-site.new"
mv -f "$APP_DIR/kawaii-radio-site.new" "$APP_DIR/kawaii-radio-site"
ok "Yig'ildi: $APP_DIR/kawaii-radio-site"

# ── 3. service
cat > "/etc/systemd/system/$SERVICE.service" <<UNIT
[Unit]
Description=Kawaii Radio sahifasi ($DOMAIN)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$APP_DIR/kawaii-radio-site
Environment=KR_BIND=127.0.0.1:$PORT
Environment=KR_UPSTREAM=https://$WORKER
Environment=KR_PUBLIC=https://$DOMAIN
DynamicUser=yes
Restart=always
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --quiet "$SERVICE"
systemctl restart "$SERVICE"
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$PORT/site/health" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "http://127.0.0.1:$PORT/site/health" >/dev/null 2>&1 || { journalctl -u "$SERVICE" -n 30 --no-pager; die "servis ishga tushmadi"; }
ok "Servis ishlayapti: 127.0.0.1:$PORT"

# ── 4. nginx: the page here, everything else to the Worker (as before)
BACKUP=""
if [ -f "$SITE" ]; then
  BACKUP="$SITE.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$SITE" "$BACKUP"
  say "Eski nginx sozlamasi saqlandi: $BACKUP"
fi
cat > "$SITE" <<'NGINX'
# /etc/nginx/sites-available/radio_kawaii — Kawaii Radio (site/deploy.sh yozgan, qo'lda o'zgartirmang)
#   "/" va "/site/*"  → Kawaii Radio sahifasi (Rust servis, 127.0.0.1:__PORT__)
#   qolgan hammasi    → Cloudflare Worker (musiqa, chat, ilova yangilanishlari, Kawaii ID)

server {
    listen 80;
    server_name __DOMAIN__;
    return 301 https://__DOMAIN__$request_uri;
}

server {
    listen 443 ssl http2;
    server_name __DOMAIN__;

    ssl_certificate     __CERT__;
    ssl_certificate_key __KEY__;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 60m;           # qo'shiq yuklash (50 MB gacha)

    # ── sahifa
    location = / {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
    }
    location /site/ {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    # ── qolgan hammasi: Worker (avvalgi proxy, o'zgarmagan)
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    set $radio __WORKER__;

    location / {
        proxy_pass https://$radio;
        proxy_ssl_server_name on;
        proxy_ssl_name $radio;
        proxy_set_header Host $radio;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto https;

        # chat (WebSocket)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # musiqa: darhol uzatiladi, o'rtasidan boshlash (Range) ishlaydi
        proxy_buffering off;
        proxy_request_buffering off;
    }

    access_log /var/log/nginx/radio_access.log;
    error_log  /var/log/nginx/radio_error.log;
}
NGINX
sed -i -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__PORT__|$PORT|g" -e "s|__CERT__|$CERT|g" -e "s|__KEY__|$KEY|g" -e "s|__WORKER__|$WORKER|g" "$SITE"
ln -sf "$SITE" /etc/nginx/sites-enabled/radio_kawaii

if ! nginx -t 2>/tmp/kawaii-radio-nginx.log; then
  cat /tmp/kawaii-radio-nginx.log >&2
  if [ -n "$BACKUP" ]; then cp -a "$BACKUP" "$SITE"; else rm -f "$SITE" /etc/nginx/sites-enabled/radio_kawaii; fi
  nginx -t >/dev/null 2>&1 || true
  die "nginx sozlamasida xato: eski sozlama qaytarildi, hech narsa o'zgarmadi"
fi
systemctl reload nginx
ok "nginx yangilandi"

# ── 5. check through nginx (this server, the real domain name)
check() { curl -kfsS -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN$1" 2>/dev/null || echo "xato"; }
PAGE=$(check /)
WORKER_OK=$(check /playlist.json)
[ "$PAGE" = 200 ] || die "sahifa javob bermadi (/: $PAGE)"
[ "$WORKER_OK" = 200 ] || die "Worker proxy javob bermadi (/playlist.json: $WORKER_OK) — ilova uchun muhim!"
ok "Tayyor: https://$DOMAIN  (sahifa: $PAGE, ilova API: $WORKER_OK)"
