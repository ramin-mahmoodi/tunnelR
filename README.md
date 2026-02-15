# TunnelR (PicoTun)

**نسل جدید تانل معکوس با قابلیت‌های پیشرفته: Connection Pooling، Compression، و DNS-over-Tunnel**

این پروژه یک بازنویسی کامل از PicoTun با تمرکز بر پایداری و سرعت است.

## ویژگی‌های جدید (v2.4.4) 🚀

- **Connection Pool**: برقراری چندین کانکشن smux به صورت همزمان (Multi-Session) برای افزایش Throughput.
- **Snappy Compression**: فشرده‌سازی ترافیک برای کاهش مصرف پهنای باند.
- **DNS-over-Tunnel**: پراکسی داخلی DNS برای جلوگیری از DNS Leak.
- **Stable Profile**: پروفایل جدید با بافرهای بهینه شده برای جلوگیری از نوسان سرعت (Sawtooth fix).
- **TCP_NODELAY**: کاهش تاخیر با ارسال سریع بسته‌ها.

## ویژگی‌های اصلی

- **Dagger-Compatible Architecture**: سازگار با معماری Dagger (Reverse Tunnel + Smux).
- **AES-256-GCM**: رمزنگاری قدرتمند روی تمام بسته‌ها.
- **HTTP Mimicry**: ترافیک کاملاً شبیه به وب‌گردی عادی (HTTPS به google.com).
- **TLS Fragment**: شکستن بسته ClientHello برای دور زدن فیلترینگ پیشرفته (DPI).
- **uTLS Fingerprint**: شبیه‌سازی دقیق فینگرپرینت Chrome 120.

---

## نصب سریع (Linux)

```bash
bash <(curl -s https://raw.githubusercontent.com/ramin-mahmoodi/tunnelR/main/setup.sh)
```

با اجرای دستور بالا منوی نصب باز می‌شود:
- **گزینه 1**: نصب سرور (ایران)
- **گزینه 2**: نصب کلاینت (خارج)

---

## پیکربندی دستی

### سرور (Server)

فایل کانفیگ: `/etc/picotun/server.yaml`

```yaml
mode: "server"
listen: "0.0.0.0:2020"
transport: "httpsmux"  # httpmux, tcpmux
psk: "my-secret-password"
profile: "stable"      # aggressive, balanced, stable, latency
verbose: true

# فوروارد کردن پورت‌ها (Reverse Tunnel)
forward:
  tcp:
    - "0.0.0.0:8080 -> 127.0.0.1:8080" # پورت 8080 سرور به 8080 کلاینت

# تنظیمات پیشرفته
smux:
  version: 2
  keepalive: 15
  max_recv: 524288    # 512KB (Stable Profile)
  max_stream: 262144  # 256KB (Stable Profile)

obfuscation:
  enabled: true
  min_padding: 4
  max_padding: 32
```

### کلاینت (Client)

فایل کانفیگ: `/etc/picotun/client.yaml`

```yaml
mode: "client"
psk: "my-secret-password"
transport: "httpsmux"
profile: "stable"      # استفاده از پروفایل استیبل توصیه می‌شود
verbose: true

# اتصال به سرور
paths:
  - addr: "1.2.3.4:2020"    # آدرس سرور ایران
    transport: "httpsmux"
    connection_pool: 4      # تعداد کانکشن‌های همزمان (افزایش سرعت)
    dial_timeout: 10

# DNS-over-Tunnel (اختیاری)
dns:
  enabled: true
  listen: "127.0.0.1:53"
  upstream: "8.8.8.8:53"

# فشرده‌سازی (اختیاری)
compression: "snappy"
```

---

## مدیریت سرویس

```bash
# مشاهده لاگ‌ها
journalctl -u picotun-server -f
journalctl -u picotun-client -f

# ریستارت سرویس
systemctl restart picotun-server
systemctl restart picotun-client

# توقف سرویس
systemctl stop picotun-server
```

## بیلد کردن (Build from Source)

نیاز به Go 1.21+:

```bash
git clone https://github.com/ramin-mahmoodi/tunnelR.git
cd tunnelR
go mod tidy
go build -o picotun cmd/picotun/main.go
```
