# PicoTun

**ریورس تانل با HTTP Mimicry و Traffic Obfuscation — معماری سازگار با DaggerConnect**

## نصب سریع

```bash
bash <(curl -s https://raw.githubusercontent.com/amir6dev/RsTunnel/main/setup.sh)
```

## ویژگی‌ها

- **Persistent Connection** — TCP hijack + xtaci/smux (نه HTTP POST)
- **AES-256-GCM** — رمزنگاری per-packet روی کل کانکشن
- **HTTP Mimicry** — ترافیک شبیه HTTPS عادی به google.com
- **TLS Fragment** — شکستن ClientHello برای دور زدن DPI
- **uTLS Chrome 120** — فینگرپرینت TLS مثل کروم واقعی
- **Traffic Obfuscation** — padding تصادفی + timing jitter
- **Auto-Reconnect** — اتصال مجدد خودکار
- **TCP/UDP Support** — پشتیبانی کامل

## معماری

```
Client → TCP/TLS → Mimicry Handshake → 101 Upgrade
       → EncryptedConn (AES-GCM) → xtaci/smux → Streams
```

## استفاده

### سرور (ایران)
```bash
# نصب اتوماتیک
bash <(curl -s https://raw.githubusercontent.com/amir6dev/RsTunnel/main/setup.sh)
# گزینه 1 → Install Server
```

### کلاینت (خارج)
```bash
bash <(curl -s https://raw.githubusercontent.com/amir6dev/RsTunnel/main/setup.sh)
# گزینه 2 → Install Client
```

### مدیریت سرویس
```bash
# مشاهده لاگ
journalctl -u picotun-server -f
journalctl -u picotun-client -f

# ریستارت
systemctl restart picotun-server
systemctl restart picotun-client
```

## پروتکل‌ها

| پروتکل | DPI Bypass | کاربرد |
|---------|-----------|--------|
| httpsmux | ⭐⭐⭐⭐⭐ | **توصیه — HTTPS + Mimicry** |
| httpmux | ⭐⭐⭐⭐ | HTTP Mimicry |
| tcpmux | ⭐⭐ | ساده و سریع |
