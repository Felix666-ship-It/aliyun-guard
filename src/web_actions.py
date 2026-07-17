#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Management operations exposed by the authenticated web panel."""

import copy
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

import telegram_proxy


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))

CONNECTION_LABELS = {
    "direct": "直连",
    "socks5": "SOCKS5 代理",
    "http": "HTTP/HTTPS 代理",
    "node": "节点链接",
    "api_proxy": "Telegram API 反向代理",
}

BILLING_PRESETS = {
    "china": {
        "enabled": True,
        "site": "china",
        "endpoint": "business.aliyuncs.com",
        "region": "cn-hangzhou",
        "currency_code": "CNY",
        "currency_symbol": "¥",
    },
    "international": {
        "enabled": True,
        "site": "international",
        "endpoint": "business.ap-southeast-1.aliyuncs.com",
        "region": "ap-southeast-1",
        "currency_code": "USD",
        "currency_symbol": "$",
    },
}


class ManagementError(RuntimeError):
    def __init__(self, message, status=400, details=None):
        super().__init__(message)
        self.status = status
        self.details = details


def _copy(value):
    return copy.deepcopy(value)


def _required_text(data, name, current="", label=None):
    value = data.get(name, current)
    value = str(value or "").strip()
    if not value:
        raise ManagementError("{}不能为空".format(label or name))
    return value


def _optional_secret(data, name, current="", label=None):
    value = str(data.get(name, "") or "").strip()
    if value:
        return value
    current = str(current or "").strip()
    if not current:
        raise ManagementError("{}不能为空".format(label or name))
    return current


def _boolean(data, name, current=False):
    value = data.get(name, current)
    if not isinstance(value, bool):
        raise ManagementError("{}必须是布尔值".format(name))
    return value


def _integer(data, name, current, minimum, maximum):
    try:
        value = int(data.get(name, current))
    except (TypeError, ValueError):
        raise ManagementError("{}必须是整数".format(name))
    if value < minimum or value > maximum:
        raise ManagementError(
            "{}必须在 {} 到 {} 之间".format(name, minimum, maximum)
        )
    return value


def _number(data, name, current, minimum):
    try:
        value = float(data.get(name, current))
    except (TypeError, ValueError):
        raise ManagementError("{}必须是数字".format(name))
    if value < minimum:
        raise ManagementError("{}不能小于 {}".format(name, minimum))
    return value


def _save_config(guard, config):
    try:
        guard.validate_config(config)
        config["telegram"]["node_urls"] = guard.telegram_node_urls(
            config.get("telegram", {})
        )
        guard.atomic_write_json(guard.CONFIG_FILE, config, mode=0o600)
    except ManagementError:
        raise
    except Exception as exc:
        raise ManagementError(guard.compact_error(exc))


def _node_description(node_url):
    try:
        return telegram_proxy.describe_node_link(node_url)
    except telegram_proxy.ProxyError:
        return "无效节点"


def _billing_payload(guard, user):
    billing = guard.get_billing_config(user)
    return {
        "enabled": bool(billing.get("enabled", True)),
        "site": str(billing.get("site", "china")),
        "endpoint": str(billing.get("endpoint", "")),
        "region": str(billing.get("region", "")),
        "currency_code": str(billing.get("currency_code", "")),
        "currency_symbol": str(billing.get("currency_symbol", "")),
    }


def _instance_payload(guard, user, index):
    schedule = guard.get_schedule_config(user)
    return {
        "index": index,
        "name": str(user.get("name", "")),
        "access_key_configured": bool(str(user.get("ak", "")).strip()),
        "secret_key_configured": bool(str(user.get("sk", "")).strip()),
        "region": str(user.get("region", "")),
        "instance_id": str(user.get("instance_id", "")),
        "traffic_limit_gb": float(user.get("traffic_limit_gb", 0) or 0),
        "actions_enabled": bool(user.get("actions_enabled", True)),
        "instance_log_enabled": bool(user.get("instance_log_enabled", False)),
        "paused": bool(user.get("paused", False)),
        "billing": _billing_payload(guard, user),
        "schedule": {
            "enabled": schedule["enabled"],
            "start_time": schedule["start_time"],
            "stop_time": schedule["stop_time"],
        },
    }


def telegram_payload(guard, telegram):
    nodes = guard.telegram_node_urls(telegram)
    active = str(telegram.get("node_url", "") or "").strip()
    mode = str(telegram.get("connection_mode", "direct") or "direct")
    explicit_admins = guard.normalize_telegram_control_admin_ids(
        telegram.get("control_admin_ids", [])
    )
    effective_admins = guard.telegram_control_admin_ids(telegram)
    return {
        "bot_token_configured": bool(str(telegram.get("bot_token", "")).strip()),
        "chat_id": str(telegram.get("chat_id", "")),
        "timeout_seconds": int(telegram.get("timeout_seconds", 12)),
        "retries": int(telegram.get("retries", 3)),
        "control_enabled": bool(telegram.get("control_enabled", True)),
        "control_admin_ids": explicit_admins,
        "control_effective_admin_ids": effective_admins,
        "control_uses_chat_id": bool(effective_admins and not explicit_admins),
        "connection_mode": mode,
        "connection_label": CONNECTION_LABELS.get(mode, "未知"),
        "connection_description": guard.telegram_connection_description(telegram),
        "proxy_configured": bool(str(telegram.get("proxy_url", "")).strip()),
        "api_base_configured": bool(str(telegram.get("api_base_url", "")).strip()),
        "nodes": [
            {
                "index": index,
                "description": _node_description(node_url),
                "active": mode == "node" and node_url == active,
            }
            for index, node_url in enumerate(nodes)
        ],
    }


def management_payload(guard, backend="unknown"):
    config = guard.load_config()
    raw_web = config.get("web_panel", {})
    web = raw_web if isinstance(raw_web, dict) else {}
    return {
        "instances": [
            _instance_payload(guard, user, index)
            for index, user in enumerate(config.get("users", []))
        ],
        "telegram": telegram_payload(guard, config.get("telegram", {})),
        "settings": {
            "interval_seconds": int(config.get("interval_seconds", 300)),
            "notification_mode": str(config.get("notification_mode", "always")),
            "force_ipv4": bool(config.get("force_ipv4", True)),
            "notify_on_daemon_start": bool(config.get("notify_on_daemon_start", False)),
            "start_wait_seconds": int(config.get("start_wait_seconds", 90)),
            "stop_wait_seconds": int(config.get("stop_wait_seconds", 45)),
            "start_poll_seconds": int(config.get("start_poll_seconds", 5)),
        },
        "web": {
            "enabled": bool(web.get("enabled", False)),
            "host": str(web.get("host", "127.0.0.1")),
            "port": int(web.get("port", 8765)),
            "username": str(web.get("username", "admin")),
            "password_configured": bool(str(web.get("password_hash", "")).strip()),
        },
        "backend": backend,
    }


def _normalize_billing(guard, raw, existing):
    raw = raw if isinstance(raw, dict) else {}
    current = guard.get_billing_config(existing)
    enabled = _boolean(raw, "enabled", bool(current.get("enabled", True)))
    site = str(raw.get("site", current.get("site", "china")) or "china")
    if not enabled:
        result = _copy(current)
        result["enabled"] = False
        return result
    if site in BILLING_PRESETS:
        return _copy(BILLING_PRESETS[site])
    if site != "custom":
        raise ManagementError("账单站点无效")
    return {
        "enabled": True,
        "site": "custom",
        "endpoint": _required_text(raw, "endpoint", current.get("endpoint"), "BSS Endpoint"),
        "region": _required_text(raw, "region", current.get("region"), "BSS 签名 Region"),
        "currency_code": _required_text(
            raw, "currency_code", current.get("currency_code"), "币种代码"
        ).upper(),
        "currency_symbol": _required_text(
            raw, "currency_symbol", current.get("currency_symbol"), "币种符号"
        ),
    }


def _normalize_schedule(guard, raw, existing):
    raw = raw if isinstance(raw, dict) else {}
    current = guard.get_schedule_config(existing)
    enabled = _boolean(raw, "enabled", current["enabled"])
    try:
        start_time = guard.normalize_schedule_time(
            raw.get("start_time", current["start_time"]), "开机时间"
        )
        stop_time = guard.normalize_schedule_time(
            raw.get("stop_time", current["stop_time"]), "关机时间"
        )
    except Exception as exc:
        raise ManagementError(str(exc))
    if enabled and start_time == stop_time:
        raise ManagementError("开机时间和关机时间不能相同")
    return {
        "enabled": enabled,
        "start_time": start_time,
        "stop_time": stop_time,
    }


def build_instance_candidate(guard, data, existing=None):
    if not isinstance(data, dict):
        raise ManagementError("实例配置格式无效")
    existing = _copy(existing or {})
    candidate = _copy(existing)
    candidate["name"] = _required_text(data, "name", existing.get("name"), "备注名称")
    candidate["ak"] = _optional_secret(
        data, "ak", existing.get("ak"), "AccessKey ID"
    )
    candidate["sk"] = _optional_secret(
        data, "sk", existing.get("sk"), "AccessKey Secret"
    )
    candidate["region"] = _required_text(
        data, "region", existing.get("region"), "Region ID"
    )
    candidate["instance_id"] = _required_text(
        data, "instance_id", existing.get("instance_id"), "实例 ID"
    )
    candidate["traffic_limit_gb"] = _number(
        data, "traffic_limit_gb", existing.get("traffic_limit_gb", 180), 0.01
    )
    candidate["actions_enabled"] = _boolean(
        data, "actions_enabled", bool(existing.get("actions_enabled", True))
    )
    candidate["instance_log_enabled"] = _boolean(
        data,
        "instance_log_enabled",
        bool(existing.get("instance_log_enabled", False)),
    )
    candidate["paused"] = bool(existing.get("paused", False))
    candidate["billing"] = _normalize_billing(
        guard, data.get("billing"), existing
    )
    candidate["schedule"] = _normalize_schedule(
        guard, data.get("schedule"), existing
    )
    for legacy in ("bill_endpoint", "currency", "billing_enabled"):
        candidate.pop(legacy, None)
    return candidate


def _validate_candidate_config(guard, config):
    try:
        guard.validate_config(config)
    except Exception as exc:
        raise ManagementError(guard.compact_error(exc))


def save_instance(guard, data, index=None):
    config = guard.load_config()
    users = config.setdefault("users", [])
    if index is None:
        existing = None
    elif index < 0 or index >= len(users):
        raise ManagementError("实例不存在", 404)
    else:
        existing = users[index]
    candidate = build_instance_candidate(guard, data, existing)
    candidate_config = _copy(config)
    if index is None:
        candidate_config["users"].append(candidate)
        candidate_index = len(candidate_config["users"]) - 1
    else:
        candidate_config["users"][index] = candidate
        candidate_index = index
    _validate_candidate_config(guard, candidate_config)
    try:
        result = guard.validate_user_connection(
            candidate, bool(config.get("force_ipv4", True))
        )
    except Exception as exc:
        raise ManagementError(
            "实例校验失败: {}".format(
                guard.compact_error(exc, secrets=(candidate.get("ak"), candidate.get("sk")))
            ),
            502,
        )
    force_save = data.get("force_save", False)
    if not isinstance(force_save, bool):
        raise ManagementError("force_save 必须是布尔值")
    if not result.get("ok") and not force_save:
        raise ManagementError("实例校验未通过，配置尚未保存", 422, result)
    _save_config(guard, candidate_config)
    return {
        "saved": True,
        "index": candidate_index,
        "validation": result,
        "instance": _instance_payload(guard, candidate, candidate_index),
    }


def validate_instance(guard, index):
    config = guard.load_config()
    users = config.get("users", [])
    if index < 0 or index >= len(users):
        raise ManagementError("实例不存在", 404)
    user = users[index]
    try:
        return guard.validate_user_connection(
            user, bool(config.get("force_ipv4", True))
        )
    except Exception as exc:
        raise ManagementError(
            guard.compact_error(exc, secrets=(user.get("ak"), user.get("sk"))),
            502,
        )


def update_instance_logging(guard, index, enabled):
    if not isinstance(enabled, bool):
        raise ManagementError("enabled 必须是布尔值")
    config = guard.load_config()
    users = config.get("users", [])
    if index < 0 or index >= len(users):
        raise ManagementError("实例不存在", 404)
    users[index]["instance_log_enabled"] = enabled
    _save_config(guard, config)
    return {
        "enabled": enabled,
        "instance": _instance_payload(guard, users[index], index),
    }


def delete_instance(guard, index, instance_id):
    config = guard.load_config()
    users = config.get("users", [])
    if index < 0 or index >= len(users):
        raise ManagementError("实例不存在", 404)
    current_id = str(users[index].get("instance_id", ""))
    if str(instance_id or "") != current_id:
        raise ManagementError("删除确认信息不匹配", 409)
    deleted = users.pop(index)
    _save_config(guard, config)
    return {"name": deleted.get("name"), "instance_id": current_id}


def update_global_settings(guard, data):
    config = guard.load_config()
    mode = str(data.get("notification_mode", config.get("notification_mode", "always")))
    if mode not in ("always", "events", "errors"):
        raise ManagementError("通知模式无效")
    config["interval_seconds"] = _integer(
        data, "interval_seconds", config.get("interval_seconds", 300), 60, 86400
    )
    config["notification_mode"] = mode
    config["force_ipv4"] = _boolean(
        data, "force_ipv4", bool(config.get("force_ipv4", True))
    )
    config["notify_on_daemon_start"] = _boolean(
        data,
        "notify_on_daemon_start",
        bool(config.get("notify_on_daemon_start", False)),
    )
    config["start_wait_seconds"] = _integer(
        data, "start_wait_seconds", config.get("start_wait_seconds", 90), 0, 600
    )
    config["stop_wait_seconds"] = _integer(
        data, "stop_wait_seconds", config.get("stop_wait_seconds", 45), 0, 600
    )
    config["start_poll_seconds"] = _integer(
        data, "start_poll_seconds", config.get("start_poll_seconds", 5), 1, 60
    )
    _save_config(guard, config)
    return management_payload(guard)["settings"]


def update_web_settings(guard, data):
    import web_panel

    config = guard.load_config()
    current = web_panel.get_web_config(config)
    enabled = _boolean(data, "enabled", current["enabled"])
    host = str(data.get("host", current["host"]) or "").strip()
    if host not in ("127.0.0.1", "0.0.0.0"):
        raise ManagementError("网页监听地址无效")
    container = os.environ.get("ALIYUN_GUARD_CONTAINER") == "1"
    container_port = int(
        os.environ.get("ALIYUN_GUARD_CONTAINER_WEB_PORT", "8765")
    )
    requested_port = _integer(data, "port", current["port"], 1024, 65535)
    if container and (host != "0.0.0.0" or requested_port != container_port):
        raise ManagementError(
            "Docker 内网页固定监听 0.0.0.0:{}；外部端口请修改 Compose 映射".format(
                container_port
            ),
            409,
        )
    if (
        host == "0.0.0.0"
        and current["host"] != "0.0.0.0"
        and data.get("confirm_public") is not True
    ):
        raise ManagementError("监听所有网卡需要确认 HTTP 明文传输风险", 409)
    candidate = dict(current)
    candidate.update(
        {
            "enabled": enabled,
            "host": host,
            "port": requested_port,
            "username": _required_text(
                data, "username", current["username"], "网页登录用户名"
            ),
            "cookie_secure": False,
        }
    )
    password = str(data.get("password", "") or "")
    confirmation = str(data.get("password_confirm", "") or "")
    if password or confirmation:
        if password != confirmation:
            raise ManagementError("两次输入的网页登录密码不一致")
        try:
            candidate["password_hash"] = web_panel.hash_password(password)
        except ValueError as exc:
            raise ManagementError(str(exc))
    if enabled and not str(candidate.get("password_hash", "")).strip():
        raise ManagementError("启用网页面板前必须设置登录密码")
    config["web_panel"] = candidate
    _save_config(guard, config)
    return {
        "enabled": candidate["enabled"],
        "host": candidate["host"],
        "port": candidate["port"],
        "username": candidate["username"],
        "password_configured": bool(candidate.get("password_hash")),
        "restart_required": any(
            candidate.get(field) != current.get(field)
            for field in ("enabled", "host", "port", "username", "password_hash")
        ),
    }


def update_telegram_identity(guard, data):
    config = guard.load_config()
    telegram = config.setdefault("telegram", {})
    token = str(data.get("bot_token", "") or "").strip()
    if token:
        telegram["bot_token"] = token
    if not str(telegram.get("bot_token", "")).strip():
        raise ManagementError("Telegram Bot Token 不能为空")
    telegram["chat_id"] = _required_text(
        data, "chat_id", telegram.get("chat_id"), "Telegram Chat ID"
    )
    telegram["timeout_seconds"] = _integer(
        data, "timeout_seconds", telegram.get("timeout_seconds", 12), 3, 60
    )
    telegram["retries"] = _integer(
        data, "retries", telegram.get("retries", 3), 1, 5
    )
    telegram["control_enabled"] = _boolean(
        data,
        "control_enabled",
        bool(telegram.get("control_enabled", True)),
    )
    if "control_admin_ids" in data:
        try:
            telegram["control_admin_ids"] = guard.normalize_telegram_control_admin_ids(
                data.get("control_admin_ids")
            )
        except Exception as exc:
            raise ManagementError(str(exc))
    _save_config(guard, config)
    return telegram_payload(guard, telegram)


def _telegram_test(guard, telegram, force_ipv4=True, install_core=True):
    try:
        guard.validate_telegram_config(telegram)
        if telegram.get("connection_mode") == "node" and not telegram_proxy.find_sing_box():
            if not install_core:
                raise ManagementError("节点模式需要先安装 sing-box", 409)
            telegram_proxy.install_sing_box()
        if force_ipv4:
            guard.enable_ipv4_only()
        details = {}
        username = guard.test_telegram(
            telegram, latency_attempts=3, result_details=details
        )
        return {
            "username": username,
            "latency_ms": round(float(details.get("latency_ms", 0)), 1),
            "latency_attempts": int(details.get("latency_attempts", 3)),
            "connection": guard.telegram_connection_description(telegram),
        }
    except ManagementError:
        raise
    except Exception as exc:
        raise ManagementError(
            "Telegram 测试失败: {}".format(
                guard.compact_error(exc, secrets=guard.telegram_secrets(telegram))
            ),
            502,
        )


def test_current_telegram(guard):
    config = guard.load_config()
    return _telegram_test(
        guard,
        config.get("telegram", {}),
        bool(config.get("force_ipv4", True)),
    )


def _connection_candidate(guard, data, config):
    telegram = _copy(config.get("telegram", {}))
    mode = str(data.get("connection_mode", "") or "").strip()
    if mode not in CONNECTION_LABELS:
        raise ManagementError("Telegram 连接方式无效")
    telegram["connection_mode"] = mode
    if mode in ("socks5", "http"):
        proxy_url = str(data.get("proxy_url", "") or "").strip()
        if proxy_url:
            telegram["proxy_url"] = proxy_url
    elif mode == "api_proxy":
        api_base_url = str(data.get("api_base_url", "") or "").strip()
        if api_base_url:
            telegram["api_base_url"] = api_base_url.rstrip("/")
    elif mode == "node":
        try:
            index = int(data.get("node_index"))
        except (TypeError, ValueError):
            raise ManagementError("请选择节点")
        nodes = guard.telegram_node_urls(telegram)
        if index < 0 or index >= len(nodes):
            raise ManagementError("节点不存在", 404)
        telegram["node_url"] = nodes[index]
    telegram["node_urls"] = guard.telegram_node_urls(telegram)
    return telegram


def configure_telegram_connection(guard, data):
    config = guard.load_config()
    candidate = _connection_candidate(guard, data, config)
    result = _telegram_test(
        guard,
        candidate,
        bool(config.get("force_ipv4", True)),
        bool(data.get("install_core", True)),
    )
    save = data.get("save", True)
    if not isinstance(save, bool):
        raise ManagementError("save 必须是布尔值")
    if save:
        config["telegram"] = candidate
        _save_config(guard, config)
    result["saved"] = save
    result["telegram"] = telegram_payload(guard, candidate)
    return result


def add_telegram_node(guard, data):
    node_url = str(data.get("node_url", "") or "").strip()
    if not node_url:
        raise ManagementError("节点链接不能为空")
    try:
        description = telegram_proxy.describe_node_link(node_url)
    except telegram_proxy.ProxyError as exc:
        raise ManagementError("节点链接无效: {}".format(exc))
    config = guard.load_config()
    current = config.setdefault("telegram", {})
    nodes = guard.telegram_node_urls(current)
    if node_url in nodes:
        raise ManagementError("该节点已经保存", 409)
    candidate = _copy(current)
    candidate["node_url"] = node_url
    candidate["node_urls"] = nodes + [node_url]
    candidate["connection_mode"] = "node"
    result = _telegram_test(
        guard,
        candidate,
        bool(config.get("force_ipv4", True)),
        bool(data.get("install_core", True)),
    )
    current["node_urls"] = nodes + [node_url]
    config["telegram"] = current
    _save_config(guard, config)
    telegram_proxy.stop_node_proxy()
    result.update({"saved": True, "description": description})
    return result


def telegram_node_action(guard, index, action):
    config = guard.load_config()
    telegram = config.setdefault("telegram", {})
    nodes = guard.telegram_node_urls(telegram)
    if index < 0 or index >= len(nodes):
        raise ManagementError("节点不存在", 404)
    node_url = nodes[index]
    if action == "delete":
        remaining = [value for value in nodes if value != node_url]
        telegram["node_urls"] = remaining
        if str(telegram.get("node_url", "")) == node_url:
            telegram["node_url"] = ""
            telegram["connection_mode"] = "direct"
        _save_config(guard, config)
        telegram_proxy.stop_node_proxy()
        return {"deleted": _node_description(node_url)}
    if action not in ("test", "select"):
        raise ManagementError("节点操作无效")
    candidate = _copy(telegram)
    candidate["node_url"] = node_url
    candidate["connection_mode"] = "node"
    result = _telegram_test(
        guard, candidate, bool(config.get("force_ipv4", True)), True
    )
    if action == "select":
        config["telegram"] = candidate
        _save_config(guard, config)
        result["saved"] = True
    else:
        result["saved"] = False
        telegram_proxy.stop_node_proxy()
    return result


def check_update():
    try:
        import manager

        remote = manager.check_for_github_update()
    except Exception as exc:
        raise ManagementError("无法检查 GitHub 更新: {}".format(exc), 502)
    return {
        "current_version": manager.APP_VERSION,
        "available": bool(remote and remote.get("available")),
        "latest_version": remote.get("version") if remote else None,
        "deployment": "docker"
        if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1"
        else "native",
    }


def detached_process(command, log_name):
    log_path = APP_DIR / "logs" / log_name
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("ab", buffering=0)
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            close_fds=True,
            start_new_session=True,
        )
    except Exception:
        raise
    finally:
        log_handle.close()
    return process.pid


def systemd_update_process(command, log_name):
    systemd_run = shutil.which("systemd-run")
    if not systemd_run:
        raise ManagementError(
            "当前 systemd 环境缺少 systemd-run，无法从网页安全更新；"
            "请通过 SSH 执行 aliyun-guard update",
            500,
        )
    log_path = APP_DIR / "logs" / log_name
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.touch(mode=0o600, exist_ok=True)
    os.chmod(log_path, 0o600)
    unit = "aliyun-guard-update-{}-{}".format(os.getpid(), int(time.time() * 1000))
    shell_command = 'log_path=$1; shift; exec "$@" >>"$log_path" 2>&1'
    launcher = [
        systemd_run,
        "--quiet",
        "--no-block",
        "--unit={}".format(unit),
        "/bin/sh",
        "-c",
        shell_command,
        "aliyun-guard-update",
        str(log_path),
        *command,
    ]
    try:
        result = subprocess.run(
            launcher,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
            check=False,
        )
    except Exception as exc:
        raise ManagementError("启动独立更新服务失败: {}".format(exc), 500)
    if result.returncode != 0:
        detail = str(result.stdout or "systemd-run 返回错误").strip()
        raise ManagementError("启动独立更新服务失败: {}".format(detail), 500)
    return unit


def service_command(action):
    if action != "restart":
        raise ManagementError("服务操作无效")
    if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
        try:
            return detached_process(
                ["/bin/sh", "-c", "sleep 1; kill -TERM 1"],
                "web-service.log",
            )
        except Exception as exc:
            raise ManagementError("容器重启请求失败: {}".format(exc), 500)
    control = APP_DIR / "control.sh"
    if not control.exists():
        raise ManagementError("控制脚本不存在", 500)
    try:
        return detached_process([str(control), action], "web-service.log")
    except Exception as exc:
        raise ManagementError("服务重启失败: {}".format(exc), 500)


def install_update():
    if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
        raise ManagementError(
            "Docker 部署请在宿主机执行 git pull && docker compose up -d --build",
            409,
        )
    manager_path = APP_DIR / "manager.py"
    if not manager_path.exists():
        raise ManagementError("更新程序不存在", 500)
    command = [sys.executable, str(manager_path), "update", "--yes"]
    backend_path = APP_DIR / "service_backend"
    try:
        backend = backend_path.read_text(encoding="utf-8").strip().lower()
    except OSError:
        backend = ""
    try:
        if backend == "systemd":
            return systemd_update_process(command, "web-update.log")
        return detached_process(command, "web-update.log")
    except ManagementError:
        raise
    except Exception as exc:
        raise ManagementError("启动更新失败: {}".format(exc), 500)
