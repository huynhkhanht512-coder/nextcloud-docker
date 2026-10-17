# Nextcloud + MariaDB + Redis trên Docker Compose

Đồ án triển khai Docker: ứng dụng lưu trữ file cá nhân **Nextcloud** chỉ đóng vai trò "vật thí nghiệm".
Trọng tâm là **Docker Compose**, **quản lý trạng thái container**, **volume / bind mount**, và phần nâng cao
**bảo mật – giám sát – CI/CD**.

> Kịch bản demo từng bước (kèm ảnh cần chụp cho báo cáo) nằm trong **[DEMO.md](DEMO.md)**.

## Khởi động nhanh

```bash
./scripts/init-env.sh        # sinh .env với mật khẩu ngẫu nhiên
docker compose up -d         # lần đầu mất 1-2 phút để Nextcloud tự cài đặt
docker compose ps            # chờ nc_app chuyển sang (healthy)
```

Mở <http://localhost:8080>, đăng nhập `admin` với mật khẩu: `grep NEXTCLOUD_ADMIN_PASSWORD .env`

## Kiến trúc

```
                 Internet / LAN
                       │
        ┌──────────────┴───────────────┐
        │ :8080 (HTTP)     :443 (HTTPS)│            ← cổng duy nhất mở ra host
        │                  ┌─────────┐ │
        │                  │  caddy  │ │  (overlay security)
        │                  └────┬────┘ │
        │      mạng nc_frontend │      │
        │                  ┌────▼────┐ │      ┌──────────┐
        └─────────────────►│   app   │ │      │   cron   │
                           │nextcloud│ │      │ (tác vụ  │
                           └────┬────┘ │      │   nền)   │
        mạng nc_backend (internal: không ra Internet)    │
                  ┌─────────────┴──────┴──────────┐
             ┌────▼────┐                     ┌────▼────┐
             │   db    │                     │  redis  │
             │ mariadb │                     │ (cache) │
             └────┬────┘                     └─────────┘
              nc_db (volume)

 Giám sát (overlay monitoring):  cadvisor ──► prometheus ──► grafana   (mạng nc_monitoring)
```

## Cấu trúc thư mục

```
nextcloud-docker/
├── docker-compose.yml             # LÕI: app, cron, db, redis
├── docker-compose.security.yml    # NÂNG CAO: Caddy HTTPS, giới hạn tài nguyên, hardening
├── docker-compose.monitoring.yml  # NÂNG CAO: cAdvisor + Prometheus + Grafana
├── .env.example                   # mẫu biến môi trường (.env sinh bởi init-env.sh)
├── config/php-custom.ini          # BIND MOUNT (chỉ-đọc) – cấu hình PHP
├── shared/                        # BIND MOUNT (đọc-ghi)  – thư mục chia sẻ host <-> container
├── backup/                        # nơi chứa file sao lưu trên host
├── caddy/Caddyfile                # BIND MOUNT – cấu hình reverse proxy
├── monitoring/                    # cấu hình Prometheus, luật cảnh báo, dashboard Grafana
├── scripts/
│   ├── init-env.sh                # tạo .env + mật khẩu ngẫu nhiên + thư mục
│   ├── backup.sh                  # sao lưu CSDL + volume
│   └── restore.sh                 # phục hồi từ bản sao lưu
├── .github/workflows/ci-cd.yml    # CI/CD GitHub Actions
├── DEMO.md                        # kịch bản demo từng bước
└── README.md
```

## Chọn mức triển khai (biến `COMPOSE_FILE` trong `.env`)

| Mức | Giá trị `COMPOSE_FILE` | Truy cập |
|---|---|---|
| Lõi | `docker-compose.yml` | http://localhost:8080 |
| + Bảo mật | `docker-compose.yml:docker-compose.security.yml` | https://localhost (và đặt `NC_BIND_IP=127.0.0.1`) |
| Đầy đủ | `…:docker-compose.security.yml:docker-compose.monitoring.yml` | + Grafana http://localhost:3000, Prometheus http://localhost:9090 |

Sau khi sửa `.env`, chạy lại `docker compose up -d`. Trên Windows, dấu ngăn cách trong `COMPOSE_FILE` là `;`
(hoặc dùng cờ `-f` trực tiếp: `docker compose -f docker-compose.yml -f docker-compose.security.yml up -d`).

## Volume và bind mount dùng trong đồ án

| Loại | Nguồn (host) | Đích (container) | Mục đích |
|---|---|---|---|
| Named volume | `nc_db` | `db:/var/lib/mysql` | dữ liệu CSDL |
| Named volume | `nc_html` | `app:/var/www/html` | mã nguồn + cấu hình Nextcloud |
| Named volume | `nc_data` | `app:/var/www/html/data` | file của người dùng |
| Bind mount (ro) | `./config/php-custom.ini` | `app:/usr/local/etc/php/conf.d/zz-custom.ini` | chỉnh PHP từ host |
| Bind mount (rw) | `./shared` | `app:/mnt/shared` | chia sẻ thư mục host ↔ container |
| Bind mount (ro) | `./caddy/Caddyfile`, `./monitoring/...` | Caddy / Prometheus / Grafana | cấu hình dịch vụ |
| Bind mount (rw) | `./backup` | container tạm của `backup.sh` | lấy file sao lưu ra host |

## Xử lý sự cố thường gặp

| Hiện tượng | Nguyên nhân / cách xử lý |
|---|---|
| `nc_app` ở trạng thái `starting` rất lâu | Lần đầu Nextcloud cài đặt mất 1-2 phút; xem `docker compose logs -f app`. |
| "Access through untrusted domain" | Tên miền/IP chưa nằm trong `trusted_domains`. Biến `NEXTCLOUD_TRUSTED_DOMAINS` chỉ có tác dụng lúc cài lần đầu. Thêm sau: `docker compose exec -u www-data app php occ config:system:set trusted_domains 3 --value=192.168.1.50` |
| Cổng 8080/80/443 đã bị chiếm | Đổi `NC_HTTP_PORT`, `CADDY_HTTP_PORT`, `CADDY_HTTPS_PORT` trong `.env`. |
| Không ghi được vào `shared/` từ giao diện Nextcloud | `www-data` (uid 33) cần quyền ghi: `chmod 777 shared` (demo) hoặc `sudo chown 33:33 shared`. |
| Đã bật HTTPS nhưng đăng nhập bằng `http://localhost:8080` bị lỗi | Overlay đặt `OVERWRITEPROTOCOL=https`; hãy dùng địa chỉ `https://...` qua Caddy. |
| Restore xong Nextcloud không kết nối được DB | `.env` hiện tại khác `.env` lúc sao lưu. Dùng lại `backup/env_<mã>.bak`. |
| Prometheus không thấy số liệu container (Docker Desktop) | cAdvisor cần cgroup của Linux. Chạy trên máy Linux/VM. |
| Sau khi bật `security.yml`, `nc_db`/`nc_redis` không lên | Xem `docker compose logs <service>`. Có thể tạm bỏ các dòng `cap_drop`/`read_only` của service đó để xác định nguyên nhân. |
| Truy cập Grafana từ máy khác không được | `MON_BIND_IP=127.0.0.1` là mặc định (an toàn). Đổi thành `0.0.0.0` hoặc dùng SSH tunnel. |

## Giới hạn đã biết

- Mật khẩu nằm trong `.env` (quyền 600, không commit). Mức cao hơn: dùng Docker secrets (Nextcloud, MariaDB đều hỗ trợ biến `*_FILE`).
- Redis nhận mật khẩu qua tham số dòng lệnh nên hiện trong `docker inspect`; chấp nhận được cho đồ án, môi trường thật nên dùng file cấu hình + secret.
- Chứng chỉ HTTPS là chứng chỉ nội bộ do Caddy tự tạo (trình duyệt sẽ cảnh báo cho đến khi import CA, xem DEMO.md phần 5).
- Backup lưu cả `.env` (chứa mật khẩu) nên thư mục `backup/` cần được bảo vệ như dữ liệu nhạy cảm.
"# nextcloud-docker" 
