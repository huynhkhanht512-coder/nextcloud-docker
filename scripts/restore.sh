#!/usr/bin/env bash
# Phục hồi Nextcloud từ bản sao lưu tạo bởi backup.sh.
# Dùng:  ./scripts/restore.sh --list          liệt kê các bản sao lưu
#        ./scripts/restore.sh <mã>            ví dụ: ./scripts/restore.sh 20261010-153000
#        ./scripts/restore.sh -y <mã>         bỏ qua bước xác nhận (dùng trong CI)
# Có thể chạy cả khi volume đã bị xóa (docker compose down -v).
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_env

ASSUME_YES=0
if [[ "${1:-}" == "--list" ]]; then
  echo "Các bản sao lưu trong ./backup:"
  # shellcheck disable=SC2012
  ls -1 "$BACKUP_DIR"/volumes_*.tar.gz 2>/dev/null | sed -E 's|.*/volumes_(.*)\.tar\.gz|  \1|' || echo "  (chưa có)"
  exit 0
fi
if [[ "${1:-}" == "-y" ]]; then
  ASSUME_YES=1
  shift
fi

TS="${1:-}"
[[ -n "$TS" ]] || { err "Thiếu mã bản sao lưu. Xem: ./scripts/restore.sh --list"; exit 1; }

DB_FILE="db_${TS}.sql.gz"
VOL_FILE="volumes_${TS}.tar.gz"
ENV_FILE="env_${TS}.bak"
MANIFEST="manifest_${TS}.sha256"
IMAGE="$(helper_image)"

[[ -f "$BACKUP_DIR/$DB_FILE"  ]] || { err "Không thấy backup/$DB_FILE";  exit 1; }
[[ -f "$BACKUP_DIR/$VOL_FILE" ]] || { err "Không thấy backup/$VOL_FILE"; exit 1; }

if [[ -f "$BACKUP_DIR/$MANIFEST" ]]; then
  log "Kiểm tra checksum..."
  (cd "$BACKUP_DIR" && sha256sum -c "$MANIFEST")
fi

if [[ -f "$BACKUP_DIR/$ENV_FILE" ]] && ! diff -q .env "$BACKUP_DIR/$ENV_FILE" >/dev/null; then
  err "CẢNH BÁO: .env hiện tại khác .env lúc sao lưu. Mật khẩu DB/Redis không khớp sẽ làm Nextcloud không kết nối được."
  err "Nếu cần, khôi phục: cp backup/$ENV_FILE .env"
fi

if (( ! ASSUME_YES )); then
  echo "Thao tác này sẽ GHI ĐÈ toàn bộ CSDL và dữ liệu Nextcloud hiện tại bằng bản ${TS}."
  read -r -p "Gõ YES để tiếp tục: " ans
  [[ "$ans" == "YES" ]] || { echo "Đã hủy."; exit 1; }
fi

log "Tạo containers/volumes còn thiếu (chưa khởi động)"
docker compose up --no-start

log "Dừng app và cron"
docker compose stop app cron

log "Khởi động db và chờ sẵn sàng"
docker compose up -d db
wait_healthy nc_db 180

log "Phục hồi CSDL từ backup/${DB_FILE}"
docker compose exec -T db sh -c \
  'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -e "DROP DATABASE IF EXISTS \`$MARIADB_DATABASE\`; CREATE DATABASE \`$MARIADB_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"'
gunzip -c "$BACKUP_DIR/$DB_FILE" \
  | docker compose exec -T db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot'

log "Phục hồi volume nc_html + nc_data từ backup/${VOL_FILE}"
docker run --rm --entrypoint sh \
  -v nc_html:/dst/html -v nc_data:/dst/data -v "$BACKUP_DIR":/backup:ro \
  "$IMAGE" -c "find /dst/html /dst/data -mindepth 1 -delete && tar --numeric-owner -xzpf /backup/${VOL_FILE} -C /dst"

log "Khởi động toàn bộ stack"
docker compose up -d
wait_healthy nc_app 300

log "Tắt maintenance mode và cập nhật data fingerprint"
occ maintenance:mode --off || true
occ maintenance:data-fingerprint || true

ok "Phục hồi hoàn tất từ bản ${TS}."
