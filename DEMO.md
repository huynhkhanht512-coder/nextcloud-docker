# Kịch bản demo từng bước

Mỗi phần có: **mục tiêu → lệnh → kết quả mong đợi → 📸 ảnh nên chụp cho báo cáo**.
Chạy mọi lệnh trong thư mục dự án (`cd nextcloud-docker`). Nên dùng máy Linux/VM (Ubuntu 22.04/24.04).

| Phần | Nội dung | Yêu cầu đề bài |
|---|---|---|
| 0 | Chuẩn bị môi trường | |
| 1 | Triển khai Docker Compose | Triển khai được docker compose |
| 2 | Quản lý trạng thái container | Quản lý được trạng thái containers |
| 3 | Volume và bind mount | Biết dùng volume và bind mount |
| 4 | Backup / Restore | (minh họa volume) |
| 5 | Bảo mật | Nâng cao – điểm cộng |
| 6 | Giám sát | Nâng cao – điểm cộng |
| 7 | CI/CD | Nâng cao – điểm cộng |
| 8 | Dọn dẹp | |

---

## Phần 0. Chuẩn bị

```bash
docker --version                 # Docker Engine 24+ là đủ
docker compose version           # Compose v2 (lệnh "docker compose", có dấu cách)
docker run --rm hello-world      # xác nhận user chạy được docker (nếu lỗi quyền: sudo usermod -aG docker $USER rồi đăng nhập lại)
free -h && df -h .               # RAM >= 2 GB (nên 4 GB), ổ đĩa trống >= 10 GB
```

📸 Ảnh: phiên bản Docker/Compose, cấu hình máy.

---

## Phần 1. Triển khai Docker Compose

**Mục tiêu:** dựng 4 service (app, cron, db, redis) bằng một file compose, có mạng riêng, healthcheck, thứ tự khởi động.

### 1.1 Sinh file cấu hình

```bash
./scripts/init-env.sh
ls -l .env                                  # quyền -rw------- (600)
grep -v PASSWORD .env                       # xem cấu hình, ẩn mật khẩu
```

### 1.2 Kiểm tra cú pháp và xem cấu hình đã "trải phẳng"

```bash
docker compose config -q && echo "Cú pháp hợp lệ"
docker compose config --services            # app, cron, db, redis
docker compose config | head -60            # biến .env đã được thay vào
```

### 1.3 Khởi động

```bash
docker compose up -d
docker compose ps                           # quan sát: db/redis (healthy) trước, app (health: starting) sau
watch -n 3 docker compose ps                # Ctrl+C để thoát; chờ nc_app thành (healthy)
docker compose logs -f --tail 30 app        # Ctrl+C để thoát
```

**Kết quả mong đợi:** thứ tự `db`, `redis` → `healthy` → `app` khởi động → `cron` khởi động sau cùng (nhờ `depends_on` + `condition: service_healthy`). `app` chuyển `healthy` sau 1-2 phút.

### 1.4 Đăng nhập

```bash
grep NEXTCLOUD_ADMIN .env                   # user: admin, mật khẩu: xem dòng _PASSWORD
```
Mở http://localhost:8080 (hoặc http://IP-máy:8080).

### 1.5 Kiểm tra mạng

```bash
docker network ls --filter name=nc_
docker network inspect nc_backend --format 'internal={{.Internal}}'     # internal=true
docker compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.Ports}}'  # chỉ app có port; db/redis KHÔNG publish
ss -ltn | grep -E ':(3306|6379)' || echo "3306/6379 không mở ra host (đúng ý đồ)"
```

📸 Ảnh: `docker compose ps` lúc đang `starting` và khi đã `healthy`; trang đăng nhập/giao diện Nextcloud; kết quả `network inspect`.

---

## Phần 2. Quản lý trạng thái container

**Mục tiêu:** thao tác vòng đời container, quan sát trạng thái/healthcheck, chứng minh `restart: unless-stopped`.

Các trạng thái: `created` → `running` ⇄ `paused` → `exited`; `restarting`; health: `starting` / `healthy` / `unhealthy`.

### 2.1 Quan sát

```bash
docker compose ps -a
docker compose top                                         # tiến trình bên trong từng container
docker stats --no-stream                                   # CPU / RAM / mạng
docker inspect -f '{{.Name}}  status={{.State.Status}}  health={{.State.Health.Status}}  restarts={{.RestartCount}}' nc_app nc_db nc_redis
```

### 2.2 Dừng và khởi động một service (mô phỏng sự cố CSDL)

```bash
docker compose stop db
docker compose ps -a                          # db: Exited
# Tải lại trang web -> lỗi / Internal Server Error
docker compose start db
docker compose ps                             # db: Up (healthy) sau ~30 giây
# Tải lại trang web -> hoạt động lại, dữ liệu còn nguyên
```

### 2.3 Restart và tạm dừng

```bash
docker compose restart app                    # khởi động lại, volume giữ nguyên dữ liệu
docker compose pause app                      # đóng băng tiến trình
docker compose ps                             # app: (Paused)
curl -m 5 -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/status.php || echo "Treo/timeout vì app đang pause"
docker compose unpause app
```

### 2.4 Chứng minh chính sách `restart: unless-stopped`

Mở **terminal 2** để theo dõi sự kiện:

```bash
docker events --filter 'label=com.docker.compose.project=nextcloud-stack' --filter 'type=container'
```

Ở terminal 1:

```bash
docker kill nc_redis                          # giả lập crash (tín hiệu SIGKILL)
sleep 5 && docker compose ps                  # redis tự chạy lại: "Up 4 seconds"
docker inspect -f 'RestartCount={{.RestartCount}}' nc_redis      # = 1

docker compose stop redis                     # DỪNG BẰNG TAY: chính sách restart không can thiệp
sleep 10 && docker compose ps -a              # redis vẫn Exited (đúng: "unless-stopped")
docker compose start redis
```

### 2.5 Log và thực thi lệnh trong container

```bash
docker compose logs --since 5m db
docker compose logs -f --tail 20 app
docker compose exec -u www-data app php occ status
docker compose exec db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -e "SHOW DATABASES;"'
```

### 2.6 `stop` khác `down` khác `down -v`

| Lệnh | Container | Network | Volume (dữ liệu) |
|---|---|---|---|
| `docker compose stop` | giữ lại (Exited) | giữ | giữ |
| `docker compose down` | xóa | xóa | **giữ** |
| `docker compose down -v` | xóa | xóa | **xóa → mất dữ liệu** |

```bash
docker compose pull && docker compose up -d     # cập nhật image: chỉ container có image mới bị tạo lại
docker compose up -d                            # chạy lại khi không đổi gì -> "Running", không làm gì (idempotent)
```

📸 Ảnh: `docker inspect` (status/health), `docker compose ps` khi db bị stop, terminal `docker events` lúc `docker kill`, `RestartCount=1`, redis vẫn Exited sau `stop`.

---

## Phần 3. Volume và bind mount

**Mục tiêu:** phân biệt named volume (Docker quản lý) và bind mount (thư mục/file trên host), kèm kiểm chứng.

### 3.1 Xem volume

```bash
docker volume ls --filter name=nc_
docker volume inspect nc_data --format '{{.Mountpoint}}'
sudo ls "$(docker volume inspect nc_data --format '{{.Mountpoint}}')"      # vị trí thật trên đĩa host
docker inspect nc_app --format '{{json .Mounts}}' | python3 -m json.tool | grep -E '"(Type|Source|Destination|Mode|RW)"'
```
Kết quả: `Type: volume` cho `nc_html`/`nc_data`, `Type: bind` cho `php-custom.ini` và `shared`.

### 3.2 Đưa dữ liệu vào bằng WebDAV (không cần thao tác chuột)

```bash
ADMIN_USER=$(grep '^NEXTCLOUD_ADMIN_USER=' .env | cut -d= -f2-)
ADMIN_PASS=$(grep '^NEXTCLOUD_ADMIN_PASSWORD=' .env | cut -d= -f2-)

echo "Dữ liệu demo $(date)" > demo.txt
curl -u "$ADMIN_USER:$ADMIN_PASS" -T demo.txt "http://localhost:8080/remote.php/dav/files/$ADMIN_USER/demo.txt"
docker compose exec app ls -l /var/www/html/data/$ADMIN_USER/files/       # thấy demo.txt trong volume nc_data
```
Đăng nhập web, thấy `demo.txt` trong mục Files.

### 3.3 Kiểm chứng dữ liệu bền vững qua vòng đời container

```bash
docker compose down                           # XÓA container + network, GIỮ volume
docker compose ps -a                          # trống
docker volume ls --filter name=nc_            # volume vẫn còn
docker compose up -d                          # container mới, dùng lại volume cũ
# chờ app healthy rồi:
curl -u "$ADMIN_USER:$ADMIN_PASS" "http://localhost:8080/remote.php/dav/files/$ADMIN_USER/demo.txt"   # nội dung vẫn còn
```

### 3.4 Bind mount thư mục `shared/` (đồng bộ hai chiều)

```bash
echo "Xin chào từ HOST" > shared/ghi-chu.txt
docker compose exec app cat /mnt/shared/ghi-chu.txt                        # container thấy ngay
docker compose exec app sh -c 'echo "Thêm một dòng từ CONTAINER" >> /mnt/shared/ghi-chu.txt'
cat shared/ghi-chu.txt                                                     # host thấy ngay
```

Hiển thị trong giao diện Nextcloud (tính năng External Storage kiểu Local):

```bash
docker compose exec -u www-data app php occ app:enable files_external
docker compose exec -u www-data app php occ files_external:create HostShared local null::null -c datadir=/mnt/shared
echo "Tạo thêm file trên host lúc $(date +%T)" > shared/file-moi.txt
```
Tải lại trang Files: xuất hiện thư mục **HostShared** chứa `ghi-chu.txt` và `file-moi.txt`.

### 3.5 Bind mount file cấu hình `php-custom.ini` (chỉ-đọc)

```bash
docker compose exec app php -r 'echo ini_get("upload_max_filesize"), PHP_EOL;'      # 512M
nano config/php-custom.ini                                                          # đổi upload_max_filesize = 1G
docker compose exec app cat /usr/local/etc/php/conf.d/zz-custom.ini                 # (nếu trình soạn thảo ghi in-place, đã thấy giá trị mới)
docker compose restart app                                                          # restart để nạp lại cấu hình PHP
docker compose exec app php -r 'echo ini_get("upload_max_filesize"), PHP_EOL;'      # 1G

# Container KHÔNG ghi được vì gắn :ro
docker compose exec app sh -c 'echo ";x" >> /usr/local/etc/php/conf.d/zz-custom.ini'   # Read-only file system
```
> Lưu ý để đưa vào báo cáo: bind mount **một file đơn lẻ** gắn theo inode. Trình soạn thảo thay file bằng file mới (ví dụ `sed -i`, một số cấu hình vim) sẽ tạo inode khác, container vẫn thấy bản cũ cho đến khi `docker compose restart app`. Bind mount **thư mục** (như `shared/`) không gặp vấn đề này.

### 3.6 Bảng so sánh (dùng trong báo cáo)

| Tiêu chí | Named volume | Bind mount |
|---|---|---|
| Nơi lưu | Do Docker quản lý (`/var/lib/docker/volumes/...`) | Đường dẫn bất kỳ trên host (`./shared`) |
| Tạo / quản lý | `docker volume create/ls/inspect/rm` | Tự tạo thư mục, tự quản lý quyền |
| Khi `down` | Giữ | Giữ (nằm trên host) |
| Khi `down -v` | **Bị xóa** | Không bị xóa |
| Phù hợp | Dữ liệu ứng dụng: CSDL, file người dùng | Cấu hình, mã nguồn đang phát triển, lấy file ra/vào host |
| Hiệu năng / di động | Tốt, độc lập hệ điều hành host | Phụ thuộc cấu trúc thư mục + quyền của host |
| Trong dự án | `nc_db`, `nc_html`, `nc_data` | `php-custom.ini`, `shared/`, `Caddyfile`, `monitoring/*` |

📸 Ảnh: `docker volume ls/inspect`, `.Mounts` (volume vs bind), file còn sau `down`/`up`, host↔container cùng file, thư mục HostShared trên web, `ini_get` trước/sau, lỗi Read-only.

---

## Phần 4. Backup / Restore volume

**Mục tiêu:** sao lưu dữ liệu, mô phỏng mất sạch dữ liệu, phục hồi.

### 4.1 Sao lưu

```bash
./scripts/backup.sh
ls -lh backup/
```
Script làm: bật maintenance mode → `mariadb-dump` → nén 2 volume bằng container tạm → lưu `.env` + checksum → tắt maintenance mode → xóa bản cũ quá `BACKUP_KEEP_DAYS` ngày.

Cơ chế nén volume (để giải thích trong báo cáo):

```bash
docker run --rm -v nc_data:/src:ro -v "$PWD/backup":/backup nextcloud:apache \
  tar -czpf /backup/nc_data_thucong.tar.gz -C /src .
```
(container tạm gắn **volume** làm nguồn và **bind mount `./backup`** làm đích)

### 4.2 Mô phỏng thảm họa

```bash
docker compose down -v                                   # xóa luôn volume
docker volume ls --filter name=nc_                       # trống
docker compose up -d                                     # dựng lại -> Nextcloud cài mới hoàn toàn
# chờ healthy, rồi kiểm tra: demo.txt đã mất
curl -u "$ADMIN_USER:$ADMIN_PASS" -o /dev/null -w '%{http_code}\n' "http://localhost:8080/remote.php/dav/files/$ADMIN_USER/demo.txt"   # 404
```

### 4.3 Phục hồi

```bash
./scripts/restore.sh --list                              # xem mã bản sao lưu, ví dụ 20261010-153000
./scripts/restore.sh 20261010-153000                     # gõ YES để xác nhận
curl -u "$ADMIN_USER:$ADMIN_PASS" "http://localhost:8080/remote.php/dav/files/$ADMIN_USER/demo.txt"   # nội dung đã quay lại
```
Đăng nhập web: tài khoản, file và cài đặt như lúc sao lưu.

### 4.4 Tự động hóa (tùy chọn)

```bash
crontab -e
# 02:00 mỗi ngày:
0 2 * * * cd /đường/dẫn/nextcloud-docker && ./scripts/backup.sh >> backup/backup.log 2>&1
```

📸 Ảnh: kết quả `backup.sh`, `ls -lh backup`, 404 sau khi mất dữ liệu, kết quả `restore.sh`, file quay lại.

---

## Phần 5. Nâng cao – Bảo mật

**Mục tiêu:** HTTPS, thu hẹp bề mặt tấn công, giới hạn tài nguyên, quét lỗ hổng.

### 5.1 Bật overlay bảo mật

Sửa `.env`:
```
COMPOSE_FILE=docker-compose.yml:docker-compose.security.yml
NC_BIND_IP=127.0.0.1
```
```bash
docker compose up -d                       # tạo thêm nc_caddy, áp dụng giới hạn cho các container còn lại
docker compose ps
```

### 5.2 HTTPS qua Caddy

```bash
curl -kI https://localhost                                                    # -k: bỏ qua cảnh báo chứng chỉ tự ký
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
curl --cacert caddy-root.crt -sS https://localhost/status.php                 # xác thực được khi tin CA nội bộ
```
Import `caddy-root.crt` vào trình duyệt/hệ điều hành để hết cảnh báo; mở https://localhost.
Nếu truy cập bằng IP máy: đặt `NC_DOMAIN=<IP>` trong `.env`, thêm IP vào trusted_domains
(`docker compose exec -u www-data app php occ config:system:set trusted_domains 3 --value=<IP>`), rồi `docker compose up -d`.

### 5.3 Bề mặt tấn công

```bash
docker compose ps --format 'table {{.Name}}\t{{.Ports}}'
ss -ltn | grep -E ':(80|443|8080|3306|6379)\b'
```
Kỳ vọng: 80/443 mở (Caddy), 8080 chỉ ở `127.0.0.1`, 3306/6379 không mở.

### 5.4 Mạng backend nội bộ (db/redis không ra Internet)

```bash
docker compose exec db bash -c 'timeout 3 bash -c "echo > /dev/tcp/1.1.1.1/443" && echo "RA ĐƯỢC INTERNET" || echo "BỊ CHẶN (đúng ý đồ)"'
docker compose exec app bash -c 'timeout 3 bash -c "echo > /dev/tcp/1.1.1.1/443" && echo "app RA ĐƯỢC INTERNET (cần cho app store)" || echo "bị chặn"'
```

### 5.4b Redis yêu cầu mật khẩu

```bash
docker compose exec redis redis-cli ping                                     # NOAUTH Authentication required
docker compose exec redis sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'     # PONG
```

### 5.5 Filesystem chỉ-đọc, bỏ capabilities, giới hạn tài nguyên

```bash
docker compose exec redis touch /test                                        # Read-only file system
docker inspect -f 'ReadOnly={{.HostConfig.ReadonlyRootfs}} CapDrop={{.HostConfig.CapDrop}} SecurityOpt={{.HostConfig.SecurityOpt}}' nc_redis nc_caddy
docker stats --no-stream                                                     # cột MEM USAGE / LIMIT có giới hạn
```

### 5.6 Quản lý bí mật

```bash
ls -l .env                                  # -rw------- (chỉ chủ sở hữu đọc được)
git check-ignore -v .env                    # .env nằm trong .gitignore (cần: git init trước)
```

### 5.7 Quét lỗ hổng image bằng Trivy

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy_cache:/root/.cache aquasec/trivy:latest \
  image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed nextcloud:apache
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy_cache:/root/.cache aquasec/trivy:latest \
  image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed mariadb:11.4
```
Giải thích kết quả (số lượng HIGH/CRITICAL, bản vá có sẵn không) và đề xuất: ghim phiên bản, cập nhật định kỳ (`docker compose pull`), dùng image `-alpine` khi phù hợp.

Trong giao diện Nextcloud: *Administration settings → Overview* để xem các cảnh báo bảo mật/cấu hình.

### 5.8 Tổng hợp biện pháp (đưa vào báo cáo)

| Rủi ro | Biện pháp | Nơi cấu hình |
|---|---|---|
| Nghe lén đường truyền | HTTPS qua Caddy | `docker-compose.security.yml`, `Caddyfile` |
| Lộ cổng CSDL/Redis | không publish port, mạng `internal` | `docker-compose.yml` |
| Lộ mật khẩu trong Git | `.env` (600) + `.gitignore`, mật khẩu ngẫu nhiên, Redis `requirepass` | `init-env.sh` |
| Container chiếm hết tài nguyên | `mem_limit`, `cpus`, `pids_limit` | `docker-compose.security.yml` |
| Leo thang đặc quyền | `no-new-privileges`, `cap_drop`, `read_only` | `docker-compose.security.yml` |
| Image có lỗ hổng | ghim phiên bản + quét Trivy trong CI | `ci-cd.yml` |

📸 Ảnh: trang HTTPS (ổ khóa), `ss -ltn`, thử kết nối Internet từ db bị chặn, `NOAUTH`, `Read-only file system`, `docker stats` có LIMIT, kết quả Trivy.

---

## Phần 6. Nâng cao – Giám sát

**Mục tiêu:** theo dõi CPU/RAM/mạng từng container, có dashboard và cảnh báo.

### 6.1 Bật overlay giám sát

Sửa `.env`:
```
COMPOSE_FILE=docker-compose.yml:docker-compose.security.yml:docker-compose.monitoring.yml
```
```bash
docker compose up -d
docker compose ps                           # thêm nc_cadvisor, nc_prometheus, nc_grafana
```

### 6.2 Prometheus

Mở http://localhost:9090/targets → job `cadvisor` ở trạng thái **UP**. Thử truy vấn tại *Graph*:
```
sum by (name) (rate(container_cpu_usage_seconds_total{name=~"nc_.+"}[1m])) * 100
container_memory_working_set_bytes{name=~"nc_.+"}
```

### 6.3 Grafana

Mở http://localhost:3000, đăng nhập `admin` / mật khẩu `grep GRAFANA_ADMIN_PASSWORD .env`.
*Dashboards → Nextcloud stack – Docker containers* (đã dựng sẵn): số container đang chạy, uptime, CPU, RAM, mạng RX/TX.

### 6.4 Sinh tải để thấy biểu đồ thay đổi

```bash
# Tải CPU 60 giây trong container app
docker compose exec -T app timeout 60 sh -c 'while :; do :; done'

# Tải mạng + đĩa: upload file 300 MB
dd if=/dev/urandom of=big.bin bs=1M count=300
curl -u "$ADMIN_USER:$ADMIN_PASS" -T big.bin "http://localhost:8080/remote.php/dav/files/$ADMIN_USER/big.bin"
```
(nếu đang dùng HTTPS với `NC_BIND_IP=127.0.0.1`, URL 8080 vẫn dùng được từ chính máy chủ; Nextcloud cần `OVERWRITEPROTOCOL` chỉ ảnh hưởng link sinh ra, không ảnh hưởng WebDAV.)

### 6.5 Cảnh báo khi container chết

```bash
docker compose stop db                      # dừng bằng tay nên không tự restart
# chờ ~1-2 phút rồi mở http://localhost:9090/alerts : NextcloudDbDown chuyển Pending -> Firing
docker compose start db                     # cảnh báo tự tắt
```
Quan sát trên dashboard: uptime của `nc_db` tụt về 0 sau khi `kill` (`docker kill nc_db`, container tự restart).

### 6.6 Giám sát nhẹ không cần Grafana

```bash
docker stats                                # theo thời gian thực
docker events --filter 'type=container'     # sự kiện start/die/health_status
docker inspect -f '{{.State.Health.Status}}' nc_app
```

📸 Ảnh: trang Targets (UP), dashboard Grafana lúc bình thường và lúc có tải, trang Alerts ở trạng thái Firing.

---

## Phần 7. Nâng cao – CI/CD (GitHub Actions)

**Mục tiêu:** mỗi lần push/PR, pipeline tự kiểm tra cấu hình, quét lỗ hổng, dựng stack thật và thử backup/restore; push lên `main` thì tự triển khai.

Pipeline (file `.github/workflows/ci-cd.yml`):

```
push/PR ─► validate ─┬─► scan-images (Trivy)
                     └─► smoke-test (up -> HTTP -> backup -> down -v -> restore -> kiểm tra)
                              └─► deploy (chỉ nhánh main, qua SSH, cần duyệt tay)
```

### 7.1 Đưa mã lên GitHub

```bash
git init -b main
git add .
git status                                   # kiểm tra: KHÔNG có .env trong danh sách
git commit -m "Nextcloud docker stack"
git remote add origin https://github.com/<tài-khoản>/<repo>.git
git push -u origin main
```
Vào tab **Actions** → xem các job chạy. 📸 Ảnh: sơ đồ pipeline màu xanh, log job `smoke-test` (đoạn "Nội dung sau restore").

### 7.2 Chứng minh pipeline chặn lỗi

```bash
git switch -c thu-nghiem-loi
# cố ý làm hỏng docker-compose.yml, ví dụ xóa một dấu ":" ở dòng "image:"
git commit -am "Cố ý gây lỗi" && git push -u origin thu-nghiem-loi
```
Mở Pull Request → job `validate` **đỏ**, nhánh không merge được. 📸 Ảnh: pipeline lỗi.

### 7.3 Chuẩn bị máy chủ để deploy (Ubuntu/VPS)

```bash
# Trên máy chủ
git clone https://github.com/<tài-khoản>/<repo>.git ~/nextcloud-docker && cd ~/nextcloud-docker
./scripts/init-env.sh && docker compose up -d

# Trên máy cá nhân: tạo khóa SSH riêng cho CI
ssh-keygen -t ed25519 -f deploy_key -N "" -C "github-actions"
ssh-copy-id -i deploy_key.pub <user>@<host>
ssh-keyscan -H <host>                        # kết quả dùng cho secret DEPLOY_KNOWN_HOSTS
```
Trên GitHub → *Settings → Secrets and variables → Actions*, tạo:

| Secret | Giá trị |
|---|---|
| `DEPLOY_HOST` | IP/tên miền máy chủ |
| `DEPLOY_USER` | user SSH |
| `DEPLOY_PATH` | `/home/<user>/nextcloud-docker` |
| `DEPLOY_SSH_KEY` | toàn bộ nội dung file `deploy_key` (khóa riêng) |
| `DEPLOY_KNOWN_HOSTS` | kết quả `ssh-keyscan -H <host>` |

*Settings → Environments → New environment `production`* → bật **Required reviewers** để phải bấm duyệt trước khi deploy.

### 7.4 Chạy deploy

```bash
# sửa nhỏ (ví dụ đổi upload_max_filesize trong config/php-custom.ini), rồi:
git commit -am "Đổi giới hạn upload" && git push
```
Trên GitHub: duyệt môi trường `production` → job `deploy` chạy: `git pull` → `backup.sh` → `docker compose pull` → `up -d` → `ps`.
Kiểm tra trên máy chủ: `git log -1 --oneline && docker compose ps`.

> Máy chủ nằm sau NAT/không có IP công khai (VM ở nhà)? Cài *self-hosted runner* trên chính máy đó, đổi `runs-on: self-hosted` ở job `deploy` và thay lệnh `ssh` bằng chạy trực tiếp các lệnh `docker compose ...`.

📸 Ảnh: màn hình duyệt production, log job deploy, `docker compose ps` trên máy chủ sau deploy.

---

## Phần 8. Dọn dẹp

```bash
docker compose down -v                       # xóa container, network, volume (MẤT dữ liệu; đã có backup/ trên host)
docker image prune -a                        # xóa image không dùng (tùy chọn)
rm -f demo.txt big.bin caddy-root.crt
```

---

## Gợi ý ánh xạ vào cấu trúc báo cáo

1. **Giới thiệu, mục tiêu** – bài toán lưu trữ cá nhân, lý do chọn Nextcloud (README: Kiến trúc).
2. **Thiết kế** – sơ đồ container/network/volume (README), giải thích từng service.
3. **Triển khai Compose** – Phần 1.
4. **Quản lý trạng thái** – Phần 2 (bảng trạng thái, restart policy, healthcheck, `stop` vs `down`).
5. **Volume / bind mount** – Phần 3 + 4 (bảng so sánh, kiểm chứng bền vững, backup/restore).
6. **Nâng cao** – Phần 5 (bảo mật), 6 (giám sát), 7 (CI/CD).
7. **Kết luận** – bài học, hạn chế (README: Giới hạn đã biết), hướng phát triển (Docker secrets, Alertmanager, HA/Swarm/Kubernetes).
