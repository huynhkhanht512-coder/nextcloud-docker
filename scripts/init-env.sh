#!/usr/bin/env bash
# Tạo file .env từ .env.example, tự sinh mật khẩu ngẫu nhiên và chuẩn bị thư mục bind mount.
# Dùng:  ./scripts/init-env.sh           (không ghi đè .env có sẵn)
#        ./scripts/init-env.sh --force   (tạo lại .env – mật khẩu cũ sẽ mất!)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ -f .env && $FORCE -eq 0 ]]; then
  echo ".env đã tồn tại, giữ nguyên. Dùng --force nếu muốn tạo lại (mật khẩu cũ sẽ mất)."
  exit 0
fi
[[ -f .env.example ]] || { echo "Thiếu .env.example"; exit 1; }

cp .env.example .env

# Sinh chuỗi hex ngẫu nhiên có độ dài $1 (không dùng pipe dài để tránh lỗi SIGPIPE với pipefail)
gen() { head -c "$(( $1 / 2 ))" /dev/urandom | od -An -vtx1 | tr -d ' \n'; }

set_var() { # $1=KEY  $2=VALUE
  sed -i "s|^$1=.*|$1=$2|" .env
}

set_var NEXTCLOUD_ADMIN_PASSWORD "$(gen 24)"
set_var MYSQL_ROOT_PASSWORD      "$(gen 32)"
set_var MYSQL_PASSWORD           "$(gen 32)"
set_var REDIS_PASSWORD           "$(gen 32)"
set_var GRAFANA_ADMIN_PASSWORD   "$(gen 24)"

# Thêm IP của máy vào danh sách trusted domains để truy cập được từ máy khác trong mạng LAN
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
set_var NEXTCLOUD_TRUSTED_DOMAINS "\"localhost${HOST_IP:+ $HOST_IP}\""

# Thư mục bind mount / backup. shared cần cho phép www-data (uid 33) trong container ghi vào.
mkdir -p shared backup config
chmod 777 shared            # CHỈ dùng cho demo; môi trường thật nên chown 33:33 shared
chmod 600 .env

echo "Đã tạo .env (quyền 600)."
echo "  - Trusted domains : localhost${HOST_IP:+ $HOST_IP}"
echo "  - Tài khoản admin : $(grep '^NEXTCLOUD_ADMIN_USER=' .env | cut -d= -f2-) / (mật khẩu trong .env)"
echo "Bước tiếp theo: docker compose up -d"
