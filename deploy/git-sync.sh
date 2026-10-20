#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  Git avto-yangilash: GitHub'ga push qilinsa server 1 daqiqa ichida kodni o'zi yuklab oladi.
#  Faqat kod yangilanadi — build va qayta ishga tushirish YO'Q (buni `sudo ./deploy.sh` qiladi).
#  .env, target/ va boshqa .gitignore dagi fayllarga tegilmaydi.
#  Serverda qaysi branch tanlangan bo'lsa (main, develop...) — shu branch kuzatiladi.
#
#    bash deploy/git-sync.sh install   — systemd timer o'rnatish (har daqiqada tekshiradi)
#    bash deploy/git-sync.sh remove    — o'chirish
#    bash deploy/git-sync.sh run       — hozir tekshirish (timer shuni chaqiradi)
#    bash deploy/git-sync.sh status    — holat va oxirgi yangilanishlar
# ═══════════════════════════════════════════════════════════════════════════
set -Eeuo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
NAME="$(basename "$REPO")-git-sync"

cmd_run() {
    cd "$REPO"
    git config --global --add safe.directory "$REPO" 2>/dev/null || true
    exec 9>"$REPO/.git/git-sync.lock"
    flock -n 9 || exit 0
    # Majburiy branch berilmagan bo'lsa — joriy branch (develop'ga o'tilsa main'ga qaytarib yubormaymiz)
    local BRANCH="${GIT_SYNC_BRANCH:-$(git symbolic-ref -q --short HEAD || echo main)}"
    git fetch -q origin "$BRANCH" || { echo "git fetch ishlamadi"; exit 1; }
    local remote; remote="$(git rev-parse "origin/$BRANCH")"
    if ! git rev-parse -q --verify HEAD >/dev/null; then
        # Bo'sh klon (birinchi push)
        git checkout -q -B "$BRANCH" "origin/$BRANCH"
        echo "✔ Birinchi yuklab olish: $(git log -1 --format='%h %s')"
        return
    fi
    [[ "$(git rev-parse HEAD)" == "$remote" ]] && return
    # fetch paytida branch almashtirilgan bo'lsa — keyingi safar (boshqa branchni boshqasiga tenglab qo'ymaslik uchun)
    [[ "$(git symbolic-ref -q --short HEAD || echo main)" == "$BRANCH" || -n "${GIT_SYNC_BRANCH:-}" ]] || return 0
    # Serverda push qilinmagan commit bo'lsa (masalan qo'lda merge) — o'chirib yubormaymiz
    if ! git merge-base --is-ancestor HEAD "$remote"; then
        echo "⚠ $BRANCH da GitHub'da yo'q commitlar bor — avto-yangilash o'tkazib yuborildi. Push qiling yoki: git reset --hard origin/$BRANCH"
        return 0
    fi
    local before; before="$(git rev-parse --short HEAD)"
    git reset -q --hard "origin/$BRANCH"
    git clean -fdq
    echo "✔ $before → $(git log -1 --format='%h %s')"
}

cmd_install() {
    [[ $EUID -eq 0 ]] || { echo "root sifatida ishga tushiring"; exit 1; }
    local user; user="$(stat -c %U "$REPO")"
    cat >"/etc/systemd/system/$NAME.service" <<EOF
[Unit]
Description=$REPO ni GitHub'dan avto-yangilash
After=network-online.target

[Service]
Type=oneshot
User=$user
ExecStart=/usr/bin/env bash $REPO/deploy/git-sync.sh run
Nice=10
EOF
    cat >"/etc/systemd/system/$NAME.timer" <<EOF
[Unit]
Description=$REPO ni har daqiqada GitHub bilan solishtirish

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$NAME.timer" >/dev/null
    echo "✔ Avto-yangilash yoqildi ($NAME.timer, har daqiqada). Loglar: journalctl -u $NAME"
}

cmd_remove() {
    systemctl disable --now "$NAME.timer" 2>/dev/null || true
    rm -f "/etc/systemd/system/$NAME.service" "/etc/systemd/system/$NAME.timer"
    systemctl daemon-reload
    echo "✔ Avto-yangilash o'chirildi"
}

cmd_status() {
    systemctl list-timers "$NAME.timer" --no-pager 2>/dev/null | head -n 3 || true
    echo "Joriy versiya: $(git -C "$REPO" log -1 --format='%h %s (%cr)' 2>/dev/null || echo '—')"
    journalctl -u "$NAME" -n 10 --no-pager -o cat 2>/dev/null | grep -v '^$' || true
}

case "${1:-}" in
    run) cmd_run ;;
    install) cmd_install ;;
    remove) cmd_remove ;;
    status) cmd_status ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
