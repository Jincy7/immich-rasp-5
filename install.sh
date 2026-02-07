#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# immich-rasp-5 installer
# Raspberry Pi 5에서 Immich를 셀프호스팅하기 위한 설치 스크립트
###############################################################################

LOG_FILE="/tmp/immich-install.log"
INSTALL_DIR="/opt/immich"
MOUNT_POINT="/mnt/immich-external"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PORT=2283

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 설정: stdout + 로그 파일에 동시 기록
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo -e "\n${RED}[ERROR] 스크립트 실패 (line $LINENO). 로그 확인: $LOG_FILE${NC}"; exit 1' ERR

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}==== $* ====${NC}\n"; }

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -rp "$prompt [y/N]: " answer
        answer="${answer:-n}"
    fi
    [[ "$answer" =~ ^[Yy] ]]
}

###############################################################################
# Phase 1: 사전 검증
###############################################################################
check_prerequisites() {
    log_step "Phase 1: 사전 검증"

    # root 권한 확인
    if [[ $EUID -ne 0 ]]; then
        log_error "이 스크립트는 root 권한이 필요합니다. sudo ./install.sh 로 실행하세요."
        exit 1
    fi

    # 아키텍처 확인
    local arch
    arch="$(uname -m)"
    if [[ "$arch" != "aarch64" ]]; then
        log_error "aarch64 아키텍처가 필요합니다. 현재: $arch"
        log_error "64비트 Raspberry Pi OS를 사용하세요."
        exit 1
    fi
    log_info "아키텍처: $arch ✓"

    # Debian 계열 확인
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
            log_warn "Debian 계열 OS가 아닙니다 (${ID:-unknown}). 호환성 문제가 있을 수 있습니다."
        fi
        if [[ "${VERSION_CODENAME:-}" != "bookworm" ]]; then
            log_warn "Bookworm이 아닙니다 (${VERSION_CODENAME:-unknown}). 계속 진행합니다."
        fi
        log_info "OS: ${PRETTY_NAME:-unknown}"
    fi

    # RAM 확인
    local ram_kb
    ram_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
    local ram_mb=$((ram_kb / 1024))
    if [[ $ram_mb -lt 2048 ]]; then
        log_error "RAM이 부족합니다 (${ram_mb}MB). 최소 2GB 필요."
        exit 1
    elif [[ $ram_mb -lt 4096 ]]; then
        log_warn "RAM: ${ram_mb}MB — 4GB 이상 권장합니다."
    else
        log_info "RAM: ${ram_mb}MB ✓"
    fi

    # 디스크 여유 공간 확인 (루트 파티션)
    local free_kb
    free_kb="$(df / | tail -1 | awk '{print $4}')"
    local free_gb=$((free_kb / 1024 / 1024))
    if [[ $free_gb -lt 5 ]]; then
        log_error "루트 파티션 여유 공간 부족 (${free_gb}GB). 최소 5GB 필요."
        exit 1
    fi
    log_info "루트 파티션 여유: ${free_gb}GB ✓"

    # 인터넷 연결 확인
    if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        log_error "인터넷 연결을 확인하세요."
        exit 1
    fi
    log_info "인터넷 연결 ✓"

    log_info "Phase 1 완료: 사전 검증 통과"
}

###############################################################################
# Phase 2: Docker 설치
###############################################################################
install_docker() {
    log_step "Phase 2: Docker 설치"

    local need_install=false

    if command -v docker &>/dev/null; then
        local docker_version
        docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")"
        local major_version
        major_version="$(echo "$docker_version" | cut -d. -f1)"

        if [[ "$major_version" -ge 25 ]]; then
            log_info "Docker $docker_version 이미 설치됨 ✓"
        else
            log_warn "Docker $docker_version — v25 이상 필요. 업그레이드합니다."
            need_install=true
        fi
    else
        log_info "Docker가 설치되어 있지 않습니다. 설치합니다."
        need_install=true
    fi

    if $need_install; then
        log_info "Docker 공식 설치 스크립트 실행 중..."
        curl -fsSL https://get.docker.com | sh
        log_info "Docker 설치 완료"
    fi

    # SUDO_USER를 docker 그룹에 추가
    if [[ -n "${SUDO_USER:-}" ]]; then
        if ! groups "$SUDO_USER" | grep -q docker; then
            usermod -aG docker "$SUDO_USER"
            log_info "$SUDO_USER 를 docker 그룹에 추가했습니다."
            log_warn "그룹 변경 적용을 위해 설치 완료 후 재로그인하세요."
        fi
    fi

    # docker compose 확인
    if ! docker compose version &>/dev/null; then
        log_error "docker compose를 사용할 수 없습니다."
        exit 1
    fi
    log_info "Docker Compose: $(docker compose version --short) ✓"

    log_info "Phase 2 완료: Docker 준비됨"
}

###############################################################################
# Phase 3: 외장하드 설정
###############################################################################
setup_external_hdd() {
    log_step "Phase 3: 외장하드 설정"

    # 이미 마운트되어 있는지 확인
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "$MOUNT_POINT 이미 마운트되어 있습니다."
        if ask_yes_no "기존 마운트를 그대로 사용하시겠습니까?"; then
            log_info "기존 마운트 재사용"
            mkdir -p "${MOUNT_POINT}/library"
            chmod 755 "$MOUNT_POINT"
            log_info "Phase 3 완료: 외장하드 (기존 마운트 사용)"
            return 0
        fi
    fi

    # USB 디스크 감지
    echo ""
    log_info "연결된 USB 디스크 목록:"
    echo ""
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL | grep -E "disk|part" || true
    echo ""

    local disk
    read -rp "사용할 디스크를 입력하세요 (예: sda): " disk

    if [[ -z "$disk" ]]; then
        log_error "디스크를 입력하지 않았습니다."
        exit 1
    fi

    local device="/dev/${disk}"
    if [[ ! -b "$device" ]]; then
        log_error "$device 를 찾을 수 없습니다."
        exit 1
    fi

    # 파티션 결정 (sda1이 있으면 사용, 없으면 전체 디스크)
    local partition
    if [[ -b "${device}1" ]]; then
        partition="${device}1"
    else
        partition="$device"
    fi

    # 이미 마운트된 파티션 확인
    local current_mount
    current_mount="$(lsblk -no MOUNTPOINT "$partition" 2>/dev/null | head -1)"
    if [[ -n "$current_mount" ]]; then
        log_warn "$partition 이 $current_mount 에 마운트되어 있습니다."
        if ask_yes_no "마운트 해제 후 $MOUNT_POINT 에 다시 마운트하시겠습니까?" "n"; then
            umount "$partition"
        else
            log_error "설치를 중단합니다. 외장하드를 수동으로 설정하세요."
            exit 1
        fi
    fi

    # 파일시스템 확인 및 포맷
    local fstype
    fstype="$(lsblk -no FSTYPE "$partition" 2>/dev/null | head -1)"
    if [[ "$fstype" != "ext4" ]]; then
        log_warn "$partition 의 파일시스템: ${fstype:-없음}"
        echo -e "${RED}주의: 포맷하면 디스크의 모든 데이터가 삭제됩니다!${NC}"
        if ask_yes_no "EXT4로 포맷하시겠습니까?" "n"; then
            log_info "$partition 을 EXT4로 포맷합니다..."
            mkfs.ext4 -F "$partition"
            log_info "포맷 완료"
        else
            log_error "EXT4 파일시스템이 필요합니다. 수동으로 포맷 후 다시 실행하세요."
            exit 1
        fi
    else
        log_info "파일시스템: EXT4 ✓"
    fi

    # 마운트
    mkdir -p "$MOUNT_POINT"
    mount "$partition" "$MOUNT_POINT"
    log_info "$partition → $MOUNT_POINT 마운트 완료"

    # fstab에 UUID 기반 항목 추가
    local uuid
    uuid="$(blkid -s UUID -o value "$partition")"
    if [[ -z "$uuid" ]]; then
        log_error "UUID를 가져올 수 없습니다."
        exit 1
    fi

    if ! grep -q "$uuid" /etc/fstab; then
        echo "UUID=$uuid $MOUNT_POINT ext4 defaults,nofail,x-systemd.device-timeout=30 0 2" >> /etc/fstab
        log_info "fstab 항목 추가 (UUID=$uuid)"
    else
        log_info "fstab에 이미 등록되어 있습니다 ✓"
    fi

    # 디렉토리 생성 및 권한
    mkdir -p "${MOUNT_POINT}/library"
    chmod 755 "$MOUNT_POINT"

    log_info "Phase 3 완료: 외장하드 설정됨 ($MOUNT_POINT)"
}

###############################################################################
# Phase 4: Immich 설정 파일 생성
###############################################################################
setup_immich_files() {
    log_step "Phase 4: Immich 설정 파일 생성"

    # 설치 디렉토리 생성
    mkdir -p "$INSTALL_DIR"

    # docker-compose.yml 복사
    cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
    log_info "docker-compose.yml 복사 완료"

    # .env 파일 생성
    local env_file="$INSTALL_DIR/.env"

    if [[ -f "$env_file" ]]; then
        log_warn ".env 파일이 이미 존재합니다."
        if ! ask_yes_no "기존 .env를 덮어쓰시겠습니까?" "n"; then
            log_info "기존 .env 유지"
            log_info "Phase 4 완료: 설정 파일 (기존 .env 유지)"
            return 0
        fi
        cp "$env_file" "${env_file}.backup.$(date +%Y%m%d%H%M%S)"
        log_info "기존 .env 백업 완료"
    fi

    # DB 비밀번호 자동 생성
    local db_password
    db_password="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"

    # 타임존 자동 감지
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo "Asia/Seoul")"

    # 포트 설정
    local port="$DEFAULT_PORT"
    echo ""
    read -rp "Immich 포트 (기본: $DEFAULT_PORT): " user_port
    if [[ -n "$user_port" ]]; then
        port="$user_port"
    fi

    # ML 활성화 여부 결정
    local ml_line="# COMPOSE_PROFILES=ml"
    local ram_kb
    ram_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
    local ram_mb=$((ram_kb / 1024))

    echo ""
    if [[ $ram_mb -ge 8192 ]]; then
        log_info "RAM ${ram_mb}MB — ML 서비스 활성화를 권장합니다."
        if ask_yes_no "ML(얼굴 인식/검색) 서비스를 활성화하시겠습니까?"; then
            ml_line="COMPOSE_PROFILES=ml"
            log_info "ML 서비스 활성화됨"
        fi
    else
        log_warn "RAM ${ram_mb}MB — ML 서비스 비활성화를 권장합니다."
        if ask_yes_no "그래도 ML 서비스를 활성화하시겠습니까?" "n"; then
            ml_line="COMPOSE_PROFILES=ml"
            log_warn "ML 서비스 활성화됨 (메모리 부족 주의)"
        fi
    fi

    # .env 파일 작성
    cat > "$env_file" <<EOF
UPLOAD_LOCATION=${MOUNT_POINT}/library
DB_DATA_LOCATION=${INSTALL_DIR}/postgres
IMMICH_VERSION=release
IMMICH_HOST=0.0.0.0
IMMICH_PORT=${port}
DB_PASSWORD=${db_password}
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
TZ=${tz}
${ml_line}
EOF

    chmod 600 "$env_file"
    log_info ".env 파일 생성 완료 (권한: 600)"

    # DB 디렉토리 생성
    mkdir -p "${INSTALL_DIR}/postgres"

    log_info "Phase 4 완료: 설정 파일 생성됨 ($INSTALL_DIR)"
}

###############################################################################
# Phase 5: 서비스 시작
###############################################################################
start_immich() {
    log_step "Phase 5: Immich 서비스 시작"

    cd "$INSTALL_DIR"

    # 이미지 다운로드
    log_info "Docker 이미지 다운로드 중... (시간이 걸릴 수 있습니다)"
    docker compose pull
    log_info "이미지 다운로드 완료"

    # 서비스 시작
    log_info "서비스 시작 중..."
    docker compose up -d
    log_info "컨테이너 시작됨"

    # 헬스체크
    local port
    port="$(grep IMMICH_PORT "$INSTALL_DIR/.env" | cut -d= -f2)"
    port="${port:-$DEFAULT_PORT}"

    log_info "Immich 서버 응답 대기 중..."
    local max_retries=30
    local retry=0
    while [[ $retry -lt $max_retries ]]; do
        if curl -sf "http://localhost:${port}/api/server/ping" &>/dev/null; then
            log_info "Immich 서버 응답 확인 ✓"
            break
        fi
        retry=$((retry + 1))
        echo -n "."
        sleep 10
    done
    echo ""

    if [[ $retry -ge $max_retries ]]; then
        log_warn "서버 응답 대기 시간 초과. 컨테이너가 시작 중일 수 있습니다."
        log_warn "docker compose -f $INSTALL_DIR/docker-compose.yml logs 로 로그를 확인하세요."
    fi

    log_info "Phase 5 완료: 서비스 시작됨"
}

###############################################################################
# Phase 6: 방화벽 설정
###############################################################################
configure_firewall() {
    log_step "Phase 6: 방화벽 설정"

    # UFW 설치
    if ! command -v ufw &>/dev/null; then
        log_info "UFW 설치 중..."
        apt-get update -qq
        apt-get install -y -qq ufw
    fi

    # 로컬 서브넷 자동 감지
    local gateway
    gateway="$(ip route | grep default | awk '{print $3}' | head -1)"
    if [[ -z "$gateway" ]]; then
        log_warn "기본 게이트웨이를 감지할 수 없습니다. 방화벽 설정을 건너뜁니다."
        return 0
    fi

    local subnet
    local iface
    iface="$(ip route | grep default | awk '{print $5}' | head -1)"
    subnet="$(ip -o -f inet addr show "$iface" | awk '{print $4}')"

    if [[ -z "$subnet" ]]; then
        log_warn "서브넷을 감지할 수 없습니다. 방화벽 설정을 건너뜁니다."
        return 0
    fi

    log_info "감지된 로컬 서브넷: $subnet"

    local port
    port="$(grep IMMICH_PORT "$INSTALL_DIR/.env" | cut -d= -f2)"
    port="${port:-$DEFAULT_PORT}"

    # UFW 규칙 설정
    ufw --force reset &>/dev/null || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow from "$subnet" to any port "$port" proto tcp comment "Immich"

    # UFW 활성화
    echo "y" | ufw enable
    log_info "방화벽 설정 완료:"
    log_info "  - SSH: 허용"
    log_info "  - Immich (포트 $port): $subnet 에서만 허용"
    log_info "  - 기타: 차단"

    ufw status verbose

    log_info "Phase 6 완료: 방화벽 설정됨"
}

###############################################################################
# Phase 7: 와치독 설정
###############################################################################
setup_watchdog() {
    log_step "Phase 7: 와치독 서비스 설정"

    # watchdog.sh 복사
    cp "$SCRIPT_DIR/watchdog.sh" "$INSTALL_DIR/watchdog.sh"
    chmod +x "$INSTALL_DIR/watchdog.sh"
    log_info "watchdog.sh 복사 완료"

    # 실제 사용자의 Desktop 경로 결정
    local real_user="${SUDO_USER:-$(whoami)}"
    local desktop_dir="/home/${real_user}/Desktop"

    # Desktop 디렉토리가 없으면 바탕화면(한글)도 확인
    if [[ ! -d "$desktop_dir" ]]; then
        local desktop_kr="/home/${real_user}/바탕화면"
        if [[ -d "$desktop_kr" ]]; then
            desktop_dir="$desktop_kr"
        else
            # 둘 다 없으면 Desktop 생성
            mkdir -p "$desktop_dir"
            chown "${real_user}:" "$desktop_dir"
        fi
    fi

    local log_path="${desktop_dir}/immich-watchdog.log"

    # systemd 서비스 파일 생성
    cat > /etc/systemd/system/immich-watchdog.service <<EOF
[Unit]
Description=Immich Watchdog - 서비스 감시 및 자동 복구
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=simple
Environment=WATCHDOG_LOG=${log_path}
ExecStart=${INSTALL_DIR}/watchdog.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    # systemd 등록 및 활성화
    systemctl daemon-reload
    systemctl enable immich-watchdog.service
    systemctl start immich-watchdog.service
    log_info "와치독 서비스 등록 및 시작 완료"
    log_info "  로그 위치: $log_path"
    log_info "  서비스 상태: systemctl status immich-watchdog"

    log_info "Phase 7 완료: 와치독 설정됨"
}

###############################################################################
# Phase 8: 완료 안내
###############################################################################
show_status() {
    log_step "Phase 8: 설치 완료"

    local ip_addr
    ip_addr="$(hostname -I | awk '{print $1}')"
    local port
    port="$(grep IMMICH_PORT "$INSTALL_DIR/.env" | cut -d= -f2)"
    port="${port:-$DEFAULT_PORT}"

    echo ""
    echo "=============================================="
    echo "  Immich 설치가 완료되었습니다!"
    echo "=============================================="
    echo ""
    echo "  접속 URL:  http://${ip_addr}:${port}"
    echo ""
    echo "  설정 파일: $INSTALL_DIR/.env"
    echo "  사진 저장: $MOUNT_POINT/library"
    echo "  DB 저장:   $INSTALL_DIR/postgres"
    echo "  로그 파일: $LOG_FILE"
    echo ""
    echo "  유용한 명령어:"
    echo "    서비스 상태:   docker compose -f $INSTALL_DIR/docker-compose.yml ps"
    echo "    로그 확인:     docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
    echo "    서비스 중지:   docker compose -f $INSTALL_DIR/docker-compose.yml down"
    echo "    서비스 시작:   docker compose -f $INSTALL_DIR/docker-compose.yml up -d"
    echo "    업데이트:      docker compose -f $INSTALL_DIR/docker-compose.yml pull && \\"
    echo "                   docker compose -f $INSTALL_DIR/docker-compose.yml up -d"
    echo "    와치독 상태:   systemctl status immich-watchdog"
    echo "    와치독 로그:   바탕화면/immich-watchdog.log"
    echo ""
    echo "=============================================="
    echo ""

    # 서비스 상태 표시
    log_info "현재 서비스 상태:"
    docker compose -f "$INSTALL_DIR/docker-compose.yml" ps
}

###############################################################################
# Main
###############################################################################
main() {
    echo ""
    echo "=============================================="
    echo "  immich-rasp-5 설치 스크립트"
    echo "  Raspberry Pi 5 × Immich 셀프호스팅"
    echo "=============================================="
    echo ""
    log_info "로그 파일: $LOG_FILE"
    echo ""

    check_prerequisites
    install_docker
    setup_external_hdd
    setup_immich_files
    start_immich
    configure_firewall
    setup_watchdog
    show_status
}

main "$@"
