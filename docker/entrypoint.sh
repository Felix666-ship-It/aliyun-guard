#!/bin/sh
set -eu

APP_DIR=/opt/aliyun-guard
DATA_DIR=/data
PYTHON=python
WEB_PORT=${ALIYUN_GUARD_CONTAINER_WEB_PORT:-8765}
PUBLIC_WEB_PORT=${ALIYUN_GUARD_PUBLIC_WEB_PORT:-$WEB_PORT}

mkdir -p "$DATA_DIR/logs" "$APP_DIR/bin"
chmod 700 "$DATA_DIR" "$DATA_DIR/logs" "$APP_DIR/bin"

detect_public_ip() {
    if [ "${ALIYUN_GUARD_HOST_BIND_IP:-0.0.0.0}" = "127.0.0.1" ]; then
        ALIYUN_GUARD_PUBLIC_IP=
        export ALIYUN_GUARD_PUBLIC_IP
        export ALIYUN_GUARD_PUBLIC_WEB_PORT="$PUBLIC_WEB_PORT"
        return 0
    fi
    if [ -z "${ALIYUN_GUARD_PUBLIC_IP:-}" ]; then
        ALIYUN_GUARD_PUBLIC_IP=$("$PYTHON" <<'PY'
import ipaddress
import urllib.request

urls = (
    "https://api.ipify.org",
    "https://4.ipw.cn",
)
for url in urls:
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "Aliyun-Guard/1"})
        with urllib.request.urlopen(request, timeout=2.5) as response:
            value = response.read(64).decode("ascii", "strict").strip()
        address = ipaddress.ip_address(value)
        if isinstance(address, ipaddress.IPv4Address) and address.is_global:
            print(str(address))
            break
    except Exception:
        continue
PY
        )
    fi
    export ALIYUN_GUARD_PUBLIC_IP
    export ALIYUN_GUARD_PUBLIC_WEB_PORT="$PUBLIC_WEB_PORT"
}

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

show_web_access() {
    [ -f "$ALIYUN_GUARD_CONFIG" ] || return 0
    "$PYTHON" <<'PY'
import aliyun_guard as guard
import web_panel

web = web_panel.get_web_config(guard.load_config())
if web.get("enabled"):
    print("Docker 网页面板访问地址：{}".format(web_panel.browser_access_url(web)))
    if web_panel.container_host_bind_ip() == "127.0.0.1":
        print("当前仅允许宿主机访问，可使用 SSH 隧道或 HTTPS 反向代理。")
    else:
        print("请确认云安全组和防火墙已放行宿主机端口，并优先配置 HTTPS。")
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
        detect_public_ip
        normalize_web_panel
        show_web_access
        exec "$PYTHON" "$APP_DIR/aliyun_guard.py" daemon "$@"
        ;;
    setup)
        detect_public_ip
        "$PYTHON" "$APP_DIR/manager.py" setup "$@"
        normalize_web_panel
        show_web_access
        printf '%s\n' "Docker 首次配置已保存。现在执行：docker compose up -d"
        ;;
    menu)
        need_config
        detect_public_ip
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
