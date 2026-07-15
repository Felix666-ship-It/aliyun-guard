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
        'aliyun-python-sdk-ecs>=4.24,<5'
}

stop_old_backend() {
    if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/$SERVICE_NAME" ]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    fi
}

write_payload() {
    say "${YELLOW}[3/6] 写入程序文件...${RESET}"
    mkdir -p "$APP_DIR/logs"
    cat > "$APP_DIR/aliyun_guard.py" <<'__AG_APP_PY_EOF__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Aliyun ECS keepalive and CDT traffic guard."""

import argparse
import contextlib
import datetime as dt
import json
import logging
from logging.handlers import TimedRotatingFileHandler
import os
from pathlib import Path
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import fcntl
except ImportError:  # pragma: no cover - the deployed target is Linux
    fcntl = None

try:
    from aliyunsdkcore.client import AcsClient
    from aliyunsdkcore.request import CommonRequest
    from aliyunsdkecs.request.v20140526.DescribeInstancesRequest import DescribeInstancesRequest
    from aliyunsdkecs.request.v20140526.StartInstanceRequest import StartInstanceRequest
    from aliyunsdkecs.request.v20140526.StopInstanceRequest import StopInstanceRequest
    SDK_IMPORT_ERROR = None
except ImportError as exc:  # Allows the manager to show a useful installation error.
    AcsClient = None
    CommonRequest = None
    DescribeInstancesRequest = None
    StartInstanceRequest = None
    StopInstanceRequest = None
    SDK_IMPORT_ERROR = exc


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
CONFIG_FILE = Path(os.environ.get("ALIYUN_GUARD_CONFIG", APP_DIR / "config.json"))
STATE_FILE = Path(os.environ.get("ALIYUN_GUARD_STATE", APP_DIR / "state.json"))
LOCK_FILE = Path(os.environ.get("ALIYUN_GUARD_LOCK", APP_DIR / "cycle.lock"))
LOG_DIR = Path(os.environ.get("ALIYUN_GUARD_LOG_DIR", APP_DIR / "logs"))
LOG_FILE = LOG_DIR / "guard.log"

DEFAULT_CONFIG = {
    "version": 1,
    "interval_seconds": 300,
    "notification_mode": "always",
    "notify_on_daemon_start": False,
    "force_ipv4": True,
    "telegram": {
        "bot_token": "",
        "chat_id": "",
        "timeout_seconds": 12,
        "retries": 3,
    },
    "start_wait_seconds": 90,
    "stop_wait_seconds": 45,
    "start_poll_seconds": 5,
    "users": [],
}

DEFAULT_BILLING = {
    "enabled": True,
    "site": "china",
    "endpoint": "business.aliyuncs.com",
    "region": "cn-hangzhou",
    "currency_code": "CNY",
    "currency_symbol": "¥",
}

LOGGER = logging.getLogger("aliyun_guard")
LOGGER.addHandler(logging.NullHandler())
_IPV4_PATCHED = False
_STOP_EVENT = threading.Event()


class GuardError(RuntimeError):
    pass


def configure_logging(console=True):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    LOGGER.handlers = []
    LOGGER.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
    file_handler = TimedRotatingFileHandler(
        str(LOG_FILE), when="midnight", interval=1, backupCount=14, encoding="utf-8"
    )
    file_handler.setFormatter(formatter)
    LOGGER.addHandler(file_handler)
    if console:
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(formatter)
        LOGGER.addHandler(console_handler)


def deep_merge(defaults, current):
    result = dict(defaults)
    for key, value in current.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_json(path, default):
    if not path.exists():
        return json.loads(json.dumps(default))
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError) as exc:
        raise GuardError("无法读取 {}: {}".format(path, exc))
    if not isinstance(value, dict):
        raise GuardError("{} 的顶层必须是 JSON 对象".format(path))
    return value


def load_config():
    config = deep_merge(DEFAULT_CONFIG, load_json(CONFIG_FILE, DEFAULT_CONFIG))
    validate_config(config)
    return config


def load_state():
    try:
        return load_json(STATE_FILE, {})
    except GuardError as exc:
        LOGGER.warning("状态文件损坏，将重新创建: %s", exc)
        return {}


def atomic_write_json(path, value, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(str(temporary), mode)
    os.replace(str(temporary), str(path))


def save_state(state):
    atomic_write_json(STATE_FILE, state)


def validate_config(config):
    try:
        interval = int(config.get("interval_seconds", 0))
    except (TypeError, ValueError):
        raise GuardError("interval_seconds 必须是整数")
    if interval < 60:
        raise GuardError("interval_seconds 不能小于 60 秒")
    for field, minimum in (("start_wait_seconds", 0), ("stop_wait_seconds", 0), ("start_poll_seconds", 1)):
        try:
            value = int(config.get(field, DEFAULT_CONFIG[field]))
        except (TypeError, ValueError):
            raise GuardError("{} 必须是整数".format(field))
        if value < minimum:
            raise GuardError("{} 不能小于 {}".format(field, minimum))
    mode = config.get("notification_mode")
    if mode not in ("always", "events", "errors"):
        raise GuardError("notification_mode 必须是 always、events 或 errors")
    users = config.get("users")
    if not isinstance(users, list):
        raise GuardError("users 必须是数组")
    seen = set()
    for index, user in enumerate(users, 1):
        if not isinstance(user, dict):
            raise GuardError("第 {} 个实例配置不是对象".format(index))
        for field in ("name", "ak", "sk", "region", "instance_id"):
            if not str(user.get(field, "")).strip():
                raise GuardError("第 {} 个实例缺少 {}".format(index, field))
        identity = (str(user["ak"]).strip(), str(user["region"]).strip(), str(user["instance_id"]).strip())
        if identity in seen:
            raise GuardError("第 {} 个实例重复配置".format(index))
        seen.add(identity)
        try:
            limit = float(user.get("traffic_limit_gb", 0))
        except (TypeError, ValueError):
            raise GuardError("第 {} 个实例的流量阈值无效".format(index))
        if limit <= 0:
            raise GuardError("第 {} 个实例的流量阈值必须大于 0".format(index))
        billing = get_billing_config(user)
        if billing.get("enabled", True):
            for field in ("endpoint", "region", "currency_code", "currency_symbol"):
                if not str(billing.get(field, "")).strip():
                    raise GuardError("第 {} 个实例的账单配置缺少 {}".format(index, field))


def enable_ipv4_only():
    global _IPV4_PATCHED
    if _IPV4_PATCHED:
        return
    original = socket.getaddrinfo

    def ipv4_getaddrinfo(host, port, family=0, socktype=0, proto=0, flags=0):
        results = original(host, port, family, socktype, proto, flags)
        ipv4_results = [item for item in results if item[0] == socket.AF_INET]
        return ipv4_results or results

    socket.getaddrinfo = ipv4_getaddrinfo
    _IPV4_PATCHED = True
    try:
        from aliyunsdkcore.vendored.requests.packages.urllib3.util import ssl_
        ssl_.HAS_SNI = True
    except Exception:
        pass


def compact_error(exc, limit=500, secrets=None):
    text = " ".join(str(exc).replace("\r", " ").replace("\n", " ").split())
    for secret in secrets or []:
        secret = str(secret or "")
        if secret:
            text = text.replace(secret, "***")
    return text[:limit] if text else exc.__class__.__name__


def require_sdk():
    if SDK_IMPORT_ERROR is not None:
        raise GuardError("阿里云 SDK 未安装: {}".format(SDK_IMPORT_ERROR))


def make_client(user, region=None):
    require_sdk()
    return AcsClient(
        str(user["ak"]).strip(),
        str(user["sk"]).strip(),
        region or str(user["region"]).strip(),
    )


def get_billing_config(user):
    configured = user.get("billing")
    if isinstance(configured, dict):
        return deep_merge(DEFAULT_BILLING, configured)
    # Compatible with the field names used by the referenced project.
    endpoint = str(user.get("bill_endpoint", DEFAULT_BILLING["endpoint"]) or DEFAULT_BILLING["endpoint"])
    international = endpoint != "business.aliyuncs.com"
    legacy = {
        "enabled": bool(user.get("billing_enabled", True)),
        "site": "international" if international else "china",
        "endpoint": endpoint,
        "region": "ap-southeast-1" if international else "cn-hangzhou",
        "currency_code": "USD" if international else "CNY",
        "currency_symbol": str(user.get("currency", "$" if international else "¥")),
    }
    return deep_merge(DEFAULT_BILLING, legacy)


def normalize_bill_items(data):
    items = data.get("Data", {}).get("Items", []) if isinstance(data, dict) else []
    if isinstance(items, dict):
        items = items.get("Item", [])
    if isinstance(items, dict):
        items = [items]
    if not isinstance(items, list):
        raise GuardError("BSS 返回的 Data.Items 格式无法识别")
    return [item for item in items if isinstance(item, dict)]


def query_instance_bill(user):
    require_sdk()
    billing = get_billing_config(user)
    if not billing.get("enabled", True):
        return None, None
    request = CommonRequest()
    request.set_protocol_type("https")
    request.set_accept_format("json")
    request.set_method("POST")
    request.set_domain(str(billing["endpoint"]).strip())
    request.set_version("2017-12-14")
    request.set_action_name("DescribeInstanceBill")
    request.set_connect_timeout(5000)
    request.set_read_timeout(15000)
    request.add_query_param("BillingCycle", dt.datetime.now().strftime("%Y-%m"))
    request.add_query_param("InstanceID", str(user["instance_id"]).strip())
    request.add_query_param("ProductCode", "ecs")
    request.add_query_param("PageNum", "1")
    request.add_query_param("PageSize", "300")
    response = make_client(user, str(billing["region"]).strip()).do_action_with_exception(request)
    data = json.loads(response.decode("utf-8"))
    if data.get("Success") is False:
        raise GuardError(
            "{}: {}".format(data.get("Code", "BSSRequestFailed"), data.get("Message", "请求失败"))
        )
    if "Data" not in data:
        raise GuardError("BSS 返回缺少 Data 字段")
    items = normalize_bill_items(data)
    amount = sum(float(item.get("PretaxAmount", 0) or 0) for item in items)
    currency = str(data.get("Data", {}).get("Currency", "") or "")
    if not currency:
        for item in items:
            if item.get("Currency"):
                currency = str(item["Currency"])
                break
    return amount, currency or str(billing.get("currency_code", ""))


def query_cdt_traffic_gb(user):
    require_sdk()
    request = CommonRequest()
    request.set_protocol_type("https")
    request.set_accept_format("json")
    request.set_method("POST")
    request.set_domain("cdt.aliyuncs.com")
    request.set_version("2021-08-13")
    request.set_action_name("ListCdtInternetTraffic")
    request.set_connect_timeout(5000)
    request.set_read_timeout(15000)
    response = make_client(user, "cn-hangzhou").do_action_with_exception(request)
    data = json.loads(response.decode("utf-8"))
    details = data.get("TrafficDetails", [])
    total_bytes = sum(float(item.get("Traffic", 0) or 0) for item in details)
    return total_bytes / (1024.0 ** 3)


def query_instance_status(user):
    require_sdk()
    request = DescribeInstancesRequest()
    request.set_protocol_type("https")
    request.set_accept_format("json")
    request.set_InstanceIds(json.dumps([str(user["instance_id"]).strip()]))
    request.set_connect_timeout(5000)
    request.set_read_timeout(15000)
    response = make_client(user).do_action_with_exception(request)
    data = json.loads(response.decode("utf-8"))
    instances = data.get("Instances", {}).get("Instance", [])
    if not instances:
        raise GuardError("区域 {} 中未找到实例 {}".format(user["region"], user["instance_id"]))
    return str(instances[0].get("Status", "Unknown"))


def start_instance(user):
    require_sdk()
    request = StartInstanceRequest()
    request.set_protocol_type("https")
    request.set_accept_format("json")
    request.set_InstanceId(str(user["instance_id"]).strip())
    request.set_connect_timeout(5000)
    request.set_read_timeout(15000)
    make_client(user).do_action_with_exception(request)


def stop_instance(user):
    require_sdk()
    request = StopInstanceRequest()
    request.set_protocol_type("https")
    request.set_accept_format("json")
    request.set_InstanceId(str(user["instance_id"]).strip())
    request.set_connect_timeout(5000)
    request.set_read_timeout(15000)
    make_client(user).do_action_with_exception(request)


def validate_user_connection(user, force_ipv4=True):
    if force_ipv4:
        enable_ipv4_only()
    result = {
        "ok": False,
        "traffic_gb": None,
        "status": None,
        "bill_amount": None,
        "bill_currency": None,
        "billing_enabled": bool(get_billing_config(user).get("enabled", True)),
        "errors": [],
    }
    try:
        result["traffic_gb"] = query_cdt_traffic_gb(user)
    except Exception as exc:
        result["errors"].append(
            "CDT 流量查询失败: {}".format(compact_error(exc, secrets=(user.get("ak"), user.get("sk"))))
        )
    try:
        result["status"] = query_instance_status(user)
    except Exception as exc:
        result["errors"].append(
            "ECS 实例查询失败: {}".format(compact_error(exc, secrets=(user.get("ak"), user.get("sk"))))
        )
    if result["billing_enabled"]:
        try:
            result["bill_amount"], result["bill_currency"] = query_instance_bill(user)
        except Exception as exc:
            result["errors"].append(
                "BSS 账单查询失败: {}".format(
                    compact_error(exc, secrets=(user.get("ak"), user.get("sk")))
                )
            )
    result["ok"] = not result["errors"]
    return result


def telegram_api(config, method, data=None):
    token = str(config.get("bot_token", "")).strip()
    if not token:
        raise GuardError("Telegram Bot Token 未配置")
    timeout = max(3, int(config.get("timeout_seconds", 12)))
    retries = max(1, min(5, int(config.get("retries", 3))))
    url = "https://api.telegram.org/bot{}/{}".format(token, method)
    payload = urllib.parse.urlencode(data or {}).encode("utf-8")
    body = ""
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(url, data=payload, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8", "replace")
            break
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            if exc.code not in (429, 500, 502, 503, 504) or attempt >= retries:
                raise GuardError("Telegram HTTP {}: {}".format(exc.code, body[:300]))
            time.sleep(min(2 ** attempt, 8))
        except Exception as exc:
            if attempt >= retries:
                raise GuardError(
                    "Telegram 网络请求失败（已重试 {} 次）: {}".format(
                        retries, compact_error(exc, secrets=(token,))
                    )
                )
            time.sleep(min(2 ** attempt, 8))
    try:
        result = json.loads(body)
    except ValueError:
        raise GuardError("Telegram 返回了无效 JSON")
    if not result.get("ok"):
        raise GuardError("Telegram API 拒绝请求: {}".format(result.get("description", body[:300])))
    return result.get("result")


def split_message(text, limit=3900):
    chunks = []
    current = []
    current_size = 0
    for line in text.splitlines(True):
        if len(line) > limit:
            if current:
                chunks.append("".join(current).rstrip())
                current = []
                current_size = 0
            for offset in range(0, len(line), limit):
                chunks.append(line[offset:offset + limit].rstrip())
            continue
        if current and current_size + len(line) > limit:
            chunks.append("".join(current).rstrip())
            current = []
            current_size = 0
        current.append(line)
        current_size += len(line)
    if current:
        chunks.append("".join(current).rstrip())
    return chunks or [""]


def send_telegram_message(telegram, text):
    chat_id = str(telegram.get("chat_id", "")).strip()
    if not chat_id:
        raise GuardError("Telegram Chat ID 未配置")
    results = []
    for chunk in split_message(text):
        results.append(telegram_api(telegram, "sendMessage", {"chat_id": chat_id, "text": chunk}))
    return results


def test_telegram(telegram):
    bot = telegram_api(telegram, "getMe")
    username = bot.get("username", "unknown") if isinstance(bot, dict) else "unknown"
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    send_telegram_message(telegram, "阿里云保活通知测试成功\n时间: {}\nBot: @{}".format(now, username))
    return username


def wait_for_status(user, expected, timeout, poll_seconds):
    deadline = time.monotonic() + max(0, timeout)
    latest = None
    latest_error = None
    while time.monotonic() < deadline and not _STOP_EVENT.is_set():
        _STOP_EVENT.wait(max(1, poll_seconds))
        if _STOP_EVENT.is_set():
            break
        try:
            latest = query_instance_status(user)
            latest_error = None
            if latest == expected:
                return latest, None
        except Exception as exc:
            latest_error = compact_error(exc, secrets=(user.get("ak"), user.get("sk")))
    return latest, latest_error


def check_one(user, config, dry_run=False):
    name = str(user.get("name") or user.get("instance_id") or "未命名")
    billing = get_billing_config(user)
    result = {
        "name": name,
        "instance_id": str(user.get("instance_id", "")),
        "traffic_gb": None,
        "limit_gb": float(user.get("traffic_limit_gb", 0) or 0),
        "status_before": None,
        "status_after": None,
        "billing_enabled": bool(billing.get("enabled", True)),
        "bill_amount": None,
        "bill_currency": None,
        "bill_symbol": str(billing.get("currency_symbol", "")),
        "bill_error": None,
        "action": "none",
        "action_performed": False,
        "level": "ok",
        "message": "",
        "errors": [],
        "paused": bool(user.get("paused", False)),
    }
    if result["paused"]:
        result["level"] = "paused"
        result["message"] = "监控已暂停"
        LOGGER.info("[%s] 监控已暂停", name)
        return result

    user_secrets = (user.get("ak"), user.get("sk"))

    try:
        result["traffic_gb"] = query_cdt_traffic_gb(user)
    except Exception as exc:
        message = "CDT 流量查询失败: {}".format(compact_error(exc, secrets=user_secrets))
        result["errors"].append(message)
        LOGGER.error("[%s] %s", name, message)

    try:
        result["status_before"] = query_instance_status(user)
        result["status_after"] = result["status_before"]
    except Exception as exc:
        message = "ECS 实例查询失败: {}".format(compact_error(exc, secrets=user_secrets))
        result["errors"].append(message)
        LOGGER.error("[%s] %s", name, message)

    core_error_count = len(result["errors"])
    if result["billing_enabled"]:
        try:
            result["bill_amount"], result["bill_currency"] = query_instance_bill(user)
            LOGGER.info(
                "[%s] 本月实例账单 %s%.2f (%s)",
                name,
                result["bill_symbol"],
                result["bill_amount"],
                result["bill_currency"],
            )
        except Exception as exc:
            result["bill_error"] = "BSS 账单查询失败: {}".format(
                compact_error(exc, secrets=user_secrets)
            )
            result["errors"].append(result["bill_error"])
            LOGGER.error("[%s] %s", name, result["bill_error"])

    if core_error_count:
        result["level"] = "error"
        result["message"] = "CDT 或 ECS 核心查询失败，本轮未执行开关机"
        return result

    traffic = result["traffic_gb"]
    limit = result["limit_gb"]
    status = result["status_before"]
    actions_enabled = bool(user.get("actions_enabled", True))
    wait_seconds = max(0, int(config.get("start_wait_seconds", 90)))
    stop_wait_seconds = max(0, int(config.get("stop_wait_seconds", 45)))
    poll_seconds = max(1, int(config.get("start_poll_seconds", 5)))

    if traffic < limit:
        if status == "Running":
            result["message"] = "流量安全，实例运行正常"
        elif status == "Stopped":
            result["action"] = "start"
            if dry_run:
                result["level"] = "action"
                result["message"] = "演练：应启动实例"
            elif not actions_enabled:
                result["level"] = "warning"
                result["message"] = "流量安全但实例已停止，自动操作未启用"
            else:
                try:
                    start_instance(user)
                    result["action_performed"] = True
                    LOGGER.info("[%s] 已提交启动请求", name)
                    latest, poll_error = wait_for_status(user, "Running", wait_seconds, poll_seconds)
                    if latest:
                        result["status_after"] = latest
                    if latest == "Running":
                        result["level"] = "action"
                        result["message"] = "已启动并确认实例运行"
                    elif poll_error:
                        result["level"] = "warning"
                        result["message"] = "已提交启动请求，状态复查失败: {}".format(poll_error)
                    else:
                        result["level"] = "warning"
                        result["message"] = "已提交启动请求，等待 {} 秒后状态为 {}".format(
                            wait_seconds, latest or "Unknown"
                        )
                except Exception as exc:
                    result["level"] = "error"
                    result["message"] = "启动实例失败: {}".format(
                        compact_error(exc, secrets=user_secrets)
                    )
                    result["errors"].append(result["message"])
                    LOGGER.error("[%s] %s", name, result["message"])
        else:
            result["level"] = "warning"
            result["message"] = "流量安全，实例处于过渡状态 {}，本轮不操作".format(status)
    else:
        if status == "Running":
            result["action"] = "stop"
            if dry_run:
                result["level"] = "action"
                result["message"] = "演练：流量达到阈值，应停止实例"
            elif not actions_enabled:
                result["level"] = "warning"
                result["message"] = "流量达到阈值，但自动操作未启用"
            else:
                try:
                    stop_instance(user)
                    result["action_performed"] = True
                    LOGGER.warning("[%s] 流量达到阈值，已提交停止请求", name)
                    latest, poll_error = wait_for_status(user, "Stopped", stop_wait_seconds, poll_seconds)
                    if latest:
                        result["status_after"] = latest
                    if latest == "Stopped":
                        result["level"] = "action"
                        result["message"] = "流量达到阈值，已停止并确认实例关机"
                    elif poll_error:
                        result["level"] = "warning"
                        result["message"] = "已提交停止请求，状态复查失败: {}".format(poll_error)
                    else:
                        result["level"] = "warning"
                        result["message"] = "已提交停止请求，等待 {} 秒后状态为 {}".format(
                            stop_wait_seconds, latest or "Unknown"
                        )
                except Exception as exc:
                    result["level"] = "error"
                    result["message"] = "停止实例失败: {}".format(
                        compact_error(exc, secrets=user_secrets)
                    )
                    result["errors"].append(result["message"])
                    LOGGER.error("[%s] %s", name, result["message"])
        elif status == "Stopped":
            result["level"] = "warning"
            result["message"] = "流量达到阈值，实例保持关机"
        else:
            result["level"] = "warning"
            result["message"] = "流量达到阈值，实例状态为 {}，本轮不重复操作".format(status)

    if result["errors"]:
        result["level"] = "error"

    LOGGER.info(
        "[%s] 流量 %.2f/%.2f GB，状态 %s，结果: %s",
        name,
        traffic,
        limit,
        status,
        result["message"],
    )
    return result


def level_icon(level):
    return {
        "ok": "[OK]",
        "action": "[ACTION]",
        "warning": "[WARN]",
        "error": "[ERROR]",
        "paused": "[PAUSED]",
    }.get(level, "[INFO]")


def build_summary(results, started_at, duration, dry_run=False):
    error_count = sum(1 for item in results if item["level"] == "error")
    action_count = sum(1 for item in results if item.get("action_performed", False))
    warning_count = sum(1 for item in results if item["level"] == "warning")
    title = "阿里云保活检测完成"
    if dry_run:
        title += "（演练）"
    lines = [
        title,
        "时间: {}".format(started_at.strftime("%Y-%m-%d %H:%M:%S")),
        "汇总: {} 个实例，{} 个动作，{} 个警告，{} 个错误".format(
            len(results), action_count, warning_count, error_count
        ),
        "",
    ]
    for item in results:
        lines.append("{} {} ({})".format(level_icon(item["level"]), item["name"], item["instance_id"]))
        if item["paused"]:
            lines.append("  结果: {}".format(item["message"]))
            continue
        if item["traffic_gb"] is None:
            lines.append("  流量: 查询失败 / {:.2f} GB".format(item["limit_gb"]))
        else:
            lines.append("  流量: {:.2f} / {:.2f} GB".format(item["traffic_gb"], item["limit_gb"]))
        status = item["status_before"] or "查询失败"
        if item["status_after"] and item["status_after"] != item["status_before"]:
            status = "{} -> {}".format(status, item["status_after"])
        lines.append("  ECS: {}".format(status))
        if item.get("billing_enabled", True):
            if item.get("bill_error"):
                lines.append("  账单: 查询失败")
            elif item.get("bill_amount") is not None:
                currency = str(item.get("bill_currency") or "")
                symbol = item.get("bill_symbol") or {"CNY": "¥", "USD": "$"}.get(currency, "")
                if currency == "CNY":
                    symbol = "¥"
                elif currency == "USD":
                    symbol = "$"
                lines.append("  账单: {}{:.2f} ({})".format(symbol, item["bill_amount"], currency or "未知币种"))
            else:
                lines.append("  账单: 无数据")
        else:
            lines.append("  账单: 已关闭")
        lines.append("  结果: {}".format(item["message"]))
        for error in item.get("errors", []):
            if error != item["message"]:
                lines.append("  错误: {}".format(error))
    lines.extend(["", "耗时: {:.1f} 秒".format(duration)])
    return "\n".join(lines), error_count, action_count, warning_count


def should_notify(config, results, previous_state):
    mode = config.get("notification_mode", "always")
    if mode == "always":
        return True
    if any(item["level"] == "error" for item in results):
        return True
    if mode == "errors":
        return False
    if any(item["action"] != "none" or item["level"] == "warning" for item in results):
        return True
    previous = previous_state.get("instances", {})
    for item in results:
        old = previous.get(item["instance_id"], {})
        if old.get("status_after") and old.get("status_after") != item.get("status_after"):
            return True
    return False


def update_state(state, results, started_at, duration, summary, error_count, notify_error=None):
    state["last_cycle_started_at"] = started_at.isoformat(timespec="seconds")
    state["last_cycle_finished_at"] = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    state["last_cycle_duration_seconds"] = round(duration, 3)
    state["last_cycle_error_count"] = error_count
    state["last_cycle_ok"] = error_count == 0
    state["last_summary"] = summary
    state["cycle_count"] = int(state.get("cycle_count", 0)) + 1
    state["telegram_error"] = notify_error
    state.setdefault("instances", {})
    for item in results:
        state["instances"][item["instance_id"]] = {
            "name": item["name"],
            "traffic_gb": item["traffic_gb"],
            "limit_gb": item["limit_gb"],
            "status_after": item["status_after"],
            "bill_amount": item.get("bill_amount"),
            "bill_currency": item.get("bill_currency"),
            "bill_error": item.get("bill_error"),
            "level": item["level"],
            "message": item["message"],
            "checked_at": started_at.isoformat(timespec="seconds"),
        }


@contextlib.contextmanager
def cycle_lock():
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    handle = LOCK_FILE.open("a+")
    locked = True
    try:
        if fcntl is not None:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                locked = False
        yield locked
    finally:
        if locked and fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def run_cycle(dry_run=False, no_notify=False):
    config = load_config()
    if config.get("force_ipv4", True):
        enable_ipv4_only()
    started_at = dt.datetime.now().astimezone()
    monotonic_start = time.monotonic()
    previous_state = load_state()
    results = []
    for user in config.get("users", []):
        if _STOP_EVENT.is_set():
            break
        results.append(check_one(user, config, dry_run=dry_run))
    duration = time.monotonic() - monotonic_start
    summary, error_count, action_count, warning_count = build_summary(
        results, started_at, duration, dry_run=dry_run
    )
    print(summary)
    notify_error = None
    if not no_notify and should_notify(config, results, previous_state):
        try:
            send_telegram_message(config.get("telegram", {}), summary)
            LOGGER.info("Telegram 本轮汇总通知发送成功")
        except Exception as exc:
            notify_error = compact_error(exc)
            LOGGER.error("Telegram 本轮汇总通知发送失败: %s", notify_error)
    update_state(previous_state, results, started_at, duration, summary, error_count, notify_error)
    save_state(previous_state)
    return 1 if error_count else 0


def is_due(config, state, now=None):
    now = now or time.time()
    last = state.get("last_cycle_epoch")
    if last is None:
        finished = state.get("last_cycle_finished_at")
        if finished:
            try:
                last = dt.datetime.fromisoformat(finished).timestamp()
            except (TypeError, ValueError):
                last = None
    if last is None:
        return True
    return now - float(last) >= int(config["interval_seconds"])


def run_scheduled():
    if (APP_DIR / "disabled").exists():
        return 0
    with cycle_lock() as locked:
        if not locked:
            LOGGER.info("已有检测正在运行，本次计划任务跳过")
            return 0
        config = load_config()
        state = load_state()
        if not is_due(config, state):
            return 0
        state["last_cycle_epoch"] = time.time()
        save_state(state)
        return run_cycle()


def handle_stop(signum, frame):
    del signum, frame
    _STOP_EVENT.set()


def run_daemon():
    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    config = load_config()
    if config.get("force_ipv4", True):
        enable_ipv4_only()
    if config.get("notify_on_daemon_start", False):
        try:
            send_telegram_message(
                config.get("telegram", {}),
                "阿里云保活服务已启动\n时间: {}".format(dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
            )
        except Exception as exc:
            LOGGER.error("启动通知发送失败: %s", compact_error(exc))
    LOGGER.info("保活服务已启动")
    while not _STOP_EVENT.is_set():
        cycle_started = time.monotonic()
        with cycle_lock() as locked:
            if locked:
                try:
                    run_cycle()
                except Exception as exc:
                    LOGGER.exception("本轮检测发生未处理错误: %s", compact_error(exc))
            else:
                LOGGER.warning("已有检测正在运行，本轮跳过")
        try:
            interval = int(load_config().get("interval_seconds", 300))
        except Exception:
            interval = 300
        remaining = max(1, interval - (time.monotonic() - cycle_started))
        _STOP_EVENT.wait(remaining)
    LOGGER.info("保活服务已停止")
    return 0


def show_status():
    try:
        config = load_config()
    except Exception as exc:
        print("配置状态: 错误 - {}".format(exc))
        return 1
    state = load_state()
    print("配置状态: 正常")
    print("实例数量: {}".format(len(config.get("users", []))))
    print("检测间隔: {} 秒".format(config["interval_seconds"]))
    print("通知模式: {}".format(config["notification_mode"]))
    print("累计检测: {} 次".format(state.get("cycle_count", 0)))
    print("最后完成: {}".format(state.get("last_cycle_finished_at", "尚未运行")))
    print("最后结果: {}".format("正常" if state.get("last_cycle_ok") else "有错误或尚未运行"))
    if state.get("telegram_error"):
        print("通知错误: {}".format(state["telegram_error"]))
    return 0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="阿里云 ECS 保活与 CDT 流量止损")
    subparsers = parser.add_subparsers(dest="command")
    once = subparsers.add_parser("once", help="立即执行一轮检测")
    once.add_argument("--dry-run", action="store_true", help="仅演练，不执行开关机")
    once.add_argument("--no-notify", action="store_true", help="本轮不发送 Telegram")
    subparsers.add_parser("scheduled", help="由 cron 调用，仅在到期时执行")
    subparsers.add_parser("daemon", help="以前台守护进程运行")
    subparsers.add_parser("status", help="显示最近运行状态")
    subparsers.add_parser("test-telegram", help="测试 Telegram 配置")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    configure_logging(console=True)
    command = args.command or "once"
    try:
        if command == "daemon":
            return run_daemon()
        if command == "scheduled":
            return run_scheduled()
        if command == "status":
            return show_status()
        if command == "test-telegram":
            config = load_config()
            if config.get("force_ipv4", True):
                enable_ipv4_only()
            username = test_telegram(config.get("telegram", {}))
            print("Telegram 测试成功: @{}".format(username))
            return 0
        with cycle_lock() as locked:
            if not locked:
                print("已有检测正在运行，请稍后再试", file=sys.stderr)
                return 3
            return run_cycle(dry_run=args.dry_run, no_notify=args.no_notify)
    except GuardError as exc:
        LOGGER.error("%s", exc)
        return 2
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        LOGGER.exception("未处理错误: %s", compact_error(exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
__AG_APP_PY_EOF__
    cat > "$APP_DIR/manager.py" <<'__AG_MANAGER_PY_EOF__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Interactive configuration manager for Aliyun Guard."""

import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.request

import aliyun_guard as guard


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
CONFIG_FILE = Path(os.environ.get("ALIYUN_GUARD_CONFIG", APP_DIR / "config.json"))
CONTROL_FILE = APP_DIR / "control.sh"
UPDATE_BASE_URL = os.environ.get(
    "ALIYUN_GUARD_UPDATE_BASE",
    "https://raw.githubusercontent.com/Felix666-ship-It/aliyun-guard/main",
).rstrip("/")
APP_VERSION = "1.1.3"
LOCAL_RELEASE_ID = "83560f993da2e8069a182cab27435cbb33831841d419b9df07a6947e65ac4b08"
UPDATE_MANIFEST_NAME = "version.json"
UPDATE_CHECK_TIMEOUT_SECONDS = 5
ANSI_YELLOW = "\033[33m"
ANSI_RESET = "\033[0m"

REGIONS = [
    ("cn-hongkong", "中国香港"),
    ("ap-southeast-1", "新加坡"),
    ("ap-southeast-3", "马来西亚（吉隆坡）"),
    ("ap-southeast-5", "印度尼西亚（雅加达）"),
    ("ap-northeast-1", "日本（东京）"),
    ("us-west-1", "美国（硅谷）"),
    ("us-east-1", "美国（弗吉尼亚）"),
    ("eu-central-1", "德国（法兰克福）"),
    ("eu-west-1", "英国（伦敦）"),
    ("me-east-1", "阿联酋（迪拜）"),
    ("cn-shanghai", "中国内地（上海）"),
    ("cn-beijing", "中国内地（北京）"),
    ("cn-shenzhen", "中国内地（深圳）"),
]


def line(char="=", width=62):
    print(char * width)


def title(text):
    print()
    line()
    print(text)
    line()


def yellow_text(text):
    if os.environ.get("NO_COLOR") is not None or os.environ.get("TERM") == "dumb":
        return text
    try:
        if not sys.stdout.isatty():
            return text
    except (AttributeError, OSError):
        return text
    return "{}{}{}".format(ANSI_YELLOW, text, ANSI_RESET)


def prompt(text, default=None, required=False):
    suffix = ""
    if default not in (None, ""):
        suffix = " [{}]".format(default)
    while True:
        try:
            value = input("{}{}: ".format(text, suffix)).strip()
        except EOFError:
            print("\n未检测到交互终端。请直接运行 aliyun-guard。", file=sys.stderr)
            raise SystemExit(2)
        if value:
            return value
        if default is not None:
            return str(default)
        if not required:
            return ""
        print("此项不能为空。")


def prompt_secret(text, keep_existing=False):
    suffix = "（回车保留当前值）" if keep_existing else ""
    while True:
        try:
            value = getpass.getpass("{}{}: ".format(text, suffix)).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            raise
        if value or keep_existing:
            return value
        print("此项不能为空。")


def yes_no(text, default=True):
    hint = "Y/n" if default else "y/N"
    while True:
        value = prompt("{} ({})".format(text, hint)).lower()
        if not value:
            return default
        if value in ("y", "yes", "1", "是"):
            return True
        if value in ("n", "no", "0", "否"):
            return False
        print("请输入 y 或 n。")


def prompt_int(text, default, minimum=None, maximum=None):
    while True:
        value = prompt(text, default)
        try:
            number = int(value)
        except ValueError:
            print("请输入整数。")
            continue
        if minimum is not None and number < minimum:
            print("不能小于 {}。".format(minimum))
            continue
        if maximum is not None and number > maximum:
            print("不能大于 {}。".format(maximum))
            continue
        return number


def prompt_float(text, default, minimum=None):
    while True:
        value = prompt(text, default)
        try:
            number = float(value)
        except ValueError:
            print("请输入数字。")
            continue
        if minimum is not None and number < minimum:
            print("不能小于 {}。".format(minimum))
            continue
        return number


def default_config():
    return json.loads(json.dumps(guard.DEFAULT_CONFIG, ensure_ascii=False))


def load_config(allow_missing=False):
    if not CONFIG_FILE.exists():
        if allow_missing:
            return default_config()
        raise guard.GuardError("配置文件不存在: {}".format(CONFIG_FILE))
    return guard.load_config()


def save_config(config):
    guard.validate_config(config)
    guard.atomic_write_json(CONFIG_FILE, config, mode=0o600)


def mask_key(value):
    value = str(value or "")
    if len(value) <= 8:
        return "*" * len(value)
    return "{}...{}".format(value[:4], value[-4:])


def choose_region(current=None):
    print("\n请选择 ECS 区域：")
    for index, (code, label) in enumerate(REGIONS, 1):
        marker = "（当前）" if current == code else ""
        print(" {:>2}) {:<22} {} {}".format(index, code, label, marker))
    print(" {:>2}) 手动输入其他 Region ID".format(len(REGIONS) + 1))
    default_index = None
    for index, (code, _label) in enumerate(REGIONS, 1):
        if code == current:
            default_index = index
            break
    selection = prompt_int("区域序号", default_index or 1, 1, len(REGIONS) + 1)
    if selection <= len(REGIONS):
        return REGIONS[selection - 1][0]
    return prompt("Region ID（例如 cn-hongkong）", current, required=True)


def configure_billing(existing_user=None):
    existing_user = existing_user or {}
    current = guard.get_billing_config(existing_user)
    title("BSS 实例账单配置")
    print(" 1) 阿里云中国站（business.aliyuncs.com / CNY）")
    print(" 2) 阿里云国际站（business.ap-southeast-1.aliyuncs.com / USD）")
    print(" 3) 自定义 BSS Endpoint")
    print(" 4) 关闭该实例的账单查询")
    default_choice = {"china": 1, "international": 2, "custom": 3}.get(current.get("site"), 1)
    if not current.get("enabled", True):
        default_choice = 4
    choice = prompt_int("账号站点序号", default_choice, 1, 4)
    if choice == 1:
        return {
            "enabled": True,
            "site": "china",
            "endpoint": "business.aliyuncs.com",
            "region": "cn-hangzhou",
            "currency_code": "CNY",
            "currency_symbol": "¥",
        }
    if choice == 2:
        return {
            "enabled": True,
            "site": "international",
            "endpoint": "business.ap-southeast-1.aliyuncs.com",
            "region": "ap-southeast-1",
            "currency_code": "USD",
            "currency_symbol": "$",
        }
    if choice == 4:
        current["enabled"] = False
        return current
    return {
        "enabled": True,
        "site": "custom",
        "endpoint": prompt("BSS Endpoint", current.get("endpoint"), required=True),
        "region": prompt("BSS 签名 Region", current.get("region"), required=True),
        "currency_code": prompt("币种代码", current.get("currency_code", "CNY"), required=True).upper(),
        "currency_symbol": prompt("币种符号", current.get("currency_symbol", "¥"), required=True),
    }


def configure_telegram(config, initial=False):
    title("Telegram 通知配置")
    current = config.setdefault("telegram", {})
    print("Token 和 Chat ID 只保存在本机 root 可读的配置文件中。")
    token = prompt_secret("Telegram Bot Token", keep_existing=bool(current.get("bot_token")))
    if token:
        current["bot_token"] = token
    current["chat_id"] = prompt("Telegram Chat ID", current.get("chat_id"), required=True)
    current["timeout_seconds"] = prompt_int(
        "Telegram 请求超时（秒）", current.get("timeout_seconds", 12), 3, 60
    )
    current["retries"] = prompt_int("Telegram 临时失败重试次数", current.get("retries", 3), 1, 5)
    if config.get("force_ipv4", True):
        guard.enable_ipv4_only()
    while True:
        print("正在发送测试消息...")
        try:
            username = guard.test_telegram(current)
            print("Telegram 测试成功，Bot: @{}".format(username))
            return True
        except Exception as exc:
            print("Telegram 测试失败: {}".format(guard.compact_error(exc)))
        if yes_no("重新输入 Telegram 配置", default=True):
            token = prompt_secret("Telegram Bot Token", keep_existing=bool(current.get("bot_token")))
            if token:
                current["bot_token"] = token
            current["chat_id"] = prompt("Telegram Chat ID", current.get("chat_id"), required=True)
            continue
        if yes_no("网络可能临时异常，仍保存当前 Telegram 配置", default=False):
            return False
        if initial:
            print("首次安装建议先确认通知链路可用。")


def collect_user(existing=None):
    existing = dict(existing or {})
    title("{}监控实例".format("编辑" if existing else "添加"))
    user = dict(existing)
    user["name"] = prompt("备注名称", existing.get("name"), required=True)
    user["ak"] = prompt_secret("AccessKey ID", keep_existing=bool(existing.get("ak"))) or existing.get("ak", "")
    user["sk"] = prompt_secret("AccessKey Secret", keep_existing=bool(existing.get("sk"))) or existing.get("sk", "")
    user["region"] = choose_region(existing.get("region"))
    user["instance_id"] = prompt(
        "ECS 实例 ID（以 i- 开头）", existing.get("instance_id"), required=True
    )
    user["billing"] = configure_billing(existing)
    user.pop("bill_endpoint", None)
    user.pop("currency", None)
    user.pop("billing_enabled", None)
    user["traffic_limit_gb"] = prompt_float(
        "当月 CDT 流量关机阈值（GB）", existing.get("traffic_limit_gb", 180), 0.01
    )
    user["actions_enabled"] = yes_no(
        "允许脚本自动启动/停止该实例", bool(existing.get("actions_enabled", True))
    )
    user["paused"] = bool(existing.get("paused", False))
    return user


def test_user(user, config):
    print("\n正在只读校验 AccessKey、CDT 权限、ECS 区域和实例 ID...")
    result = guard.validate_user_connection(user, bool(config.get("force_ipv4", True)))
    if result["traffic_gb"] is not None:
        print("CDT 流量: {:.2f} GB".format(result["traffic_gb"]))
    if result["status"] is not None:
        print("ECS 状态: {}".format(result["status"]))
    if result["billing_enabled"] and result["bill_amount"] is not None:
        billing = guard.get_billing_config(user)
        symbol = billing.get("currency_symbol", "")
        print(
            "BSS 账单: {}{:.2f} ({})".format(
                symbol, result["bill_amount"], result["bill_currency"] or "未知币种"
            )
        )
    if result["ok"]:
        print("CDT、ECS 和 BSS 校验全部成功。")
        return True
    print("校验失败：")
    for error in result["errors"]:
        print(" - {}".format(error))
    return False


def add_user(config, require_success=False):
    while True:
        user = collect_user()
        duplicate = any(
            item.get("ak") == user.get("ak")
            and item.get("region") == user.get("region")
            and item.get("instance_id") == user.get("instance_id")
            for item in config.get("users", [])
        )
        if duplicate:
            print("该 AccessKey、区域和实例 ID 已存在，不能重复添加。")
            if yes_no("重新输入", True):
                continue
            return False
        if test_user(user, config):
            config.setdefault("users", []).append(user)
            save_config(config)
            print("实例已保存。")
            return True
        if not require_success and yes_no("校验失败，仍然保存该配置", False):
            config.setdefault("users", []).append(user)
            save_config(config)
            print("实例已保存，但定时检测会继续报告上述错误。")
            return True
        if not yes_no("重新输入实例配置", True):
            return False


def list_users(config):
    users = config.get("users", [])
    print()
    if not users:
        print("当前没有监控实例。")
        return
    print("序号  状态    名称                  Region                实例 ID                 账单       AccessKey")
    line("-")
    for index, user in enumerate(users, 1):
        status = "暂停" if user.get("paused") else "运行"
        billing = guard.get_billing_config(user)
        bill_site = {
            "china": "中国站",
            "international": "国际站",
            "custom": "自定义",
        }.get(billing.get("site"), "自定义") if billing.get("enabled", True) else "关闭"
        print(
            "{:<5} {:<7} {:<21} {:<21} {:<23} {:<10} {}".format(
                index,
                status,
                str(user.get("name", ""))[:20],
                str(user.get("region", ""))[:20],
                str(user.get("instance_id", ""))[:22],
                bill_site,
                mask_key(user.get("ak")),
            )
        )


def choose_user(config, action):
    users = config.get("users", [])
    if not users:
        print("当前没有监控实例。")
        return None
    list_users(config)
    index = prompt_int("选择要{}的实例序号".format(action), 1, 1, len(users))
    return index - 1


def edit_user(config):
    index = choose_user(config, "编辑")
    if index is None:
        return
    candidate = collect_user(config["users"][index])
    if test_user(candidate, config) or yes_no("校验失败，仍保存修改", False):
        config["users"][index] = candidate
        save_config(config)
        print("实例配置已更新。")


def toggle_user(config):
    index = choose_user(config, "暂停/恢复")
    if index is None:
        return
    user = config["users"][index]
    user["paused"] = not bool(user.get("paused"))
    save_config(config)
    print("{} 已{}。".format(user.get("name"), "暂停" if user["paused"] else "恢复"))


def delete_user(config):
    index = choose_user(config, "删除")
    if index is None:
        return
    user = config["users"][index]
    if yes_no("确认删除 {} ({})".format(user.get("name"), user.get("instance_id")), False):
        config["users"].pop(index)
        save_config(config)
        print("实例已删除。")


def choose_notification_mode(current):
    modes = [
        ("always", "每轮检测完成都通知"),
        ("events", "仅动作、警告、错误或状态变化时通知"),
        ("errors", "仅检测错误时通知"),
    ]
    print("\n通知模式：")
    default_index = 1
    for index, (value, label) in enumerate(modes, 1):
        if value == current:
            default_index = index
        print(" {}) {}{}".format(index, label, "（当前）" if value == current else ""))
    return modes[prompt_int("模式序号", default_index, 1, len(modes)) - 1][0]


def edit_settings(config):
    title("全局设置")
    config["interval_seconds"] = prompt_int(
        "检测间隔（秒，最小 60）", config.get("interval_seconds", 300), 60, 86400
    )
    config["notification_mode"] = choose_notification_mode(config.get("notification_mode", "always"))
    config["force_ipv4"] = yes_no("网络请求优先使用 IPv4", bool(config.get("force_ipv4", True)))
    config["notify_on_daemon_start"] = yes_no(
        "服务每次启动时发送通知", bool(config.get("notify_on_daemon_start", False))
    )
    config["start_wait_seconds"] = prompt_int(
        "启动实例后等待确认时间（秒）", config.get("start_wait_seconds", 90), 0, 600
    )
    config["stop_wait_seconds"] = prompt_int(
        "停止实例后等待确认时间（秒）", config.get("stop_wait_seconds", 45), 0, 600
    )
    save_config(config)
    print("全局设置已保存。服务会在下一轮自动读取新配置。")


def run_control(*arguments):
    if not CONTROL_FILE.exists():
        print("控制脚本不存在: {}".format(CONTROL_FILE))
        return 1
    return subprocess.call([str(CONTROL_FILE)] + list(arguments))


def run_once(dry_run=False):
    command = [sys.executable, str(APP_DIR / "aliyun_guard.py"), "once"]
    if dry_run:
        command.append("--dry-run")
    return subprocess.call(command)


def show_logs(lines=80):
    path = guard.LOG_FILE
    if not path.exists():
        print("日志尚未生成: {}".format(path))
        return
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        content = handle.readlines()[-lines:]
    print("".join(content), end="")


def download_update_file(url, timeout=30, retries=3):
    last_error = None
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(url, headers={"User-Agent": "Aliyun-Guard-Updater"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except Exception as exc:
            last_error = exc
            if attempt < retries:
                time.sleep(min(2 ** attempt, 8))
    raise guard.GuardError("下载失败（已重试 {} 次）: {}".format(retries, guard.compact_error(last_error)))


def parse_release_id(value):
    release_id = str(value or "").strip().lower()
    if len(release_id) != 64 or any(char not in "0123456789abcdef" for char in release_id):
        raise guard.GuardError("版本构建标识格式无效")
    return release_id


def parse_version_manifest(payload):
    if isinstance(payload, bytes):
        payload = payload.decode("utf-8", "strict")
    data = json.loads(payload)
    if not isinstance(data, dict):
        raise guard.GuardError("GitHub 版本清单格式无效")
    version = str(data.get("version", "")).strip()
    allowed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+"
    if not version or len(version) > 32 or any(char not in allowed for char in version):
        raise guard.GuardError("GitHub 版本号格式无效")
    return {
        "version": version,
        "release_id": parse_release_id(data.get("release_id")),
    }


def check_for_github_update():
    """Return remote release details, or None when the startup check is unavailable."""
    try:
        local_release_id = parse_release_id(LOCAL_RELEASE_ID)
    except Exception:
        return None
    try:
        payload = download_update_file(
            UPDATE_BASE_URL + "/" + UPDATE_MANIFEST_NAME,
            timeout=UPDATE_CHECK_TIMEOUT_SECONDS,
            retries=1,
        )
        remote = parse_version_manifest(payload)
    except Exception:
        return None
    remote["available"] = remote["release_id"] != local_release_id
    return remote


def update_from_github(confirm_update=True, release_info=None):
    title("更新 GitHub 版本")
    print("当前版本: v{}".format(APP_VERSION))
    try:
        if load_config().get("force_ipv4", True):
            guard.enable_ipv4_only()
    except Exception:
        pass
    if release_info is None:
        release_info = check_for_github_update()
    target_version = release_info.get("version") if release_info else None
    if target_version and not release_info.get("available"):
        print("当前版本已经是最新版本了。")
        return None
    if target_version:
        print("最新版本: v{}".format(target_version))
    else:
        print("最新版本: 暂时无法获取（仍可继续更新）")
    print("更新来源: {}".format(UPDATE_BASE_URL))
    print("现有 config.json、state.json 和日志会保留。")
    confirm_text = "下载并安装 GitHub main 分支最新版本"
    if target_version:
        confirm_text = "下载并安装 GitHub v{}".format(target_version)
    if confirm_update and not yes_no(confirm_text, True):
        print("已取消更新。")
        return None

    installer_url = UPDATE_BASE_URL + "/install.sh"
    checksum_url = UPDATE_BASE_URL + "/install.sh.sha256"
    print("正在下载更新和校验文件...")
    try:
        installer = download_update_file(installer_url)
        checksum_text = download_update_file(checksum_url).decode("ascii", "strict").strip()
        expected = checksum_text.split()[0].lower()
        if len(expected) != 64 or any(char not in "0123456789abcdef" for char in expected):
            raise guard.GuardError("GitHub 校验文件格式无效")
        actual = hashlib.sha256(installer).hexdigest()
        if actual != expected:
            raise guard.GuardError("SHA-256 校验失败，已拒绝安装")
    except Exception as exc:
        print("更新下载失败: {}".format(guard.compact_error(exc)))
        return False

    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(prefix="aliyun-guard-update-", suffix=".sh", delete=False) as handle:
            handle.write(installer)
            temporary_path = handle.name
        os.chmod(temporary_path, 0o700)
        print("SHA-256 校验通过: {}".format(actual))
        result = subprocess.call(["/bin/sh", temporary_path, "--update"])
    except Exception as exc:
        print("执行更新失败: {}".format(guard.compact_error(exc)))
        return False
    finally:
        if temporary_path:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass

    if result != 0:
        print("更新安装器退出码: {}".format(result))
        return False
    print("GitHub 最新版本已安装，后台服务已重启。")
    return True


def show_status(config):
    title("运行状态")
    run_control("backend-status")
    print()
    guard.show_status()
    list_users(config)


def initial_setup(force=False):
    if CONFIG_FILE.exists() and not force:
        config = load_config()
        if config.get("users"):
            print("已有有效配置，不执行首次设置。")
            return 0
    config = default_config()
    title("阿里云保活与 Telegram 通知 - 首次设置")
    print("保活规则：当月 CDT 流量低于阈值时确保 ECS 运行；达到阈值时停止 ECS。")
    print("BSS 账单错误会单独通知，但不会阻断基于 CDT 流量的保活判断。")
    config["interval_seconds"] = prompt_int("检测间隔（秒）", 300, 60, 86400)
    config["notification_mode"] = choose_notification_mode("always")
    config["force_ipv4"] = yes_no("网络请求优先使用 IPv4", True)
    configure_telegram(config, initial=True)
    save_config(config)
    while True:
        if add_user(config, require_success=False):
            if not yes_no("继续添加其他账号或实例", False):
                break
        elif not config.get("users"):
            print("首次安装至少需要一个监控实例。")
            continue
        else:
            break
    save_config(config)
    print("\n首次配置完成。")
    return 0


def menu():
    setup_needed = not CONFIG_FILE.exists()
    if not setup_needed:
        try:
            setup_needed = not bool(load_config().get("users"))
        except Exception:
            setup_needed = True
    if setup_needed:
        if initial_setup(force=CONFIG_FILE.exists()) != 0:
            return 2
        print("\n首次配置已保存，正在启动后台服务...")
        if run_control("start") != 0:
            print("后台服务启动失败，请在管理面板查看运行状态或日志。")
    update_info = None
    update_checked = False
    while True:
        try:
            config = load_config()
        except Exception as exc:
            print("配置加载失败: {}".format(exc))
            return 2
        if not update_checked:
            if config.get("force_ipv4", True):
                guard.enable_ipv4_only()
            update_info = check_for_github_update()
            update_checked = True
        title("阿里云保活与通知 v{} - 管理面板".format(APP_VERSION))
        if update_info and update_info.get("available"):
            print(yellow_text("发现新版本: v{}（请选择 13 更新）".format(update_info["version"])))
        print(" 1) 查看运行状态")
        print(" 2) 立即执行一轮检测")
        print(" 3) 演练一轮（不执行开关机）")
        print(" 4) 测试 Telegram 通知")
        print(" 5) 查看监控实例")
        print(" 6) 添加监控实例")
        print(" 7) 编辑监控实例")
        print(" 8) 暂停/恢复监控实例")
        print(" 9) 删除监控实例")
        print("10) 修改全局设置")
        print("11) 查看最近日志")
        print("12) 重启后台服务")
        update_hint = ""
        if update_info and update_info.get("available"):
            update_hint = "  " + yellow_text("[有新版本 v{}]".format(update_info["version"]))
        print("13) 更新 GitHub 版本{}".format(update_hint))
        print("14) 退出")
        choice = prompt_int("请输入序号", 1, 1, 14)
        try:
            if choice == 1:
                show_status(config)
            elif choice == 2:
                run_once(False)
            elif choice == 3:
                run_once(True)
            elif choice == 4:
                configure_telegram(config)
                save_config(config)
            elif choice == 5:
                list_users(config)
            elif choice == 6:
                add_user(config)
            elif choice == 7:
                edit_user(config)
            elif choice == 8:
                toggle_user(config)
            elif choice == 9:
                delete_user(config)
            elif choice == 10:
                edit_settings(config)
            elif choice == 11:
                show_logs()
            elif choice == 12:
                run_control("restart")
            elif choice == 13:
                if update_from_github(release_info=update_info) is True:
                    return 0
            elif choice == 14:
                return 0
        except KeyboardInterrupt:
            print("\n操作已取消。")
        if choice != 14:
            prompt("按回车返回菜单")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="阿里云保活交互式管理器")
    subparsers = parser.add_subparsers(dest="command")
    setup = subparsers.add_parser("setup", help="执行首次设置")
    setup.add_argument("--force", action="store_true", help="忽略已有配置并重新设置")
    subparsers.add_parser("menu", help="打开管理面板")
    subparsers.add_parser("status", help="显示状态")
    subparsers.add_parser("add", help="添加实例")
    subparsers.add_parser("update", help="从 GitHub 更新程序")
    subparsers.add_parser("version", help="显示当前版本")
    return parser.parse_args(argv)


def main(argv=None):
    guard.configure_logging(console=False)
    args = parse_args(argv)
    try:
        if args.command == "setup":
            return initial_setup(args.force)
        if args.command == "status":
            show_status(load_config())
            return 0
        if args.command == "add":
            config = load_config()
            add_user(config)
            return 0
        if args.command == "update":
            result = update_from_github()
            return 1 if result is False else 0
        if args.command == "version":
            print("Aliyun Guard v{}".format(APP_VERSION))
            return 0
        return menu()
    except guard.GuardError as exc:
        print("错误: {}".format(exc), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\n已退出。")
        return 130


if __name__ == "__main__":
    sys.exit(main())
__AG_MANAGER_PY_EOF__
    cat > "$APP_DIR/control.sh" <<'__AG_CONTROL_SH_EOF__'
#!/bin/sh
set -u

APP_DIR=${ALIYUN_GUARD_HOME:-/opt/aliyun-guard}
PYTHON="$APP_DIR/venv/bin/python"
APP="$APP_DIR/aliyun_guard.py"
MANAGER="$APP_DIR/manager.py"
BACKEND_FILE="$APP_DIR/service_backend"
SERVICE_NAME="aliyun-guard"

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
            systemctl enable --now "$SERVICE_NAME.service"
            ;;
        openrc)
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
            rc-service "$SERVICE_NAME" start
            ;;
        cron)
            rm -f "$APP_DIR/disabled"
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
            systemctl stop "$SERVICE_NAME.service"
            ;;
        openrc)
            rc-service "$SERVICE_NAME" stop
            ;;
        cron)
            : > "$APP_DIR/disabled"
            chmod 600 "$APP_DIR/disabled"
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
            systemctl restart "$SERVICE_NAME.service"
            systemctl is-active "$SERVICE_NAME.service"
            ;;
        openrc)
            rc-service "$SERVICE_NAME" restart
            ;;
        cron)
            rm -f "$APP_DIR/disabled"
            "$PYTHON" "$APP" scheduled
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
__AG_CONTROL_SH_EOF__
    cat > "$APP_DIR/uninstall.sh" <<'__AG_UNINSTALL_SH_EOF__'
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

case "$backend" in
    systemd)
        systemctl disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ;;
    openrc)
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$SERVICE_NAME"
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
__AG_UNINSTALL_SH_EOF__
    chmod 700 "$APP_DIR/control.sh" "$APP_DIR/uninstall.sh"
    chmod 700 "$APP_DIR/aliyun_guard.py" "$APP_DIR/manager.py"
    chmod 700 "$APP_DIR"
    chmod 700 "$APP_DIR/logs"
    [ ! -f "$APP_DIR/config.json" ] || chmod 600 "$APP_DIR/config.json"
    [ ! -f "$APP_DIR/state.json" ] || chmod 600 "$APP_DIR/state.json"
    "$VENV_DIR/bin/python" -m py_compile "$APP_DIR/aliyun_guard.py" "$APP_DIR/manager.py"
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
write_payload
prepare_configuration
setup_backend
finish
