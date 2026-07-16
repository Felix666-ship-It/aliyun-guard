#!/bin/sh
# Aliyun Guard self-contained interactive installer.
set -eu
umask 077

APP_DIR=${ALIYUN_GUARD_HOME:-/opt/aliyun-guard}
VENV_DIR="$APP_DIR/venv"
SERVICE_NAME="aliyun-guard"
BIN_LINK="/usr/local/bin/aliyun-guard"
SHORT_BIN_LINK="/usr/local/bin/ag"
MIN_PYTHON="3.8"
SHORTCUT_AVAILABLE=no
PRESERVE_DIR=""

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

case ${1:-} in
    "") INSTALL_ACTION=interactive ;;
    --update) INSTALL_ACTION=update ;;
    *)
        printf '%s\n' "未知安装参数: $1" >&2
        exit 2
        ;;
esac

say() {
    printf '%b\n' "$*"
}

die() {
    say "${RED}错误: $*${RESET}" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 权限运行（sudo -i）。"
fi

if [ ! -r /dev/tty ] && [ "$INSTALL_ACTION" = interactive ]; then
    die "这是交互式安装器，但当前没有可用终端。请在 SSH/VNC 终端中运行。"
fi
if [ -r /dev/tty ]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

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
        prompt "$question (Y/n)" "y"
    else
        prompt "$question (y/N)" "n"
    fi
    case "$REPLY" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup_preserved_data() {
    if [ -n "$PRESERVE_DIR" ] && [ -d "$PRESERVE_DIR" ]; then
        rm -rf "$PRESERVE_DIR"
    fi
    PRESERVE_DIR=""
}

trap cleanup_preserved_data EXIT
trap 'exit 130' HUP INT TERM

say "${CYAN}==============================================================${RESET}"
say "${CYAN}       阿里云 ECS 保活 + CDT 止损 + Telegram 通知${RESET}"
say "${CYAN}==============================================================${RESET}"
say "安装目录: $APP_DIR"

detect_os() {
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
    else
        PKG_MANAGER=unknown
    fi
    say "检测到系统: ${GREEN}$OS_NAME${RESET}（包管理器: $PKG_MANAGER）"
}

existing_menu() {
    if [ "$INSTALL_ACTION" = update ]; then
        [ -f "$APP_DIR/config.json" ] || die "未检测到现有配置，不能使用 --update；请执行首次交互安装。"
        say "${YELLOW}更新模式：保留现有配置和状态。${RESET}"
        return
    fi
    if [ ! -f "$APP_DIR/config.json" ]; then
        return
    fi
    say "${YELLOW}检测到已有 Aliyun Guard 配置。${RESET}"
    say " 1) 打开管理面板"
    say " 2) 更新程序并保留配置"
    say " 3) 重置配置并重新安装"
    say " 4) 卸载"
    say " 5) 退出"
    prompt "请选择" "1"
    case "$REPLY" in
        1)
            if [ -x "$VENV_DIR/bin/python" ] && [ -f "$APP_DIR/manager.py" ]; then
                "$VENV_DIR/bin/python" "$APP_DIR/manager.py" menu <&3
                exit $?
            fi
            say "${YELLOW}现有程序不完整，将进入修复更新。${RESET}"
            ;;
        2)
            ;;
        3)
            if ! confirm "会备份并清空当前配置，确认继续" n; then
                exit 0
            fi
            backup_dir="/root/aliyun-guard-backup-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$backup_dir"
            cp "$APP_DIR/config.json" "$backup_dir/config.json"
            [ ! -f "$APP_DIR/state.json" ] || cp "$APP_DIR/state.json" "$backup_dir/state.json"
            chmod 600 "$backup_dir"/*.json 2>/dev/null || true
            rm -f "$APP_DIR/config.json" "$APP_DIR/state.json"
            say "旧配置已备份到: $backup_dir"
            ;;
        4)
            if [ -x "$APP_DIR/uninstall.sh" ]; then
                "$APP_DIR/uninstall.sh" <&3
                exit $?
            fi
            die "卸载脚本缺失，请先选择更新修复。"
            ;;
        5)
            exit 0
            ;;
        *)
            die "无效选择。"
            ;;
    esac
}

preserve_local_data() {
    if [ ! -f "$APP_DIR/config.json" ]; then
        return
    fi
    PRESERVE_DIR=$(mktemp -d)
    cp "$APP_DIR/config.json" "$PRESERVE_DIR/config.json"
    [ ! -f "$APP_DIR/state.json" ] || cp "$APP_DIR/state.json" "$PRESERVE_DIR/state.json"
    if [ -f "$APP_DIR/bin/sing-box" ]; then
        mkdir -p "$PRESERVE_DIR/bin"
        cp "$APP_DIR/bin/sing-box" "$PRESERVE_DIR/bin/sing-box"
    fi
    chmod 600 "$PRESERVE_DIR/config.json"
    say "${GREEN}已保护现有配置（包括 Telegram 连接方式、节点和网页面板设置）。${RESET}"
}

restore_local_data() {
    if [ -z "$PRESERVE_DIR" ] || [ ! -f "$PRESERVE_DIR/config.json" ]; then
        return
    fi
    cp "$PRESERVE_DIR/config.json" "$APP_DIR/config.json"
    chmod 600 "$APP_DIR/config.json"
    if [ -f "$PRESERVE_DIR/state.json" ]; then
        cp "$PRESERVE_DIR/state.json" "$APP_DIR/state.json"
        chmod 600 "$APP_DIR/state.json"
    fi
    if [ -f "$PRESERVE_DIR/bin/sing-box" ] && [ ! -x "$APP_DIR/bin/sing-box" ]; then
        mkdir -p "$APP_DIR/bin"
        cp "$PRESERVE_DIR/bin/sing-box" "$APP_DIR/bin/sing-box"
        chmod 700 "$APP_DIR/bin/sing-box"
    fi
    say "${GREEN}已恢复现有配置，Telegram 代理、节点和网页面板设置保持不变。${RESET}"
    cleanup_preserved_data
}

handle_legacy_monitor() {
    if [ "$INSTALL_ACTION" = update ]; then
        return
    fi
    legacy_found=no
    if [ -f /opt/scripts/monitor.py ]; then
        legacy_found=yes
    elif command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q '#aliyun_monitor'; then
        legacy_found=yes
    fi
    if [ "$legacy_found" != yes ]; then
        return
    fi
    say "${YELLOW}检测到旧项目 /opt/scripts 或 #aliyun_monitor 定时任务。${RESET}"
    say "新旧监控同时运行会重复通知，并可能对同一 ECS 重复执行动作。"
    if ! confirm "是否停用旧项目的 cron 定时任务（保留旧文件和控制 Bot）" y; then
        say "${YELLOW}已保留旧任务，请自行确保两套程序不监控同一实例。${RESET}"
        return
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        say "${YELLOW}当前找不到 crontab，未修改旧项目。${RESET}"
        return
    fi
    cron_old=$(mktemp)
    cron_new=$(mktemp)
    crontab -l > "$cron_old" 2>/dev/null || :
    backup_file="/root/aliyun-monitor-crontab-$(date +%Y%m%d-%H%M%S).bak"
    cp "$cron_old" "$backup_file"
    chmod 600 "$backup_file"
    grep -v '#aliyun_monitor' "$cron_old" > "$cron_new" || :
    if [ -s "$cron_new" ]; then
        crontab "$cron_new"
    else
        crontab -r >/dev/null 2>&1 || true
    fi
    rm -f "$cron_old" "$cron_new"
    say "旧 cron 已停用，备份位于: $backup_file"
}

install_packages() {
    say "${YELLOW}[1/6] 安装系统依赖...${RESET}"
    case "$PKG_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y python3 python3-venv python3-pip ca-certificates cron
            ;;
        dnf)
            dnf install -y python3 python3-pip ca-certificates cronie
            ;;
        yum)
            yum install -y python3 python3-pip ca-certificates cronie
            ;;
        apk)
            apk add --no-cache python3 py3-pip py3-virtualenv ca-certificates openrc dcron
            update-ca-certificates >/dev/null 2>&1 || true
            ;;
        pacman)
            pacman -Sy --noconfirm python python-pip ca-certificates cronie
            ;;
        zypper)
            zypper --non-interactive install python3 python3-pip python3-virtualenv ca-certificates cron
            ;;
        unknown)
            if ! command -v python3 >/dev/null 2>&1; then
                die "未识别包管理器，且未找到 python3。"
            fi
            say "${YELLOW}未识别包管理器，将使用系统现有 Python。${RESET}"
            ;;
    esac
}

find_python() {
    PYTHON=""
    for candidate in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
            PYTHON=$(command -v "$candidate")
            break
        fi
    done
    [ -n "$PYTHON" ] || die "需要 Python $MIN_PYTHON 或更高版本。"
    say "使用 Python: $PYTHON（$($PYTHON -c 'import platform; print(platform.python_version())')）"
}

create_venv() {
    say "${YELLOW}[2/6] 创建 Python 独立环境...${RESET}"
    if [ ! -x "$VENV_DIR/bin/python" ]; then
        rm -rf "$VENV_DIR"
        if ! "$PYTHON" -m venv "$VENV_DIR" 2>/dev/null; then
            if "$PYTHON" -m virtualenv --version >/dev/null 2>&1; then
                "$PYTHON" -m virtualenv "$VENV_DIR"
            elif command -v virtualenv >/dev/null 2>&1; then
                virtualenv -p "$PYTHON" "$VENV_DIR"
            else
                die "无法创建虚拟环境，请安装 Python venv/virtualenv 后重试。"
            fi
        fi
    fi
    "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check --upgrade pip setuptools wheel
    "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check \
        'aliyun-python-sdk-core>=2.16,<3' \
        'aliyun-python-sdk-ecs>=4.24,<5' \
        'requests[socks]>=2.31,<3'
}

stop_old_backend() {
    if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/$SERVICE_NAME" ]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    fi
    if [ -x "$VENV_DIR/bin/python" ] && [ -f "$APP_DIR/web_panel.py" ]; then
        "$VENV_DIR/bin/python" "$APP_DIR/web_panel.py" stop >/dev/null 2>&1 || true
    fi
}

write_payload() {
    say "${YELLOW}[3/6] 写入程序文件...${RESET}"
    mkdir -p "$APP_DIR/logs"
# __PAYLOAD_BLOCKS__
    chmod 700 "$APP_DIR/control.sh" "$APP_DIR/uninstall.sh"
    chmod 700 "$APP_DIR/aliyun_guard.py" "$APP_DIR/manager.py" "$APP_DIR/telegram_proxy.py" "$APP_DIR/web_panel.py"
    chmod 600 "$APP_DIR/web_panel.html"
    chmod 700 "$APP_DIR"
    chmod 700 "$APP_DIR/logs"
    [ ! -f "$APP_DIR/config.json" ] || chmod 600 "$APP_DIR/config.json"
    [ ! -f "$APP_DIR/state.json" ] || chmod 600 "$APP_DIR/state.json"
    "$VENV_DIR/bin/python" -m py_compile \
        "$APP_DIR/aliyun_guard.py" \
        "$APP_DIR/manager.py" \
        "$APP_DIR/telegram_proxy.py" \
        "$APP_DIR/web_panel.py"
    sh -n "$APP_DIR/control.sh"
    sh -n "$APP_DIR/uninstall.sh"
    mkdir -p /usr/local/bin
    ln -sf "$APP_DIR/control.sh" "$BIN_LINK"
    existing_shortcut=$(command -v ag 2>/dev/null || true)
    if [ -n "$existing_shortcut" ] && [ "$existing_shortcut" != "$SHORT_BIN_LINK" ]; then
        say "${YELLOW}快捷命令 ag 已被其他程序占用（$existing_shortcut），仅安装完整命令 aliyun-guard。${RESET}"
    elif [ -e "$SHORT_BIN_LINK" ] || [ -L "$SHORT_BIN_LINK" ]; then
        if [ "$(readlink "$SHORT_BIN_LINK" 2>/dev/null || true)" = "$APP_DIR/control.sh" ]; then
            ln -sf "$APP_DIR/control.sh" "$SHORT_BIN_LINK"
            SHORTCUT_AVAILABLE=yes
        else
            say "${YELLOW}快捷命令 ag 已被其他程序占用，仅安装完整命令 aliyun-guard。${RESET}"
        fi
    else
        ln -s "$APP_DIR/control.sh" "$SHORT_BIN_LINK"
        SHORTCUT_AVAILABLE=yes
    fi
}

remove_cron_entry() {
    if ! command -v crontab >/dev/null 2>&1; then
        return
    fi
    cron_old=$(mktemp)
    cron_new=$(mktemp)
    crontab -l > "$cron_old" 2>/dev/null || :
    grep -v '# aliyun-guard' "$cron_old" > "$cron_new" || :
    if [ -s "$cron_new" ]; then
        crontab "$cron_new"
    else
        crontab -r >/dev/null 2>&1 || true
    fi
    rm -f "$cron_old" "$cron_new"
}

setup_systemd() {
    cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Aliyun ECS keepalive and CDT traffic guard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$VENV_DIR/bin/python $APP_DIR/aliyun_guard.py daemon
Restart=always
RestartSec=10
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "/etc/systemd/system/$SERVICE_NAME.service"
    if [ -f "/etc/init.d/$SERVICE_NAME" ]; then
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$SERVICE_NAME"
    fi
    remove_cron_entry
    printf '%s\n' systemd > "$APP_DIR/service_backend"
    systemctl daemon-reload
    if [ "$START_BACKEND" = yes ]; then
        systemctl enable --now "$SERVICE_NAME.service"
    else
        systemctl disable "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    fi
}

setup_openrc() {
    cat > "/etc/init.d/$SERVICE_NAME" <<EOF
#!/sbin/openrc-run
name="Aliyun ECS keepalive and CDT traffic guard"
description="Aliyun ECS keepalive and CDT traffic guard"
command="$VENV_DIR/bin/python"
command_args="$APP_DIR/aliyun_guard.py daemon"
command_background="yes"
pidfile="/run/$SERVICE_NAME.pid"
output_log="$APP_DIR/logs/service.log"
error_log="$APP_DIR/logs/service.log"

depend() {
    need net
    after firewall
}
EOF
    chmod 755 "/etc/init.d/$SERVICE_NAME"
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    remove_cron_entry
    printf '%s\n' openrc > "$APP_DIR/service_backend"
    if [ "$START_BACKEND" = yes ]; then
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start
    else
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
    fi
}

start_cron_service() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
    elif command -v crond >/dev/null 2>&1; then
        crond >/dev/null 2>&1 || true
    fi
}

setup_cron() {
    command -v crontab >/dev/null 2>&1 || die "系统没有 systemd/OpenRC，也没有 crontab，无法安装调度任务。"
    cron_old=$(mktemp)
    cron_new=$(mktemp)
    crontab -l > "$cron_old" 2>/dev/null || :
    grep -v '# aliyun-guard' "$cron_old" > "$cron_new" || :
    printf '* * * * * %s/bin/python %s/aliyun_guard.py scheduled >> %s/logs/cron.log 2>&1 # aliyun-guard\n' \
        "$VENV_DIR" "$APP_DIR" "$APP_DIR" >> "$cron_new"
    printf '* * * * * %s/bin/python %s/web_panel.py ensure >> %s/logs/web-supervisor.log 2>&1 # aliyun-guard-web\n' \
        "$VENV_DIR" "$APP_DIR" "$APP_DIR" >> "$cron_new"
    crontab "$cron_new"
    rm -f "$cron_old" "$cron_new"
    if [ "$START_BACKEND" = yes ]; then
        rm -f "$APP_DIR/disabled"
    else
        : > "$APP_DIR/disabled"
        chmod 600 "$APP_DIR/disabled"
    fi
    printf '%s\n' cron > "$APP_DIR/service_backend"
    start_cron_service
    if [ "$START_BACKEND" = yes ]; then
        "$VENV_DIR/bin/python" "$APP_DIR/web_panel.py" ensure >/dev/null 2>&1 || \
            say "${YELLOW}网页面板暂未启动，cron 将在一分钟内自动重试。${RESET}"
    fi
}

setup_backend() {
    say "${YELLOW}[5/6] 配置后台调度...${RESET}"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && systemctl show-environment >/dev/null 2>&1; then
        setup_systemd
    elif command -v rc-service >/dev/null 2>&1 && rc-status >/dev/null 2>&1; then
        setup_openrc
    else
        setup_cron
    fi
    chmod 600 "$APP_DIR/service_backend"
}

prepare_configuration() {
    say "${YELLOW}[4/6] 检查首次配置状态...${RESET}"
    if [ -s "$APP_DIR/config.json" ]; then
        chmod 600 "$APP_DIR/config.json"
        START_BACKEND=yes
        say "${GREEN}已保留现有配置，安装完成后自动恢复后台服务。${RESET}"
    else
        START_BACKEND=no
        say "${YELLOW}尚未配置账号。安装完成后需手动输入管理命令。${RESET}"
    fi
}

finish() {
    say "${YELLOW}[6/6] 验证运行状态...${RESET}"
    sleep 1
    "$APP_DIR/control.sh" backend-status || true
    say ""
    say "${GREEN}安装完成。${RESET}"
    version_text=$("$VENV_DIR/bin/python" "$APP_DIR/manager.py" version)
    say "当前版本: ${CYAN}$version_text${RESET}"
    if [ "$START_BACKEND" = no ]; then
        say "${YELLOW}管理面板不会自动打开。请返回命令行后手动输入以下命令：${RESET}"
        say "完整命令: ${CYAN}aliyun-guard${RESET}"
        if [ "$SHORTCUT_AVAILABLE" = yes ]; then
            say "快捷命令: ${CYAN}ag${RESET}"
        fi
        say "首次打开时会进入配置向导；配置成功后后台服务才会启动。"
        return
    fi
    say "管理面板: ${CYAN}aliyun-guard${RESET}"
    if [ "$SHORTCUT_AVAILABLE" = yes ]; then
        say "快捷面板: ${CYAN}ag${RESET}"
    fi
    say "立即检测: ${CYAN}aliyun-guard run${RESET}"
    say "演练检测: ${CYAN}aliyun-guard dry-run${RESET}"
    say "查看状态: ${CYAN}aliyun-guard status${RESET}"
    say "查看日志: ${CYAN}aliyun-guard logs${RESET}"
    say "网页面板: ${CYAN}aliyun-guard web${RESET}"
    say "更新版本: ${CYAN}aliyun-guard update${RESET}"
}

detect_os
existing_menu
handle_legacy_monitor
install_packages
find_python
mkdir -p "$APP_DIR"
create_venv
stop_old_backend
preserve_local_data
write_payload
restore_local_data
prepare_configuration
setup_backend
finish
