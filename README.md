# immich-rasp-5

Raspberry Pi 5에서 Immich(사진 관리 서비스)를 셀프호스팅하는 프로젝트.
로컬 네트워크에서만 접근 가능하도록 구성되며, 1TB 외장하드를 사진 저장소로 사용한다.

## 사전 요구사항

- Raspberry Pi 5 (RAM 4GB 이상 권장)
- 64비트 Raspberry Pi OS (Bookworm)
- USB 외장하드 (사진 저장용)
- 인터넷 연결

## Quick Start

```bash
git clone https://github.com/changyeobjin/immich-rasp-5.git
cd immich-rasp-5
sudo ./install.sh
```

설치 스크립트가 자동으로 처리하는 항목:
1. 시스템 요구사항 검증
2. Docker 설치
3. 외장하드 마운트 및 fstab 설정
4. Immich 설정 파일 생성 (DB 비밀번호 자동 생성)
5. Docker 컨테이너 시작
6. UFW 방화벽 설정 (로컬 네트워크만 허용)

## 설정 변경

`.env` 파일을 수정한 후 서비스를 재시작한다:

```bash
sudo nano /opt/immich/.env
docker compose -f /opt/immich/docker-compose.yml up -d
```

### ML 서비스 활성화/비활성화

ML 서비스(얼굴 인식, 스마트 검색)를 활성화하려면 `/opt/immich/.env`에서:

```env
# 활성화
COMPOSE_PROFILES=ml

# 비활성화 (주석 처리)
# COMPOSE_PROFILES=ml
```

변경 후 `docker compose -f /opt/immich/docker-compose.yml up -d` 실행.

> RAM 8GB 이상에서 ML 활성화를 권장합니다.

## 업데이트

```bash
cd /opt/immich
docker compose pull
docker compose up -d
```

## 백업

백업해야 할 항목:
- `/opt/immich/.env` — 설정 파일
- `/opt/immich/postgres/` — PostgreSQL 데이터베이스
- `/mnt/immich-external/library/` — 사진 라이브러리 (외장하드)

PostgreSQL 덤프:

```bash
docker exec -t immich_postgres pg_dumpall -c -U postgres > /tmp/immich-db-backup.sql
```

## 삭제

```bash
# 서비스 중지 및 컨테이너 제거
docker compose -f /opt/immich/docker-compose.yml down -v

# 설정 파일 제거
sudo rm -rf /opt/immich

# (선택) Docker 이미지 제거
docker image prune -a

# (선택) 외장하드 언마운트
sudo umount /mnt/immich-external
# /etc/fstab에서 immich-external 관련 줄 제거
```

## 트러블슈팅

### 컨테이너가 시작되지 않음

```bash
docker compose -f /opt/immich/docker-compose.yml logs
```

### 외장하드가 마운트되지 않음

```bash
# 연결 확인
lsblk

# 수동 마운트
sudo mount /mnt/immich-external

# fstab 확인
cat /etc/fstab | grep immich
```

### 포트 충돌

`/opt/immich/.env`에서 `IMMICH_PORT`를 다른 값으로 변경한 후 서비스 재시작.

### 메모리 부족 (OOM)

```bash
# 리소스 사용량 확인
docker stats --no-stream

# ML 서비스 비활성화 권장
# /opt/immich/.env 에서 COMPOSE_PROFILES=ml 주석 처리
```

### API 응답 확인

```bash
curl -s http://localhost:2283/api/server/ping
# 정상: {"res":"pong"}
```

## 검증

```bash
# 컨테이너 상태
docker compose -f /opt/immich/docker-compose.yml ps

# API 응답
curl -s http://localhost:2283/api/server/ping

# 외장하드 마운트
df -h /mnt/immich-external

# 방화벽 상태
sudo ufw status verbose

# 리소스 사용량
docker stats --no-stream
```

## 라이선스

MIT
