#!/bin/sh
# Aliyun Guard one-command Docker deployment.
set -eu
umask 077

REPOSITORY="Felix666-ship-It/aliyun-guard"
SOURCE_REF=${ALIYUN_GUARD_DOCKER_REF:-main}
INSTALL_DIR=${ALIYUN_GUARD_DOCKER_HOME:-/opt/aliyun-guard-docker}
NATIVE_DIR=${ALIYUN_GUARD_NATIVE_HOME:-/opt/aliyun-guard}
ARCHIVE_URL="https://github.com/$REPOSITORY/archive/refs/heads/$SOURCE_REF.tar.gz"
TMP_DIR=""
PKG_MANAGER=unknown
COMPOSE_MODE=""
HAS_TTY=no
INSTALL_ACTION=deploy

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

say() {
    printf '%b\n' "$*"
}

die() {
    say "${RED}错误: $*${RESET}" >&2
    exit 1
}

prompt() {
    question=$1
    default_value=${2:-}
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$question" "$default_value"
    else
        printf '%s: ' "$question"
    fi
    IFS= read -r answer <&3 || answer=""
    if [ -z "$answer" ]; then
        answer=$default_value
    fi
    REPLY=$answer
}

confirm() {
    question=$1
    default_value=${2:-y}
    if [ "$default_value" = y ]; then
        prompt "$question (Y/n)" y
    else
        prompt "$question (y/N)" n
    fi
    case "$REPLY" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

show_help() {
    cat <<'EOF'
用法: docker-install.sh [--update]

不带参数     首次部署；已有 Docker 配置时自动更新并重建
--update     仅更新已有 Docker 部署，不进入首次配置
--help       显示帮助

环境变量:
ALIYUN_GUARD_DOCKER_HOME  部署目录，默认 /opt/aliyun-guard-docker
ALIYUN_GUARD_DOCKER_REF   GitHub 分支，默认 main
EOF
}

parse_arguments() {
    case ${1:-} in
        "") INSTALL_ACTION=deploy ;;
        --update) INSTALL_ACTION=update ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *) die "未知参数: $1" ;;
    esac
}

open_terminal() {
    if [ -r /dev/tty ]; then
        exec 3</dev/tty
        HAS_TTY=yes
    else
        exec 3<&0
        HAS_TTY=no
    fi
}

validate_source_ref() {
    case "$SOURCE_REF" in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_install_dir() {
    candidate=$1
    case "$candidate" in
        ""|/|/opt|/usr|/var|/root|/home|.) return 1 ;;
        /*/*) ;;
        *) return 1 ;;
    esac
    if [ -L "$candidate" ]; then
        return 1
    fi
    return 0
}

valid_port() {
    value=$1
    case "$value" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ]
}

detect_system() {
    OS_NAME="Unknown Linux"
    if [ -r /etc/os-release ]; then
        OS_NAME=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n 1 | tr -d '"')
    fi
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER=apt
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER=dnf
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER=yum
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER=apk
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER=pacman
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER=zypper
    fi
    say "检测到系统: ${GREEN}$OS_NAME${RESET}（包管理器: $PKG_MANAGER）"
}

install_base_packages() {
    if { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } \
        && command -v tar >/dev/null 2>&1 \
        && command -v gzip >/dev/null 2>&1; then
        return
    fi
    say "${YELLOW}[1/6] 安装下载与解压依赖...${RESET}"
    case "$PKG_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y ca-certificates curl tar gzip
            ;;
        dnf) dnf install -y ca-certificates curl tar gzip ;;
        yum) yum install -y ca-certificates curl tar gzip ;;
        apk) apk add --no-cache ca-certificates curl tar gzip ;;
        pacman) pacman -Sy --noconfirm ca-certificates curl tar gzip ;;
        zypper) zypper --non-interactive install ca-certificates curl tar gzip ;;
        *) die "未找到 curl/wget 或 tar，且无法识别包管理器。" ;;
    esac
    update-ca-certificates >/dev/null 2>&1 || true
}

download_file() {
    url=$1
    destination=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 \
            -o "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$destination" "$url"
    else
        die "缺少 curl 或 wget。"
    fi
}

install_docker_packages() {
    say "${YELLOW}[2/6] 安装 Docker Engine 与 Compose...${RESET}"
    case "$PKG_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y docker.io
            if ! apt-get install -y docker-compose-v2; then
                if ! apt-get install -y docker-compose-plugin; then
                    apt-get install -y docker-compose
                fi
            fi
            ;;
        dnf)
            if ! dnf install -y docker docker-compose-plugin; then
                if ! dnf install -y moby-engine docker-compose-plugin; then
                    dnf install -y docker docker-compose
                fi
            fi
            ;;
        yum)
            if ! yum install -y docker docker-compose-plugin; then
                yum install -y docker docker-compose
            fi
            ;;
        apk) apk add --no-cache docker docker-cli-compose ;;
        pacman) pacman -Sy --noconfirm docker docker-compose ;;
        zypper) zypper --non-interactive install docker docker-compose ;;
        *) return 1 ;;
    esac
}

install_official_docker() {
    say "${YELLOW}系统仓库未提供可用 Docker，将使用 Docker 官方安装脚本。${RESET}"
    installer="$TMP_DIR/get-docker.sh"
    download_file "https://get.docker.com" "$installer"
    sh "$installer"
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_MODE=plugin
        return 0
    fi
    if command -v docker-compose >/dev/null 2>&1 \
        && docker-compose version >/dev/null 2>&1; then
        COMPOSE_MODE=standalone
        return 0
    fi
    return 1
}

compose() {
    if [ "$COMPOSE_MODE" = plugin ]; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        if ! install_docker_packages || ! command -v docker >/dev/null 2>&1; then
            install_official_docker
        fi
    fi
    if ! detect_compose; then
        install_docker_packages || true
    fi
    if ! detect_compose; then
        install_official_docker
    fi
    detect_compose || die "Docker 已安装，但未找到 docker compose 或 docker-compose。"
    say "Docker: ${GREEN}$(docker --version)${RESET}"
    if [ "$COMPOSE_MODE" = plugin ]; then
        say "Compose: ${GREEN}$(docker compose version)${RESET}"
    else
        say "Compose: ${YELLOW}$(docker-compose version)（兼容模式）${RESET}"
    fi
}

start_docker_daemon() {
    if docker info >/dev/null 2>&1; then
        return
    fi
    say "正在启动 Docker 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add docker default >/dev/null 2>&1 || true
        rc-service docker start || true
    elif command -v service >/dev/null 2>&1; then
        service docker start || true
    fi
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        if docker info >/dev/null 2>&1; then
            return
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    die "Docker 服务未就绪。请先确认当前系统支持 Docker，再重新运行。"
}

download_source() {
    say "${YELLOW}[3/6] 下载 Aliyun Guard 源码...${RESET}"
    archive="$TMP_DIR/aliyun-guard.tar.gz"
    download_file "$ARCHIVE_URL" "$archive"
    tar -xzf "$archive" -C "$TMP_DIR"
    SOURCE_DIR="$TMP_DIR/aliyun-guard-$SOURCE_REF"
    if [ ! -d "$SOURCE_DIR" ]; then
        SOURCE_DIR=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d \
            -name 'aliyun-guard-*' | head -n 1)
    fi
    [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/Dockerfile" ] \
        && [ -f "$SOURCE_DIR/docker-compose.yml" ] \
        && [ -f "$SOURCE_DIR/.env.example" ] \
        && [ -f "$SOURCE_DIR/requirements.txt" ] \
        && [ -d "$SOURCE_DIR/src" ] \
        && [ -d "$SOURCE_DIR/docker" ] \
        || die "下载的源码包不完整。"
}

install_source() {
    say "${YELLOW}[4/6] 写入 Docker 部署文件...${RESET}"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/src" "$INSTALL_DIR/docker"
    cp -R "$SOURCE_DIR/src" "$INSTALL_DIR/src"
    cp -R "$SOURCE_DIR/docker" "$INSTALL_DIR/docker"
    for file in Dockerfile docker-compose.yml requirements.txt version.json \
        README.md docker-install.sh .dockerignore .env.example; do
        if [ -f "$SOURCE_DIR/$file" ]; then
            cp "$SOURCE_DIR/$file" "$INSTALL_DIR/$file"
        fi
    done
    if [ ! -f "$INSTALL_DIR/.env" ]; then
        if [ -s "$INSTALL_DIR/docker-data/config.json" ]; then
            sed 's/^ALIYUN_GUARD_BIND_IP=.*/ALIYUN_GUARD_BIND_IP=127.0.0.1/' \
                "$INSTALL_DIR/.env.example" > "$INSTALL_DIR/.env"
            say "检测到旧 Docker 配置，已创建仅本机监听的兼容 .env。"
        else
            cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
            say "已创建默认 .env：公网监听 0.0.0.0:8765。"
        fi
    else
        say "已保留现有 .env。"
    fi
    mkdir -p "$INSTALL_DIR/docker-data/logs"
    chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/docker-data" \
        "$INSTALL_DIR/docker-data/logs"
    chmod 600 "$INSTALL_DIR/.env"
    [ ! -f "$INSTALL_DIR/docker-install.sh" ] \
        || chmod 700 "$INSTALL_DIR/docker-install.sh"
    [ ! -f "$INSTALL_DIR/docker-data/config.json" ] \
        || chmod 600 "$INSTALL_DIR/docker-data/config.json"
}

stop_native_service() {
    if [ -x "$NATIVE_DIR/control.sh" ]; then
        "$NATIVE_DIR/control.sh" stop
        current_backend=$(sed -n '1p' "$NATIVE_DIR/service_backend" 2>/dev/null || true)
        case "$current_backend" in
            systemd) systemctl disable aliyun-guard.service >/dev/null 2>&1 || true ;;
            openrc) rc-update del aliyun-guard default >/dev/null 2>&1 || true ;;
        esac
        return
    fi
    die "检测到原生配置，但找不到控制脚本，无法安全停止原生调度。"
}

migrate_native_installation() {
    docker_config="$INSTALL_DIR/docker-data/config.json"
    native_config="$NATIVE_DIR/config.json"
    if [ -f "$docker_config" ] || [ ! -f "$native_config" ]; then
        return
    fi
    [ "$HAS_TTY" = yes ] || die "检测到原生安装，需要交互确认迁移，但当前没有终端。"
    say "${YELLOW}检测到原生部署: $NATIVE_DIR${RESET}"
    say "两套保活同时运行可能重复操作同一台 ECS。"
    if ! confirm "迁移原配置并停用原生调度后继续 Docker 部署" y; then
        die "已取消。请先处理原生部署后再运行。"
    fi
    stop_native_service
    cp "$native_config" "$docker_config"
    chmod 600 "$docker_config"
    if [ -f "$NATIVE_DIR/state.json" ]; then
        cp "$NATIVE_DIR/state.json" "$INSTALL_DIR/docker-data/state.json"
        chmod 600 "$INSTALL_DIR/docker-data/state.json"
    fi
    if [ -d "$NATIVE_DIR/logs" ]; then
        cp -R "$NATIVE_DIR/logs/." "$INSTALL_DIR/docker-data/logs/"
    fi
    say "${GREEN}原配置、状态和日志已迁移；原生程序文件未删除。${RESET}"
}

build_image() {
    say "${YELLOW}[5/6] 构建 Docker 镜像...${RESET}"
    cd "$INSTALL_DIR"
    compose build
}

run_initial_setup() {
    config_file="$INSTALL_DIR/docker-data/config.json"
    if [ -s "$config_file" ]; then
        say "${GREEN}检测到已有 Docker 配置，跳过首次向导。${RESET}"
        return
    fi
    if [ "$INSTALL_ACTION" = update ]; then
        die "--update 要求已有 $config_file。"
    fi
    [ "$HAS_TTY" = yes ] \
        || die "首次配置需要 SSH/VNC 交互终端，不能在无终端环境运行。"
    say "${YELLOW}开始首次配置，请按提示填写 Telegram 和阿里云实例。${RESET}"
    cd "$INSTALL_DIR"
    compose run --rm aliyun-guard setup <&3
    [ -s "$config_file" ] || die "首次配置未生成 config.json。"
    chmod 600 "$config_file"
}

start_container() {
    say "${YELLOW}[6/6] 启动 Aliyun Guard 容器...${RESET}"
    cd "$INSTALL_DIR"
    compose up -d --remove-orphans --force-recreate
    attempt=0
    while [ "$attempt" -lt 30 ]; do
        status=$(docker inspect -f '{{.State.Status}}' aliyun-guard 2>/dev/null || true)
        if [ "$status" = running ]; then
            return
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    compose logs --tail 100 aliyun-guard || true
    die "容器未进入 running 状态，请检查上方日志。"
}

env_value() {
    key=$1
    default_value=$2
    value=$(sed -n "s/^${key}=//p" "$INSTALL_DIR/.env" | tail -n 1)
    if [ -z "$value" ]; then
        value=$default_value
    fi
    printf '%s' "$value"
}

detect_public_ipv4() {
    configured=$(env_value ALIYUN_GUARD_PUBLIC_IP "")
    if [ -n "$configured" ]; then
        printf '%s' "$configured"
        return
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -4fsS --connect-timeout 3 https://api.ipify.org 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T 3 https://api.ipify.org 2>/dev/null || true
    fi
}

show_result() {
    bind_ip=$(env_value ALIYUN_GUARD_BIND_IP "127.0.0.1")
    web_port=$(env_value ALIYUN_GUARD_WEB_PORT "8765")
    valid_port "$web_port" || web_port=8765
    if [ "$bind_ip" = 127.0.0.1 ]; then
        access_url="http://127.0.0.1:$web_port"
        access_note="当前仅宿主机可访问，可使用 SSH 隧道或 HTTPS 反向代理。"
    else
        public_ip=$(detect_public_ipv4)
        [ -n "$public_ip" ] || public_ip="服务器公网IP"
        access_url="http://$public_ip:$web_port"
        access_note="请确认云安全组和系统防火墙已放行 TCP $web_port。"
    fi
    say ""
    say "${GREEN}==============================================================${RESET}"
    say "${GREEN}             Aliyun Guard Docker 部署完成${RESET}"
    say "${GREEN}==============================================================${RESET}"
    say "部署目录: $INSTALL_DIR"
    say "网页地址: $access_url"
    say "$access_note"
    say ""
    say "常用命令:"
    say "  cd $INSTALL_DIR"
    if [ "$COMPOSE_MODE" = plugin ]; then
        say "  docker compose ps"
        say "  docker compose logs -f aliyun-guard"
        say "  docker compose run --rm aliyun-guard menu"
    else
        say "  docker-compose ps"
        say "  docker-compose logs -f aliyun-guard"
        say "  docker-compose run --rm aliyun-guard menu"
    fi
    say ""
    say "再次执行同一条一键命令即可更新并重建，配置和日志会保留。"
}

main() {
    parse_arguments "$@"
    [ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行（sudo -i）。"
    validate_source_ref || die "ALIYUN_GUARD_DOCKER_REF 只能包含字母、数字、点、下划线和横线。"
    validate_install_dir "$INSTALL_DIR" \
        || die "部署目录不安全或是符号链接: $INSTALL_DIR"
    if [ "$INSTALL_ACTION" = update ] \
        && [ ! -s "$INSTALL_DIR/docker-data/config.json" ]; then
        die "--update 要求已有 $INSTALL_DIR/docker-data/config.json。"
    fi
    open_terminal
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    TMP_DIR=$(mktemp -d)

    say "${CYAN}==============================================================${RESET}"
    say "${CYAN}          Aliyun Guard 一键 Docker 部署${RESET}"
    say "${CYAN}==============================================================${RESET}"
    say "部署目录: $INSTALL_DIR"

    detect_system
    install_base_packages
    ensure_docker
    start_docker_daemon
    download_source
    install_source
    migrate_native_installation
    build_image
    run_initial_setup
    start_container
    show_result
}

if [ "${ALIYUN_GUARD_DOCKER_INSTALL_LIB_ONLY:-0}" != 1 ]; then
    main "$@"
fi
