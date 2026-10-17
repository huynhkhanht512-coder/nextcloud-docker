#!/usr/bin/env bash
# Sao lưu Nextcloud: (1) dump CSDL, (2) nén 2 named volume (nc_html, nc_data), (3) lưu bản sao .env.
# Kết quả nằm trong thư mục ./backup (BIND MOUNT/thư mục trên host nên lấy ra dễ dàng).
# Dùng:  ./scripts/backup.sh
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_env

TS="$(date +%Y%m%d-%H%M%S)"
KEEP_DAYS="$(env_get BACKUP_KEEP_DAYS 7)"
IMAGE="$(helper_image)"
DB_FILE="db_${TS}.sql.gz"
VOL_FILE="volumes_${TS}.tar.gz"
ENV_FILE="env_${TS}.bak"
MANIFEST="manifest_${TS}.sha256"

maintenance_on=0
cleanup() {
  if (( maintenance_on )); then
    log "Tắt maintenance mode..."
    occ maintenance:mode --off >/dev/null \
      || err "Không tắt được maintenance mode. Chạy tay: docker compose exec -u www-data app php occ maintenance:mode --off"
  fi
}
trap cleanup EXIT

log "Kiểm tra container app và db đang chạy..."
running="$(docker compose ps --status running --services)"
grep -qx app <<<"$running" || { err "Container app chưa chạy (docker compose up -d)"; exit 1; }
grep -qx db  <<<"$running" || { err "Container db chưa chạy (docker compose up -d)"; exit 1; }

log "Bật maintenance mode để dữ liệu nhất quán"
occ maintenance:mode --on >/dev/null
maintenance_on=1

log "Dump CSDL -> backup/${DB_FILE}"
docker compose exec -T db sh -c \
  'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-dump -uroot --single-transaction --routines --triggers --databases "$MARIADB_DATABASE"' \
  | gzip -9 > "$BACKUP_DIR/$DB_FILE"

log "Nén volume nc_html + nc_data -> backup/${VOL_FILE}"
# Container tạm mount volume ở chế độ chỉ-đọc (:ro) và thư mục backup (bind mount) ở chế độ ghi.
# tar trả về mã 1 nếu "file changed as we read it" – chấp nhận mã 1.
docker run --rm --entrypoint sh \
  -v nc_html:/src/html:ro -v nc_data:/src/data:ro -v "$BACKUP_DIR":/backup \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" -c "tar --numeric-owner -czpf /backup/${VOL_FILE} -C /src html data || [ \$? -eq 1 ]; chown \$HOST_UID:\$HOST_GID /backup/${VOL_FILE}"

log "Lưu bản sao .env (chứa mật khẩu – hãy bảo quản backup cẩn thận)"
cp .env "$BACKUP_DIR/$ENV_FILE"
chmod 600 "$BACKUP_DIR/$ENV_FILE"

log "Tạo checksum"
(cd "$BACKUP_DIR" && sha256sum "$DB_FILE" "$VOL_FILE" "$ENV_FILE" > "$MANIFEST")

log "Xóa bản sao lưu cũ hơn ${KEEP_DAYS} ngày"
find "$BACKUP_DIR" -maxdepth 1 -type f \
  \( -name 'db_*.sql.gz' -o -name 'volumes_*.tar.gz' -o -name 'env_*.bak' -o -name 'manifest_*.sha256' \) \
  -mtime +"$KEEP_DAYS" -print -delete

ok "Hoàn tất. Mã bản sao lưu: ${TS}"
ls -lh "$BACKUP_DIR"/*"${TS}"*
echo "Phục hồi bằng:  ./scripts/restore.sh ${TS}"
