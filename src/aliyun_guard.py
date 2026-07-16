#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Aliyun ECS keepalive and CDT traffic guard."""

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import logging
from logging.handlers import TimedRotatingFileHandler
import os
from pathlib import Path
import re
import signal
import socket
import sys
import threading
import time
import urllib.parse

try:
    import requests
    REQUESTS_IMPORT_ERROR = None
except ImportError as exc:
    requests = None
    REQUESTS_IMPORT_ERROR = exc

import telegram_proxy

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
    "version": 2,
    "interval_seconds": 300,
    "notification_mode": "always",
    "notify_on_daemon_start": False,
    "force_ipv4": True,
    "web_panel": {
        "enabled": False,
        "host": "127.0.0.1",
        "port": 8765,
        "username": "admin",
        "password_hash": "",
        "cookie_secure": False,
    },
    "telegram": {
        "bot_token": "",
        "chat_id": "",
        "timeout_seconds": 12,
        "retries": 3,
        "connection_mode": "direct",
        "proxy_url": "",
        "node_url": "",
        "node_urls": [],
        "api_base_url": "https://api.telegram.org",
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

DEFAULT_SCHEDULE = {
    "enabled": False,
    "start_time": "08:00",
    "stop_time": "23:00",
}

LOGGER = logging.getLogger("aliyun_guard")
LOGGER.addHandler(logging.NullHandler())
_IPV4_PATCHED = False
_STOP_EVENT = threading.Event()
_CYCLE_THREAD_LOCK = threading.Lock()
_INSTANCE_LOG_LOCK = threading.Lock()


class GuardError(RuntimeError):
    pass


def configure_logging(console=True):
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(str(LOG_FILE.parent), 0o700)
    LOGGER.handlers = []
    LOGGER.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
    file_handler = TimedRotatingFileHandler(
        str(LOG_FILE), when="midnight", interval=1, backupCount=14, encoding="utf-8"
    )
    file_handler.setFormatter(formatter)
    LOGGER.addHandler(file_handler)
    os.chmod(str(LOG_FILE), 0o600)
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


def telegram_node_urls(telegram):
    """Return saved node links, including a legacy active node_url."""
    nodes = []
    raw_nodes = telegram.get("node_urls", []) if isinstance(telegram, dict) else []
    if isinstance(raw_nodes, list):
        for value in raw_nodes:
            node_url = str(value or "").strip()
            if node_url and node_url not in nodes:
                nodes.append(node_url)
    active_node = (
        str(telegram.get("node_url", "") or "").strip()
        if isinstance(telegram, dict)
        else ""
    )
    if active_node and active_node not in nodes:
        nodes.append(active_node)
    return nodes


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
    config["telegram"]["node_urls"] = telegram_node_urls(config["telegram"])
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
    try:
        import web_panel
    except ImportError as exc:
        raise GuardError("网页面板模块缺失: {}".format(exc))
    try:
        web_panel.validate_web_config(config)
    except web_panel.WebPanelError as exc:
        raise GuardError(str(exc))
    validate_telegram_config(config.get("telegram", {}))
    users = config.get("users")
    if not isinstance(users, list):
        raise GuardError("users 必须是数组")
    seen = set()
    for index, user in enumerate(users, 1):
        if not isinstance(user, dict):
            raise GuardError("第 {} 个实例配置不是对象".format(index))
        if "instance_log_enabled" in user and not isinstance(
            user["instance_log_enabled"], bool
        ):
            raise GuardError("第 {} 个实例的独立日志开关必须是布尔值".format(index))
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
        configured_schedule = user.get("schedule")
        if configured_schedule is not None and not isinstance(configured_schedule, dict):
            raise GuardError("第 {} 个实例的定时开关机配置必须是对象".format(index))
        if isinstance(configured_schedule, dict) and "enabled" in configured_schedule:
            if not isinstance(configured_schedule["enabled"], bool):
                raise GuardError("第 {} 个实例的定时开关机 enabled 必须是布尔值".format(index))
        schedule = get_schedule_config(user)
        if schedule["enabled"]:
            start_time = normalize_schedule_time(schedule["start_time"], "开机时间")
            stop_time = normalize_schedule_time(schedule["stop_time"], "关机时间")
            if start_time == stop_time:
                raise GuardError("第 {} 个实例的开机时间和关机时间不能相同".format(index))
        billing = get_billing_config(user)
        if billing.get("enabled", True):
            for field in ("endpoint", "region", "currency_code", "currency_symbol"):
                if not str(billing.get(field, "")).strip():
                    raise GuardError("第 {} 个实例的账单配置缺少 {}".format(index, field))


def validate_telegram_config(telegram):
    if not isinstance(telegram, dict):
        raise GuardError("telegram 必须是对象")
    try:
        timeout = int(telegram.get("timeout_seconds", 12))
        retries = int(telegram.get("retries", 3))
    except (TypeError, ValueError):
        raise GuardError("Telegram 超时和重试次数必须是整数")
    if timeout < 3 or timeout > 60:
        raise GuardError("Telegram 请求超时必须在 3 到 60 秒之间")
    if retries < 1 or retries > 5:
        raise GuardError("Telegram 重试次数必须在 1 到 5 之间")
    mode = str(telegram.get("connection_mode", "direct") or "direct").strip().lower()
    if mode not in ("direct", "socks5", "http", "node", "api_proxy"):
        raise GuardError("Telegram 连接方式无效")
    saved_nodes = telegram.get("node_urls", [])
    if not isinstance(saved_nodes, list):
        raise GuardError("Telegram 已保存节点必须是数组")
    for index, node_url in enumerate(saved_nodes, 1):
        if not isinstance(node_url, str) or not node_url.strip():
            raise GuardError("Telegram 第 {} 个已保存节点无效".format(index))
    if mode in ("socks5", "http"):
        proxy_url = str(telegram.get("proxy_url", "")).strip()
        parsed = urllib.parse.urlsplit(proxy_url)
        allowed = ("socks5", "socks5h") if mode == "socks5" else ("http", "https")
        try:
            port = parsed.port
        except ValueError:
            port = None
        if parsed.scheme.lower() not in allowed or not parsed.hostname or not port:
            raise GuardError("Telegram {} 代理地址无效".format("SOCKS5" if mode == "socks5" else "HTTP"))
    if mode == "node":
        try:
            telegram_proxy.parse_node_link(telegram.get("node_url", ""))
        except telegram_proxy.ProxyError as exc:
            raise GuardError("Telegram 节点链接无效: {}".format(exc))
    if mode == "api_proxy":
        base_url = str(telegram.get("api_base_url", "")).strip().rstrip("/")
        parsed = urllib.parse.urlsplit(base_url)
        try:
            parsed.port
        except ValueError:
            raise GuardError("Telegram API 反向代理端口无效")
        if parsed.scheme.lower() not in ("http", "https") or not parsed.hostname:
            raise GuardError("Telegram API 反向代理地址无效")
        if parsed.scheme.lower() != "https" and parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise GuardError("远程 Telegram API 反向代理必须使用 HTTPS")
        if parsed.query or parsed.fragment:
            raise GuardError("Telegram API 反向代理基础地址不能包含查询参数或片段")
        if "/bot" in parsed.path.lower():
            raise GuardError("Telegram API 反向代理只填写基础地址，不要包含 /botTOKEN")


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


def instance_log_enabled(user):
    return bool(user.get("instance_log_enabled", False))


def instance_log_path(user):
    """Return a deterministic path below the private instance log directory."""
    instance_id = str(user.get("instance_id", "") or "").strip()
    region = str(user.get("region", "") or "").strip()
    safe_id = re.sub(r"[^A-Za-z0-9._-]+", "-", instance_id)
    safe_id = safe_id.strip(".-_")[:64] or "instance"
    digest = hashlib.sha256(
        "{}\0{}".format(region, instance_id).encode("utf-8")
    ).hexdigest()[:10]
    return LOG_FILE.parent / "instances" / "{}-{}.log".format(safe_id, digest)


def _instance_log_value(value, user, limit=500):
    text = " ".join(str(value or "").replace("\r", " ").replace("\n", " ").split())
    for secret in (user.get("ak"), user.get("sk")):
        secret = str(secret or "")
        if secret:
            text = text.replace(secret, "***")
    text = re.sub(
        r"(?i)\b(?:https?|socks5h?|vless|vmess|ss)://[^\s；，,]+",
        "[链接已隐藏]",
        text,
    )
    text = re.sub(
        r"(?<![A-Za-z0-9_])\d{6,12}:[A-Za-z0-9_-]{20,}",
        "[Bot Token 已隐藏]",
        text,
    )
    return text[:limit] or "-"


def _instance_log_message(user, result, dry_run=False, event="周期检测"):
    traffic = result.get("traffic_gb")
    limit = result.get("limit_gb")
    if traffic is None:
        traffic_text = "无数据"
    elif limit is None:
        traffic_text = "{:.2f} GB".format(float(traffic))
    else:
        traffic_text = "{:.2f}/{:.2f} GB".format(float(traffic), float(limit))

    before = result.get("status_before") or "Unknown"
    after = result.get("status_after") or before
    status_text = str(before) if before == after else "{}->{}".format(before, after)

    if result.get("billing_checked", True) is False:
        bill_text = "未查询"
    elif not result.get("billing_enabled", False):
        bill_text = "已关闭"
    elif result.get("bill_error"):
        bill_text = "失败: {}".format(
            _instance_log_value(result.get("bill_error"), user)
        )
    elif result.get("bill_amount") is not None:
        bill_text = "{}{:.2f} {}".format(
            result.get("bill_symbol", ""),
            float(result["bill_amount"]),
            result.get("bill_currency") or "",
        ).strip()
    else:
        bill_text = "无数据"

    errors = result.get("errors", [])
    if not isinstance(errors, list):
        errors = [errors]
    errors_text = "；".join(
        _instance_log_value(value, user) for value in errors if value
    ) or "无"
    return " | ".join(
        (
            "事件={}".format(_instance_log_value(event, user, 80)),
            "实例={} ({})".format(
                _instance_log_value(result.get("name") or user.get("name"), user, 120),
                _instance_log_value(result.get("instance_id") or user.get("instance_id"), user, 120),
            ),
            "结果={}".format(_instance_log_value(result.get("level", "unknown"), user, 40)),
            "流量={}".format(traffic_text),
            "ECS={}".format(_instance_log_value(status_text, user, 120)),
            "账单={}".format(_instance_log_value(bill_text, user, 500)),
            "动作={}".format(_instance_log_value(result.get("action", "none"), user, 80)),
            "已执行={}".format("是" if result.get("action_performed") else "否"),
            "演练={}".format("是" if dry_run else "否"),
            "说明={}".format(_instance_log_value(result.get("message"), user, 500)),
            "错误={}".format(errors_text),
        )
    )


def write_instance_log(user, result, dry_run=False, event="周期检测"):
    """Write one redacted result line when per-instance logging is enabled."""
    if not instance_log_enabled(user):
        return False
    path = instance_log_path(user)
    try:
        with _INSTANCE_LOG_LOCK:
            path.parent.mkdir(parents=True, exist_ok=True)
            os.chmod(str(path.parent), 0o700)
            handler = TimedRotatingFileHandler(
                str(path),
                when="midnight",
                interval=1,
                backupCount=14,
                encoding="utf-8",
                delay=True,
            )
            try:
                handler.setFormatter(
                    logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
                )
                level = {
                    "error": logging.ERROR,
                    "warning": logging.WARNING,
                    "action": logging.INFO,
                    "paused": logging.INFO,
                }.get(result.get("level"), logging.INFO)
                record = logging.LogRecord(
                    "aliyun_guard.instance",
                    level,
                    __file__,
                    0,
                    _instance_log_message(user, result, dry_run=dry_run, event=event),
                    (),
                    None,
                )
                handler.handle(record)
            finally:
                handler.close()
            os.chmod(str(path), 0o600)
        return True
    except Exception as exc:
        LOGGER.error(
            "[%s] 独立日志写入失败: %s",
            user.get("name") or user.get("instance_id") or "未命名",
            compact_error(exc, secrets=(user.get("ak"), user.get("sk"))),
        )
        return False


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


def normalize_schedule_time(value, field_name="时间"):
    text = str(value or "").strip()
    if len(text) != 5 or text[2] != ":" or not (text[:2] + text[3:]).isdigit():
        raise GuardError("{}必须使用 HH:MM 格式，例如 08:30".format(field_name))
    hour = int(text[:2])
    minute = int(text[3:])
    if hour > 23 or minute > 59:
        raise GuardError("{}超出有效范围".format(field_name))
    return "{:02d}:{:02d}".format(hour, minute)


def get_schedule_config(user):
    configured = user.get("schedule")
    if not isinstance(configured, dict):
        configured = {}
    schedule = deep_merge(DEFAULT_SCHEDULE, configured)
    schedule["enabled"] = bool(schedule.get("enabled", False))
    if schedule["enabled"]:
        schedule["start_time"] = normalize_schedule_time(
            schedule.get("start_time"), "开机时间"
        )
        schedule["stop_time"] = normalize_schedule_time(
            schedule.get("stop_time"), "关机时间"
        )
    return schedule


def schedule_target(user, now=None):
    """Return the desired ECS state for the current daily schedule."""
    schedule = get_schedule_config(user)
    if not schedule["enabled"]:
        return None
    now = now or dt.datetime.now().astimezone()
    current = now.hour * 60 + now.minute
    start = int(schedule["start_time"][:2]) * 60 + int(schedule["start_time"][3:])
    stop = int(schedule["stop_time"][:2]) * 60 + int(schedule["stop_time"][3:])
    if start < stop:
        running = start <= current < stop
    else:
        running = current >= start or current < stop
    return "running" if running else "stopped"


def schedule_signature(user):
    schedule = get_schedule_config(user)
    if not schedule["enabled"]:
        return "disabled"
    return "{}|{}".format(schedule["start_time"], schedule["stop_time"])


def schedule_transition(user, previous_instance, now=None):
    if user.get("paused") or not get_schedule_config(user)["enabled"]:
        return None
    if not isinstance(previous_instance, dict):
        previous_instance = {}
    target = schedule_target(user, now)
    if (
        previous_instance.get("schedule_signature") != schedule_signature(user)
        or previous_instance.get("schedule_target") != target
    ):
        return "start" if target == "running" else "stop"
    return None


def has_due_schedule(config, state, now=None):
    now = now or dt.datetime.now().astimezone()
    previous = state.get("instances", {})
    if not isinstance(previous, dict):
        previous = {}
    for user in config.get("users", []):
        instance_id = str(user.get("instance_id", ""))
        if schedule_transition(user, previous.get(instance_id, {}), now):
            return True
    return False


def next_schedule_event(user, now=None):
    schedule = get_schedule_config(user)
    if not schedule["enabled"]:
        return None
    now = now or dt.datetime.now().astimezone()
    events = []
    for action, value in (("start", schedule["start_time"]), ("stop", schedule["stop_time"])):
        candidate = now.replace(
            hour=int(value[:2]), minute=int(value[3:]), second=0, microsecond=0
        )
        if candidate <= now:
            candidate += dt.timedelta(days=1)
        events.append((candidate, action))
    return min(events, key=lambda item: item[0])


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


def telegram_secrets(config):
    secrets = []
    for field in ("bot_token", "proxy_url", "api_base_url"):
        value = str(config.get(field, "") or "").strip()
        if value:
            secrets.append(value)
    proxy_url = str(config.get("proxy_url", "") or "").strip()
    if proxy_url:
        try:
            parsed = urllib.parse.urlsplit(proxy_url)
            secrets.extend(
                value for value in (parsed.username, parsed.password) if value
            )
        except ValueError:
            pass
    for node_url in telegram_node_urls(config):
        secrets.append(node_url)
        try:
            outbound = telegram_proxy.parse_node_link(node_url)
            secrets.extend(
                str(outbound[field]) for field in ("uuid", "password")
                if outbound.get(field)
            )
        except telegram_proxy.ProxyError:
            pass
    return tuple(dict.fromkeys(secrets))


def telegram_connection(config):
    validate_telegram_config(config)
    mode = str(config.get("connection_mode", "direct") or "direct").strip().lower()
    if mode != "node":
        telegram_proxy.stop_node_proxy()
    base_url = "https://api.telegram.org"
    proxies = None
    if mode in ("socks5", "http"):
        proxy_url = str(config.get("proxy_url", "")).strip()
        proxies = {"http": proxy_url, "https": proxy_url}
    elif mode == "node":
        try:
            proxy_url = telegram_proxy.ensure_node_proxy(config.get("node_url", ""))
        except telegram_proxy.ProxyError as exc:
            detail = compact_error(exc, secrets=telegram_secrets(config))
            raise GuardError("Telegram 节点代理失败: {}".format(detail)) from exc
        proxies = {"http": proxy_url, "https": proxy_url}
    elif mode == "api_proxy":
        base_url = str(config.get("api_base_url", "")).strip().rstrip("/")
    return base_url, proxies


def _safe_connection_endpoint(value):
    try:
        parsed = urllib.parse.urlsplit(str(value or ""))
        host = parsed.hostname or ""
        if ":" in host:
            host = "[{}]".format(host)
        if parsed.port:
            return "{}:{}".format(host, parsed.port)
        return host
    except ValueError:
        return "地址无效"


def telegram_connection_description(config):
    mode = str(config.get("connection_mode", "direct") or "direct").strip().lower()
    if mode == "socks5":
        return "SOCKS5 代理（{}）".format(
            _safe_connection_endpoint(config.get("proxy_url"))
        )
    if mode == "http":
        return "HTTP/HTTPS 代理（{}）".format(
            _safe_connection_endpoint(config.get("proxy_url"))
        )
    if mode == "node":
        try:
            return telegram_proxy.describe_node_link(config.get("node_url", ""))
        except telegram_proxy.ProxyError:
            return "节点代理（配置无效）"
    if mode == "api_proxy":
        return "Telegram API 反向代理（{}）".format(
            _safe_connection_endpoint(config.get("api_base_url"))
        )
    return "直连"


def append_telegram_connection_notice(telegram, text):
    mode = str(telegram.get("connection_mode", "direct") or "direct").strip().lower()
    text = str(text or "").rstrip()
    if mode == "direct":
        return text
    return "{}\n\nTelegram 连接：{}".format(
        text,
        telegram_connection_description(telegram),
    )


def _telegram_post(url, data, timeout, proxies):
    if REQUESTS_IMPORT_ERROR is not None:
        raise GuardError("Telegram HTTP 依赖未安装: {}".format(REQUESTS_IMPORT_ERROR))
    with requests.Session() as session:
        session.trust_env = False
        return session.post(url, data=data, timeout=timeout, proxies=proxies)


def telegram_api(config, method, data=None):
    token = str(config.get("bot_token", "")).strip()
    if not token:
        raise GuardError("Telegram Bot Token 未配置")
    timeout = max(3, int(config.get("timeout_seconds", 12)))
    retries = max(1, min(5, int(config.get("retries", 3))))
    base_url, proxies = telegram_connection(config)
    url = "{}/bot{}/{}".format(base_url, token, method)
    secrets = telegram_secrets(config)
    body = ""
    for attempt in range(1, retries + 1):
        try:
            response = _telegram_post(url, data or {}, timeout, proxies)
            body = response.text
            if response.status_code >= 400:
                if response.status_code not in (429, 500, 502, 503, 504) or attempt >= retries:
                    raise GuardError(
                        "Telegram HTTP {}: {}".format(response.status_code, body[:300])
                    )
                time.sleep(min(2 ** attempt, 8))
                continue
            break
        except GuardError:
            raise
        except Exception as exc:
            if attempt >= retries:
                raise GuardError(
                    "Telegram 网络请求失败（已重试 {} 次）: {}".format(
                        retries, compact_error(exc, secrets=secrets)
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
    text = append_telegram_connection_notice(telegram, text)
    results = []
    for chunk in split_message(text):
        results.append(telegram_api(telegram, "sendMessage", {"chat_id": chat_id, "text": chunk}))
    return results


def test_telegram(telegram, latency_attempts=3, result_details=None):
    latency_attempts = max(1, min(5, int(latency_attempts)))
    bot = telegram_api(telegram, "getMe")
    latencies = []
    for _index in range(latency_attempts):
        started = time.perf_counter()
        bot = telegram_api(telegram, "getMe")
        latencies.append((time.perf_counter() - started) * 1000.0)
    latency_ms = sum(latencies) / len(latencies)
    username = bot.get("username", "unknown") if isinstance(bot, dict) else "unknown"
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    message = "阿里云保活通知测试成功\n时间: {}\nBot: @{}".format(now, username)
    message += "\nTelegram 往返延迟: {:.0f} ms（{} 次平均）".format(
        latency_ms,
        latency_attempts,
    )
    send_telegram_message(telegram, message)
    if result_details is not None:
        result_details["latency_ms"] = latency_ms
        result_details["latency_attempts"] = latency_attempts
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


def check_one(user, config, dry_run=False, now=None, scheduled_action=None):
    name = str(user.get("name") or user.get("instance_id") or "未命名")
    billing = get_billing_config(user)
    schedule = get_schedule_config(user)
    target = schedule_target(user, now) if schedule["enabled"] else None
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
        "schedule_enabled": schedule["enabled"],
        "schedule_start_time": schedule["start_time"],
        "schedule_stop_time": schedule["stop_time"],
        "schedule_target": target,
        "schedule_event": scheduled_action,
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

    status = result["status_before"]
    actions_enabled = bool(user.get("actions_enabled", True))
    wait_seconds = max(0, int(config.get("start_wait_seconds", 90)))
    stop_wait_seconds = max(0, int(config.get("stop_wait_seconds", 45)))
    poll_seconds = max(1, int(config.get("start_poll_seconds", 5)))

    # A planned shutdown only depends on a readable ECS state. CDT or BSS
    # failures remain visible, but they must not leave an instance running.
    if target == "stopped" and status is not None:
        if status == "Running":
            result["action"] = "schedule_stop"
            if dry_run:
                result["level"] = "action"
                result["message"] = "演练：当前处于计划关机时段，应停止实例"
            elif not actions_enabled:
                result["level"] = "warning"
                result["message"] = "当前处于计划关机时段，但自动操作未启用"
            else:
                try:
                    stop_instance(user)
                    result["action_performed"] = True
                    LOGGER.info("[%s] 已提交定时关机请求", name)
                    latest, poll_error = wait_for_status(
                        user, "Stopped", stop_wait_seconds, poll_seconds
                    )
                    if latest:
                        result["status_after"] = latest
                    if latest == "Stopped":
                        result["level"] = "action"
                        result["message"] = "定时关机已执行并确认实例停止"
                    elif poll_error:
                        result["level"] = "warning"
                        result["message"] = "已提交定时关机，状态复查失败: {}".format(
                            poll_error
                        )
                    else:
                        result["level"] = "warning"
                        result["message"] = "已提交定时关机，等待 {} 秒后状态为 {}".format(
                            stop_wait_seconds, latest or "Unknown"
                        )
                except Exception as exc:
                    result["level"] = "error"
                    result["message"] = "定时关机失败: {}".format(
                        compact_error(exc, secrets=user_secrets)
                    )
                    result["errors"].append(result["message"])
                    LOGGER.error("[%s] %s", name, result["message"])
        elif status == "Stopped":
            result["message"] = "当前处于计划关机时段，实例保持关机"
        else:
            result["level"] = "warning"
            result["message"] = "当前处于计划关机时段，实例状态为 {}，本轮不重复操作".format(
                status
            )
        if result["errors"]:
            result["level"] = "error"
        LOGGER.info("[%s] 计划关机时段，状态 %s，结果: %s", name, status, result["message"])
        return result

    if core_error_count:
        result["level"] = "error"
        result["message"] = "CDT 或 ECS 核心查询失败，本轮未执行开关机"
        return result

    traffic = result["traffic_gb"]
    limit = result["limit_gb"]

    if traffic < limit:
        if status == "Running":
            if scheduled_action == "start":
                result["message"] = "已进入计划运行时段，实例正在运行"
            else:
                result["message"] = "流量安全，实例运行正常"
        elif status == "Stopped":
            result["action"] = "schedule_start" if scheduled_action == "start" else "start"
            if dry_run:
                result["level"] = "action"
                result["message"] = (
                    "演练：当前处于计划运行时段，应启动实例"
                    if schedule["enabled"]
                    else "演练：应启动实例"
                )
            elif not actions_enabled:
                result["level"] = "warning"
                result["message"] = (
                    "当前处于计划运行时段，但自动操作未启用"
                    if schedule["enabled"]
                    else "流量安全但实例已停止，自动操作未启用"
                )
            else:
                try:
                    start_instance(user)
                    result["action_performed"] = True
                    LOGGER.info(
                        "[%s] 已提交%s启动请求",
                        name,
                        "定时" if scheduled_action == "start" else "保活",
                    )
                    latest, poll_error = wait_for_status(user, "Running", wait_seconds, poll_seconds)
                    if latest:
                        result["status_after"] = latest
                    if latest == "Running":
                        result["level"] = "action"
                        result["message"] = (
                            "定时开机已执行并确认实例运行"
                            if scheduled_action == "start"
                            else "已启动并确认实例运行"
                        )
                    elif poll_error:
                        result["level"] = "warning"
                        result["message"] = "已提交{}启动请求，状态复查失败: {}".format(
                            "定时" if scheduled_action == "start" else "保活",
                            poll_error,
                        )
                    else:
                        result["level"] = "warning"
                        result["message"] = "已提交{}启动请求，等待 {} 秒后状态为 {}".format(
                            "定时" if scheduled_action == "start" else "保活",
                            wait_seconds,
                            latest or "Unknown",
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
        if item.get("schedule_enabled"):
            target_label = "运行" if item.get("schedule_target") == "running" else "关机"
            lines.append(
                "  计划: {} 开机 / {} 关机（当前{}时段）".format(
                    item.get("schedule_start_time"),
                    item.get("schedule_stop_time"),
                    target_label,
                )
            )
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
    if any(
        item["action"] != "none"
        or item["level"] == "warning"
        or item.get("schedule_event")
        for item in results
    ):
        return True
    previous = previous_state.get("instances", {})
    if not isinstance(previous, dict):
        previous = {}
    for item in results:
        old = previous.get(item["instance_id"], {})
        if old.get("status_after") and old.get("status_after") != item.get("status_after"):
            return True
    return False


def update_state(
    state,
    results,
    started_at,
    duration,
    summary,
    error_count,
    notify_error=None,
    dry_run=False,
):
    state["last_cycle_started_at"] = started_at.isoformat(timespec="seconds")
    state["last_cycle_finished_at"] = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    state["last_cycle_duration_seconds"] = round(duration, 3)
    state["last_cycle_error_count"] = error_count
    state["last_cycle_ok"] = error_count == 0
    state["last_summary"] = summary
    state["cycle_count"] = int(state.get("cycle_count", 0)) + 1
    state["telegram_error"] = notify_error
    if not dry_run:
        state["last_cycle_epoch"] = started_at.timestamp()
    if not isinstance(state.get("instances"), dict):
        state["instances"] = {}
    for item in results:
        previous_instance = state["instances"].get(item["instance_id"], {})
        instance_state = {
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
        if not dry_run and not item.get("paused"):
            instance_state["schedule_signature"] = (
                "{}|{}".format(
                    item.get("schedule_start_time"), item.get("schedule_stop_time")
                )
                if item.get("schedule_enabled")
                else "disabled"
            )
            instance_state["schedule_target"] = item.get("schedule_target")
        else:
            for field in ("schedule_signature", "schedule_target"):
                if field in previous_instance:
                    instance_state[field] = previous_instance[field]
        state["instances"][item["instance_id"]] = instance_state
    if not dry_run:
        history = state.get("history")
        if not isinstance(history, list):
            history = []
        history.append(
            {
                "at": started_at.isoformat(timespec="seconds"),
                "instances": {
                    item["instance_id"]: {
                        "traffic_gb": item.get("traffic_gb"),
                        "status": item.get("status_after"),
                        "status_before": item.get("status_before"),
                        "status_after": item.get("status_after"),
                        "bill_amount": item.get("bill_amount"),
                        "action": item.get("action", "none"),
                        "action_performed": bool(item.get("action_performed", False)),
                        "message": item.get("message", ""),
                        "level": item.get("level", "unknown"),
                    }
                    for item in results
                },
            }
        )
        state["history"] = history[-576:]


@contextlib.contextmanager
def cycle_lock():
    thread_locked = _CYCLE_THREAD_LOCK.acquire(False)
    if not thread_locked:
        yield False
        return
    handle = None
    locked = True
    try:
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        handle = LOCK_FILE.open("a+")
        if fcntl is not None:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                locked = False
        yield locked
    finally:
        if handle is not None and locked and fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        if handle is not None:
            handle.close()
        _CYCLE_THREAD_LOCK.release()


def run_cycle(dry_run=False, no_notify=False, started_at=None):
    config = load_config()
    if config.get("force_ipv4", True):
        enable_ipv4_only()
    started_at = started_at or dt.datetime.now().astimezone()
    monotonic_start = time.monotonic()
    previous_state = load_state()
    previous_instances = previous_state.get("instances", {})
    if not isinstance(previous_instances, dict):
        previous_instances = {}
    results = []
    for user in config.get("users", []):
        if _STOP_EVENT.is_set():
            break
        instance_id = str(user.get("instance_id", ""))
        transition = schedule_transition(
            user, previous_instances.get(instance_id, {}), started_at
        )
        result = check_one(
            user,
            config,
            dry_run=dry_run,
            now=started_at,
            scheduled_action=transition,
        )
        results.append(result)
        write_instance_log(user, result, dry_run=dry_run)
    duration = time.monotonic() - monotonic_start
    summary, error_count, action_count, warning_count = build_summary(
        results, started_at, duration, dry_run=dry_run
    )
    print(summary)
    notify_error = None
    if not no_notify and should_notify(config, results, previous_state):
        telegram = config.get("telegram", {})
        try:
            send_telegram_message(telegram, summary)
            LOGGER.info("Telegram 本轮汇总通知发送成功")
        except Exception as exc:
            notify_error = compact_error(exc, secrets=telegram_secrets(telegram))
            LOGGER.error("Telegram 本轮汇总通知发送失败: %s", notify_error)
    update_state(
        previous_state,
        results,
        started_at,
        duration,
        summary,
        error_count,
        notify_error,
        dry_run=dry_run,
    )
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
        now = dt.datetime.now().astimezone()
        if not is_due(config, state, now.timestamp()) and not has_due_schedule(
            config, state, now
        ):
            return 0
        return run_cycle(started_at=now)


def scheduler_wait_seconds(config, state, now=None):
    now = time.time() if now is None else float(now)
    last = state.get("last_cycle_epoch")
    if last is None:
        regular_wait = 60.0
    else:
        regular_wait = max(1.0, int(config["interval_seconds"]) - (now - float(last)))
    minute_wait = 60.05 - (now % 60.0)
    return max(1.0, min(regular_wait, minute_wait))


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
        telegram = config.get("telegram", {})
        try:
            send_telegram_message(
                telegram,
                "阿里云保活服务已启动\n时间: {}".format(dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
            )
        except Exception as exc:
            LOGGER.error(
                "启动通知发送失败: %s",
                compact_error(exc, secrets=telegram_secrets(telegram)),
            )
    web_server = None
    try:
        import web_panel

        web_server = web_panel.start_background(sys.modules[__name__], config)
    except Exception as exc:
        LOGGER.error("网页控制面板启动失败，保活服务继续运行: %s", compact_error(exc))
    LOGGER.info("保活服务已启动")
    first_cycle = True
    while not _STOP_EVENT.is_set():
        with cycle_lock() as locked:
            if locked:
                try:
                    config = load_config()
                    state = load_state()
                    now = dt.datetime.now().astimezone()
                    if (
                        first_cycle
                        or is_due(config, state, now.timestamp())
                        or has_due_schedule(config, state, now)
                    ):
                        run_cycle(started_at=now)
                except Exception as exc:
                    LOGGER.exception(
                        "本轮检测发生未处理错误: %s",
                        compact_error(
                            exc,
                            secrets=telegram_secrets(config.get("telegram", {})),
                        ),
                    )
            else:
                LOGGER.warning("已有检测正在运行，本轮跳过")
        first_cycle = False
        try:
            config = load_config()
            state = load_state()
            remaining = scheduler_wait_seconds(config, state)
        except Exception:
            remaining = 60
        _STOP_EVENT.wait(remaining)
    if web_server is not None:
        web_server.shutdown()
        web_server.server_close()
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
    scheduled_users = [
        user
        for user in config.get("users", [])
        if get_schedule_config(user)["enabled"] and not user.get("paused")
    ]
    print("定时计划: {} 个已启用".format(len(scheduled_users)))
    upcoming = []
    now = dt.datetime.now().astimezone()
    for user in scheduled_users:
        event = next_schedule_event(user, now)
        if event:
            upcoming.append((event[0], event[1], str(user.get("name") or user.get("instance_id"))))
    if upcoming:
        event_at, action, name = min(upcoming, key=lambda item: item[0])
        print(
            "下一计划: {} {} {}".format(
                event_at.strftime("%Y-%m-%d %H:%M"),
                name,
                "开机" if action == "start" else "关机",
            )
        )
    print("检测间隔: {} 秒".format(config["interval_seconds"]))
    print("通知模式: {}".format(config["notification_mode"]))
    try:
        import web_panel

        web = web_panel.get_web_config(config)
        print(
            "网页面板: {} (http://{}:{})".format(
                "已启用" if web["enabled"] else "已关闭", web["host"], web["port"]
            )
        )
    except Exception:
        print("网页面板: 配置异常")
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
            details = {}
            username = test_telegram(
                config.get("telegram", {}),
                latency_attempts=3,
                result_details=details,
            )
            print("Telegram 测试成功: @{}".format(username))
            print(
                "Telegram 往返延迟: {:.0f} ms（{} 次平均）".format(
                    details["latency_ms"],
                    details["latency_attempts"],
                )
            )
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
