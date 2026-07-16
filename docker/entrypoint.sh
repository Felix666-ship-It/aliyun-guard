#!/bin/sh
set -eu

APP_DIR=/opt/aliyun-guard
DATA_DIR=/data
PYTHON=python
WEB_PORT=${ALIYUN_GUARD_CONTAINER_WEB_PORT:-8765}

mkdir -p "$DATA_DIR/logs" "$APP_DIR/bin"
chmod 700 "$DATA_DIR" "$DATA_DIR/logs" "$APP_DIR/bin"

normalize_web_panel() {
    [ -f "$ALIYUN_GUARD_CONFIG" ] || return 0
    "$PYTHON" - "$WEB_PORT" <<'PY'
import sys

import aliyun_guard as guard

port = int(sys.argv[1])
if port < 1024 or port > 65535:
    raise SystemExit("ALIYUN_GUARD_CONTAINER_WEB_PORT 必须在 1024 到 65535 之间")
config = guard.load_config()
web = config.setdefault("web_panel", {})
if web.get("enabled"):
    changed = web.get("host") != "0.0.0.0" or int(web.get("port", port)) != port
    web["host"] = "0.0.0.0"
    web["port"] = port
    web["cookie_secure"] = False
    if changed:
        guard.atomic_write_json(guard.CONFIG_FILE, config, mode=0o600)
        print("Docker 网页面板已固定监听 0.0.0.0:{}".format(port))
PY
}

need_config() {
    if [ ! -s "$ALIYUN_GUARD_CONFIG" ]; then
        printf '%s\n' "尚未配置。请先执行：docker compose run --rm aliyun-guard setup" >&2
        exit 2
    fi
}

command_name=${1:-daemon}
shift || true

case "$command_name" in
    daemon)
        need_config
        normalize_web_panel
        exec "$PYTHON" "$APP_DIR/aliyun_guard.py" daemon "$@"
        ;;
    setup)
        "$PYTHON" "$APP_DIR/manager.py" setup "$@"
        normalize_web_panel
        printf '%s\n' "Docker 首次配置已保存。现在执行：docker compose up -d"
        ;;
    menu)
        need_config
        "$PYTHON" "$APP_DIR/manager.py" menu "$@"
        normalize_web_panel
        ;;
    run|once)
        need_config
        exec "$PYTHON" "$APP_DIR/aliyun_guard.py" once "$@"
        ;;
    dry-run)
        need_config
        exec "$PYTHON" "$APP_DIR/aliyun_guard.py" once --dry-run "$@"
        ;;
    test-telegram)
        need_config
        exec "$PYTHON" "$APP_DIR/aliyun_guard.py" test-telegram "$@"
        ;;
    status)
        need_config
        exec "$PYTHON" "$APP_DIR/aliyun_guard.py" status "$@"
        ;;
    version)
        exec "$PYTHON" "$APP_DIR/manager.py" version
        ;;
    update)
        printf '%s\n' "Docker 部署请在宿主机执行：git pull && docker compose up -d --build" >&2
        exit 2
        ;;
    shell)
        exec /bin/sh "$@"
        ;;
    help|-h|--help)
        cat <<'EOF'
用法: docker compose run --rm aliyun-guard <命令>

setup            首次交互配置
daemon           以前台守护进程运行（容器默认）
run              立即真实检测
dry-run          演练检测，不执行开关机
test-telegram    测试 Telegram
status           查看状态
version          显示版本
menu             打开终端管理菜单
shell            进入容器 shell
EOF
        ;;
    *)
        exec "$command_name" "$@"
        ;;
esac
