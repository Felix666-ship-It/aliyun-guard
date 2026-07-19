#!/bin/sh
set -eu

APP_DIR=${ALIYUN_GUARD_HOME:-/opt/aliyun-guard}
BACKEND_FILE="$APP_DIR/service_backend"
SERVICE_NAME="aliyun-guard"

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "请使用 root 权限运行。" >&2
    exit 1
fi

if [ -r /dev/tty ]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

printf '%s\n' "此操作将停止服务并删除 $APP_DIR。"
while true; do
    printf '%s' "确认卸载？输入 Y/N : "
    if ! IFS= read -r answer <&3; then
        printf '\n%s\n' "无法读取确认输入，已取消卸载。"
        exit 1
    fi
    case "$answer" in
        y|Y) break ;;
        n|N)
            printf '%s\n' "已取消卸载。"
            exit 0
            ;;
        *) printf '%s\n' "输入无效，请输入 Y 或 N。" ;;
    esac
done

printf '%s' "卸载前备份 config.json 到 /root？[Y/n]: "
IFS= read -r backup <&3 || backup=""
case "$backup" in
    n|N|no|NO) ;;
    *)
        if [ -f "$APP_DIR/config.json" ]; then
            backup_dir="/root/aliyun-guard-backup-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$backup_dir"
            cp "$APP_DIR/config.json" "$backup_dir/config.json"
            chmod 600 "$backup_dir/config.json"
            printf '配置已备份到 %s\n' "$backup_dir/config.json"
        fi
        ;;
esac

backend=unknown
if [ -r "$BACKEND_FILE" ]; then
    backend=$(sed -n '1p' "$BACKEND_FILE")
fi

if [ -x "$APP_DIR/venv/bin/python" ] && [ -f "$APP_DIR/web_panel.py" ]; then
    "$APP_DIR/venv/bin/python" "$APP_DIR/web_panel.py" stop >/dev/null 2>&1 || true
fi

case "$backend" in
    systemd)
        systemctl disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        systemctl disable --now "$SERVICE_NAME-watchdog.timer" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$SERVICE_NAME.service" \
            "/etc/systemd/system/$SERVICE_NAME-watchdog.service" \
            "/etc/systemd/system/$SERVICE_NAME-watchdog.timer"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ;;
    openrc)
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$SERVICE_NAME"
        rm -f "/etc/periodic/1min/$SERVICE_NAME-watchdog"
        ;;
    cron)
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
        ;;
esac

if [ -L /usr/local/bin/aliyun-guard ] || [ -f /usr/local/bin/aliyun-guard ]; then
    rm -f /usr/local/bin/aliyun-guard
fi
if [ -L /usr/local/bin/ag ] && [ "$(readlink /usr/local/bin/ag 2>/dev/null || true)" = "$APP_DIR/control.sh" ]; then
    rm -f /usr/local/bin/ag
fi
rm -rf "$APP_DIR"
printf '%s\n' "阿里云保活程序已卸载。"
