# radio.kawaii.uz — Kawaii Radio sahifasi

Ilovaning vizitka-sayti: radio uslubida, musiqa yo'q. Android'da «ILOVANI OCHISH» tugmasi ilova o'rnatilgan
bo'lsa uni ochadi, o'rnatilmagan bo'lsa oxirgi APK'ni yuklab beradi. Kompyuter va iPhone'da APK havolasi va izoh.

Rust (axum) servis faqat `/` va `/site/*` ni beradi. Domendagi qolgan hamma narsa (musiqa, chat, ilova
yangilanishlari, Kawaii ID) avvalgidek Cloudflare Worker'ga proxy bo'ladi — **ilova uchun bu shart**.

## O'rnatish (kawaii.uz serverida)

```bash
unzip kawaii-radio-site.zip -d kawaii-radio-site
cd kawaii-radio-site
sudo ./deploy.sh
```

Skript o'zi:

1. Rust bo'lmasa o'rnatadi va servisni yig'adi (`cargo build --release`, birinchi marta bir necha daqiqa)
2. `kawaii-radio-site` systemd servisini ishga tushiradi (`127.0.0.1:8095`)
3. `/etc/nginx/sites-available/radio_kawaii` ni yangilaydi (eski fayl `.bak-<sana>` bo'lib saqlanadi),
   `nginx -t` xato bersa eskisini qaytaradi
4. Oxirida tekshiradi: sahifa ham, Worker proxy ham (`/playlist.json`) javob berishi kerak

Yangi versiyani o'rnatish ham shu buyruq bilan. Sozlash (ixtiyoriy): `PORT`, `CERT`, `KEY`, `DOMAIN`, `WORKER`,
masalan `PORT=8096 sudo -E ./deploy.sh`.

## Foydali buyruqlar

```bash
systemctl status kawaii-radio-site        # servis holati
journalctl -u kawaii-radio-site -f        # loglar
curl http://127.0.0.1:8095/site/health    # "ok"
```

## Kompyuterda sinash

```bash
KR_DEV=1 cargo run --release              # http://127.0.0.1:8095, qolgan yo'llar Worker'ga
```
