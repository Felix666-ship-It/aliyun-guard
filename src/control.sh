#!/bin/sh
set -u

APP_DIR=${ALIYUN_GUARD_HOME:-/opt/aliyun-guard}
PYTHON="$APP_DIR/venv/bin/python"
APP="$APP_DIR/aliyun_guard.py"
MANAGER="$APP_DIR/manager.py"
WEB="$APP_DIR/web_panel.py"
BACKEND_FILE="$APP_DIR/service_backend"
SERVICE_NAME="aliyun-guard"

mark_enabled() {
    rm -f "$APP_DIR/disabled"
}

mark_disabled() {
    : > "$APP_DIR/disabled"
    chmod 600 "$APP_DIR/disabled"
}

enable_watchdog_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    cron_old=$(mktemp)
    cron_new=$(mktemp)
    crontab -l > "$cron_old" 2>/dev/null || :
    grep -v '# aliyun-guard-watchdog' "$cron_old" > "$cron_new" || :
    printf '* * * * * %s %s/watchdog.py >> %s/logs/watchdog.log 2>&1 # aliyun-guard-watchdog\n' \
        "$PYTHON" "$APP_DIR" "$APP_DIR" >> "$cron_new"
    crontab "$cron_new"
    rm -f "$cron_old" "$cron_new"
}

disable_watchdog_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    cron_old=$(mktemp)
    cron_new=$(mktemp)
    crontab -l > "$cron_old" 2>/dev/null || :
    grep -v '# aliyun-guard-watchdog' "$cron_old" > "$cron_new" || :
    if [ -s "$cron_new" ]; then
        crontab "$cron_new"
    else
        crontab -r >/dev/null 2>&1 || true
    fi
    rm -f "$cron_old" "$cron_new"
}

backend() {
    if [ -r "$BACKEND_FILE" ]; then
        sed -n '1p' "$BACKEND_FILE"
    else
        printf '%s\n' unknown
    fi
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '%s\n' "请使用 root 权限运行。" >&2
        exit 1
    fi
}

backend_status() {
    current=$(backend)
    printf '调度后端: %s\n' "$current"
    case "$current" in
        systemd)
            systemctl is-enabled "$SERVICE_NAME.service" 2>/dev/null || true
            systemctl is-active "$SERVICE_NAME.service" 2>/dev/null || true
            systemctl is-active "$SERVICE_NAME-watchdog.timer" 2>/dev/null || true
            ;;
        openrc)
            rc-service "$SERVICE_NAME" status 2>/dev/null || true
            ;;
        cron)
            if [ -e "$APP_DIR/disabled" ]; then
                printf '%s\n' "状态: 已暂停"
            else
                printf '%s\n' "状态: 已启用"
            fi
            crontab -l 2>/dev/null | grep '# aliyun-guard' || true
            ;;
        *)
            printf '%s\n' "未识别调度后端，请重新运行安装器修复。"
            return 1
            ;;
    esac
}

start_service() {
    need_root
    current=$(backend)
    case "$current" in
        systemd)
            mark_enabled
            systemctl enable --now "$SERVICE_NAME.service"
            systemctl enable --now "$SERVICE_NAME-watchdog.timer"
            ;;
        openrc)
            mark_enabled
            enable_watchdog_cron
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
            rc-service "$SERVICE_NAME" start
            ;;
        cron)
            mark_enabled
            enable_watchdog_cron
            "$PYTHON" "$WEB" ensure >/dev/null 2>&1 || true
            printf '%s\n' "cron 调度已启用。"
            ;;
        *)
            printf '%s\n' "未知调度后端: $current" >&2
            return 1
            ;;
    esac
}

stop_service() {
    need_root
    current=$(backend)
    case "$current" in
        systemd)
            mark_disabled
            systemctl disable --now "$SERVICE_NAME-watchdog.timer" >/dev/null 2>&1 || true
            systemctl disable --now "$SERVICE_NAME.service"
            ;;
        openrc)
            mark_disabled
            disable_watchdog_cron
            rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
            rc-service "$SERVICE_NAME" stop
            ;;
        cron)
            mark_disabled
            disable_watchdog_cron
            "$PYTHON" "$WEB" stop >/dev/null 2>&1 || true
            printf '%s\n' "cron 调度已暂停。"
            ;;
        *)
            printf '%s\n' "未知调度后端: $current" >&2
            return 1
            ;;
    esac
}

restart_service() {
    need_root
    current=$(backend)
    case "$current" in
        systemd)
            mark_enabled
            systemctl restart "$SERVICE_NAME.service"
            systemctl enable --now "$SERVICE_NAME-watchdog.timer"
            systemctl is-active "$SERVICE_NAME.service"
            ;;
        openrc)
            mark_enabled
            enable_watchdog_cron
            rc-service "$SERVICE_NAME" restart
            ;;
        cron)
            mark_enabled
            enable_watchdog_cron
            "$PYTHON" "$APP" scheduled
            "$PYTHON" "$WEB" restart
            ;;
        *)
            printf '%s\n' "未知调度后端: $current" >&2
            return 1
            ;;
    esac
}

show_help() {
    cat <<'EOF'
用法: aliyun-guard [命令]

不带命令             打开交互式管理面板
status                查看服务和最近检测状态
run                    立即执行一轮检测并通知
dry-run                演练一轮，不执行开关机
test-telegram          发送 Telegram 测试消息
web                    查看网页控制面板地址和状态
update                 从 GitHub 下载并安装最新版本
version                显示当前版本号
logs                   查看最近 100 行日志
logs-follow            持续查看日志
start|stop|restart     管理后台调度
add                    交互式添加实例
uninstall              交互式卸载
help                   显示本帮助
EOF
}

if [ ! -x "$PYTHON" ] || [ ! -f "$APP" ]; then
    printf '%s\n' "程序不完整，请重新运行安装器。" >&2
    exit 1
fi

command_name=${1:-menu}
case "$command_name" in
    menu)
        exec "$PYTHON" "$MANAGER" menu
        ;;
    status)
        backend_status
        printf '\n'
        exec "$PYTHON" "$APP" status
        ;;
    backend-status)
        backend_status
        ;;
    run|once)
        exec "$PYTHON" "$APP" once
        ;;
    dry-run)
        exec "$PYTHON" "$APP" once --dry-run
        ;;
    test-telegram)
        exec "$PYTHON" "$APP" test-telegram
        ;;
    web)
        exec "$PYTHON" "$MANAGER" web
        ;;
    update)
        exec "$PYTHON" "$MANAGER" update
        ;;
    version|-V|--version)
        exec "$PYTHON" "$MANAGER" version
        ;;
    logs)
        if [ -f "$APP_DIR/logs/guard.log" ]; then
            tail -n 100 "$APP_DIR/logs/guard.log"
        else
            printf '%s\n' "日志尚未生成。"
        fi
        ;;
    logs-follow)
        touch "$APP_DIR/logs/guard.log"
        exec tail -f "$APP_DIR/logs/guard.log"
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    add)
        exec "$PYTHON" "$MANAGER" add
        ;;
    uninstall)
        need_root
        exec "$APP_DIR/uninstall.sh"
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        printf '未知命令: %s\n\n' "$command_name" >&2
        show_help >&2
        exit 2
        ;;
esac
