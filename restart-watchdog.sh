#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/immich"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$EUID" -ne 0 ]]; then
    echo "root 권한이 필요합니다: sudo $0"
    exit 1
fi

cp "$SCRIPT_DIR/watchdog.sh" "$INSTALL_DIR/watchdog.sh"
chmod +x "$INSTALL_DIR/watchdog.sh"
systemctl restart immich-watchdog.service

echo "와치독 재시작 완료"
systemctl status immich-watchdog.service --no-pager
