#!/usr/bin/env bash
###############################################################################
# immich-watchdog
# Immich 서비스를 감시하고, 죽어있으면 자동으로 되살리는 와치독 스크립트
# systemd 서비스로 등록되어 부팅 시 자동 실행됨
###############################################################################

INSTALL_DIR="/opt/immich"
CHECK_INTERVAL=60          # 점검 주기 (초)
MAX_LOG_BYTES=10485760     # 로그 최대 크기 10MB

# 로그 경로: 설치 시 install.sh가 환경변수로 주입
LOG_FILE="${WATCHDOG_LOG:-/tmp/immich-watchdog.log}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size="$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
        if [[ "$size" -gt "$MAX_LOG_BYTES" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log "로그 로테이션 완료 (이전 로그: ${LOG_FILE}.old)"
        fi
    fi
}

# Immich API 포트 읽기
get_api_port() {
    local port
    port="$(grep IMMICH_PORT "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2)"
    echo "${port:-2283}"
}

# API 핑 한 번 시도
ping_api() {
    curl -sf "http://localhost:$(get_api_port)/api/server/ping" &>/dev/null
}

# 지수 백오프로 API 응답 대기 (최대 ~3분)
wait_for_api() {
    local delay=5
    local elapsed=0
    local max_wait=180    # 3분

    log "[INFO] API 응답 대기 시작 (지수 백오프, 최대 ${max_wait}초)"

    while [[ "$elapsed" -lt "$max_wait" ]]; do
        sleep "$delay"
        elapsed=$((elapsed + delay))

        if ping_api; then
            log "[INFO] 서비스 복구 성공 (API 응답 확인, ${elapsed}초 경과)"
            return 0
        fi

        log "[INFO] API 아직 미응답 (${elapsed}초/${max_wait}초), 다음 대기: ${delay}초→$((delay * 2))초"
        delay=$((delay * 2))

        # 남은 시간보다 delay가 크면 남은 시간만큼만 대기
        local remaining=$((max_wait - elapsed))
        if [[ "$delay" -gt "$remaining" ]]; then
            delay="$remaining"
        fi
    done

    return 1
}

# Docker 데몬 자체가 살아있는지 확인
check_docker() {
    if ! docker info &>/dev/null; then
        log "[WARN] Docker 데몬이 응답하지 않습니다. 시작 시도..."
        systemctl start docker
        sleep 10
        if ! docker info &>/dev/null; then
            log "[ERROR] Docker 데몬을 시작할 수 없습니다."
            return 1
        fi
        log "[INFO] Docker 데몬 시작됨"
    fi
    return 0
}

# 컨테이너 상태 확인 및 복구
check_and_restart() {
    local compose_file="$INSTALL_DIR/docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        log "[ERROR] $compose_file 을 찾을 수 없습니다."
        return 1
    fi

    # 필수 컨테이너 목록
    local required_containers=("immich_server" "immich_redis" "immich_postgres")
    local any_down=false

    for container in "${required_containers[@]}"; do
        local status
        status="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "missing")"
        if [[ "$status" != "running" ]]; then
            log "[WARN] $container 상태: $status"
            any_down=true
        fi
    done

    if $any_down; then
        log "[INFO] 서비스 복구 시도: docker compose up -d"
        if docker compose -f "$compose_file" up -d 2>>"$LOG_FILE"; then
            log "[INFO] docker compose up -d 완료"
        else
            log "[ERROR] docker compose up -d 실패"
            return 1
        fi

        # 지수 백오프로 API 응답 대기 (최대 ~3분)
        if ! wait_for_api; then
            log "[ERROR] 서비스 복구 후에도 API 응답 없음. 수동 확인 필요."
        fi
        return 0
    fi

    # 컨테이너는 모두 running이지만 API가 응답하지 않는 경우
    if ! ping_api; then
        log "[WARN] 컨테이너 정상이나 API 미응답. immich_server 재시작 시도."
        docker restart immich_server 2>>"$LOG_FILE"

        if ! wait_for_api; then
            log "[ERROR] immich_server 재시작 후에도 API 응답 없음. 전체 재시작 시도."
            docker compose -f "$compose_file" down 2>>"$LOG_FILE"
            docker compose -f "$compose_file" up -d 2>>"$LOG_FILE"

            if ! wait_for_api; then
                log "[ERROR] 전체 재시작 후에도 API 응답 없음. 수동 확인 필요."
            fi
        fi
    fi

    return 0
}

###############################################################################
# Main loop
###############################################################################
main() {
    log "=========================================="
    log "[INFO] Immich 와치독 시작 (PID: $$)"
    log "[INFO] 점검 주기: ${CHECK_INTERVAL}초"
    log "[INFO] 로그 파일: $LOG_FILE"
    log "=========================================="

    # 부팅 직후에는 Docker가 아직 안 떴을 수 있으므로 넉넉히 대기
    sleep 30

    while true; do
        rotate_log

        if check_docker; then
            check_and_restart
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main
