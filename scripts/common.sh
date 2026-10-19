#!/usr/bin/env bash
# Hàm dùng chung cho backup.sh / restore.sh (được "source", không chạy trực tiếp).
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BACKUP_DIR="$ROOT_DIR/backup"
mkdir -p "$BACKUP_DIR"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()  { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[LỖI]\033[0m %s\n' "$*" >&2; }

# Đọc một biến từ .env (không dùng "source" vì giá trị có thể chứa dấu cách)
env_get() {
  local key="$1" default="${2:-}" val
  val="$(grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  val="${val%\"}"
  val="${val#\"}"
  printf '%s' "${val:-$default}"
}

require_env() {
  if [[ ! -f .env ]]; then
    err "Chưa có file .env. Hãy chạy: ./scripts/init-env.sh"
    exit 1
  fi
}

# Image dùng làm "container trợ giúp" (có GNU tar, đúng uid www-data=33 như container Nextcloud).
# Dùng lại image Nextcloud đã có sẵn nên không phải tải thêm image nào khác.
helper_image() { env_get NEXTCLOUD_IMAGE "nextcloud:apache"; }

# Chạy lệnh occ trong container app với quyền www-data
occ() { docker compose exec -T -u www-data app php occ "$@"; }

# Chờ container healthy (hoặc running nếu container không có healthcheck)
wait_healthy() {
  local name="$1" timeout="${2:-300}" waited=0 status="unknown"
  while (( waited < timeout )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo missing)"
    if [[ "$status" == "healthy" || "$status" == "running" ]]; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  err "Hết thời gian chờ $name (trạng thái cuối: $status)"
  return 1
}
