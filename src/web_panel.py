#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Authenticated web control panel for Aliyun Guard."""

import argparse
import contextlib
import datetime as dt
import hashlib
import hmac
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

import web_actions

try:
    import fcntl
except ImportError:  # pragma: no cover - cron supervision runs on Linux
    fcntl = None


APP_VERSION = "1.4.0"
APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
HTML_FILE = APP_DIR / "web_panel.html"
PID_FILE = APP_DIR / "web-panel.pid"
SUPERVISOR_LOCK_FILE = APP_DIR / "web-panel-supervisor.lock"
DISABLED_FILE = APP_DIR / "disabled"
BACKEND_FILE = APP_DIR / "service_backend"
MAX_BODY_BYTES = 64 * 1024
SESSION_SECONDS = 12 * 60 * 60
PASSWORD_ITERATIONS = 260000

DEFAULT_WEB_CONFIG = {
    "enabled": False,
    "host": "127.0.0.1",
    "port": 8765,
    "username": "admin",
    "password_hash": "",
    "cookie_secure": False,
}


class WebPanelError(RuntimeError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def hash_password(password, iterations=PASSWORD_ITERATIONS):
    password = str(password or "")
    if len(password) < 8:
        raise ValueError("网页面板密码至少需要 8 个字符")
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, int(iterations)
    )
    return "pbkdf2_sha256${}${}${}".format(
        int(iterations), salt.hex(), digest.hex()
    )


def verify_password(password, encoded):
    try:
        algorithm, iterations, salt_hex, expected_hex = str(encoded).split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(expected_hex)
        actual = hashlib.pbkdf2_hmac(
            "sha256", str(password or "").encode("utf-8"), salt, int(iterations)
        )
        return hmac.compare_digest(actual, expected)
    except (TypeError, ValueError):
        return False


def get_web_config(config):
    result = dict(DEFAULT_WEB_CONFIG)
    configured = config.get("web_panel", {}) if isinstance(config, dict) else {}
    if isinstance(configured, dict):
        result.update(configured)
    result["enabled"] = bool(result.get("enabled", False))
    result["host"] = str(result.get("host", "127.0.0.1") or "127.0.0.1").strip()
    result["username"] = str(result.get("username", "admin") or "admin").strip()
    result["password_hash"] = str(result.get("password_hash", "") or "")
    result["cookie_secure"] = bool(result.get("cookie_secure", False))
    try:
        result["port"] = int(result.get("port", 8765))
    except (TypeError, ValueError):
        result["port"] = 0
    return result


def validate_web_config(config):
    web = get_web_config(config)
    if web["host"] not in ("127.0.0.1", "0.0.0.0"):
        raise WebPanelError("网页面板监听地址只能是 127.0.0.1 或 0.0.0.0")
    if web["port"] < 1024 or web["port"] > 65535:
        raise WebPanelError("网页面板端口必须在 1024 到 65535 之间")
    if not web["username"] or len(web["username"]) > 64:
        raise WebPanelError("网页面板用户名不能为空且不能超过 64 个字符")
    if web["enabled"]:
        if not web["password_hash"] or not web["password_hash"].startswith(
            "pbkdf2_sha256$"
        ):
            raise WebPanelError("网页面板尚未设置有效登录密码")
    return web


def _usable_ipv4(value):
    try:
        address = ipaddress.ip_address(str(value or ""))
    except ValueError:
        return False
    return (
        isinstance(address, ipaddress.IPv4Address)
        and not address.is_loopback
        and not address.is_unspecified
        and not address.is_link_local
        and not address.is_multicast
    )


def detect_primary_ipv4():
    for destination in (("1.1.1.1", 80), ("8.8.8.8", 80)):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
                connection.connect(destination)
                candidate = connection.getsockname()[0]
            if _usable_ipv4(candidate):
                return candidate
        except OSError:
            continue
    try:
        addresses = socket.getaddrinfo(
            socket.gethostname(), None, socket.AF_INET, socket.SOCK_DGRAM
        )
    except OSError:
        addresses = []
    for address in addresses:
        candidate = address[4][0]
        if _usable_ipv4(candidate):
            return candidate
    return ""


def browser_access_url(web, local_ip=None):
    host = str(web.get("host", "127.0.0.1"))
    if host == "0.0.0.0":
        host = detect_primary_ipv4() if local_ip is None else local_ip
        host = host or "服务器IP"
    return "http://{}:{}".format(host, int(web.get("port", 8765)))


def service_backend():
    if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
        return "docker"
    try:
        value = BACKEND_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        value = "unknown"
    return value or "unknown"


def _safe_instances(state):
    instances = state.get("instances", {}) if isinstance(state, dict) else {}
    return instances if isinstance(instances, dict) else {}


def _safe_history(state):
    history = state.get("history", []) if isinstance(state, dict) else []
    return history if isinstance(history, list) else []


def dashboard_payload(guard, config=None, state=None, job=None):
    config = config or guard.load_config()
    state = state or guard.load_state()
    now = dt.datetime.now().astimezone()
    states = _safe_instances(state)
    history = _safe_history(state)
    users = []
    for index, user in enumerate(config.get("users", [])):
        instance_id = str(user.get("instance_id", ""))
        current = states.get(instance_id, {})
        if not isinstance(current, dict):
            current = {}
        billing = guard.get_billing_config(user)
        schedule = guard.get_schedule_config(user)
        next_event = guard.next_schedule_event(user, now) if schedule["enabled"] else None
        points = []
        for sample in history[-96:]:
            if not isinstance(sample, dict):
                continue
            values = sample.get("instances", {})
            value = values.get(instance_id, {}) if isinstance(values, dict) else {}
            if isinstance(value, dict) and value.get("traffic_gb") is not None:
                points.append(
                    {
                        "at": sample.get("at"),
                        "value": value.get("traffic_gb"),
                        "status": value.get("status_after") or value.get("status"),
                        "status_before": value.get("status_before"),
                        "action": value.get("action", "none"),
                        "action_performed": bool(
                            value.get("action_performed", False)
                        ),
                        "message": value.get("message", ""),
                        "level": value.get("level", "unknown"),
                    }
                )
        traffic = current.get("traffic_gb")
        limit = float(user.get("traffic_limit_gb", 0) or 0)
        percent = None
        if traffic is not None and limit > 0:
            percent = round((float(traffic) / limit) * 100.0, 2)
        users.append(
            {
                "index": index,
                "name": str(user.get("name") or instance_id),
                "instance_id": instance_id,
                "region": str(user.get("region", "")),
                "paused": bool(user.get("paused", False)),
                "actions_enabled": bool(user.get("actions_enabled", True)),
                "traffic_gb": traffic,
                "traffic_limit_gb": limit,
                "traffic_percent": percent,
                "status": current.get("status_after") or "Unknown",
                "level": current.get("level") or "unknown",
                "message": current.get("message") or "尚未完成检测",
                "checked_at": current.get("checked_at"),
                "bill_amount": current.get("bill_amount"),
                "bill_currency": current.get("bill_currency"),
                "bill_error": current.get("bill_error"),
                "bill_symbol": str(billing.get("currency_symbol", "")),
                "billing_enabled": bool(billing.get("enabled", True)),
                "schedule": {
                    "enabled": schedule["enabled"],
                    "start_time": schedule["start_time"],
                    "stop_time": schedule["stop_time"],
                    "target": guard.schedule_target(user, now)
                    if schedule["enabled"]
                    else None,
                    "next_at": next_event[0].isoformat(timespec="minutes")
                    if next_event
                    else None,
                    "next_action": next_event[1] if next_event else None,
                },
                "history": points,
            }
        )
    finished = state.get("last_cycle_finished_at")
    stale = True
    if finished:
        try:
            age = now.timestamp() - dt.datetime.fromisoformat(finished).timestamp()
            stale = age > max(180, int(config.get("interval_seconds", 300)) * 2)
        except (TypeError, ValueError):
            pass
    web = get_web_config(config)
    return {
        "version": APP_VERSION,
        "now": now.isoformat(timespec="seconds"),
        "users": users,
        "service": {
            "cycle_count": int(state.get("cycle_count", 0) or 0),
            "last_finished_at": finished,
            "last_ok": bool(state.get("last_cycle_ok", False)),
            "last_error_count": int(state.get("last_cycle_error_count", 0) or 0),
            "telegram_error": state.get("telegram_error"),
            "stale": stale,
        },
        "settings": {
            "interval_seconds": int(config.get("interval_seconds", 300)),
            "notification_mode": str(config.get("notification_mode", "always")),
            "force_ipv4": bool(config.get("force_ipv4", True)),
            "web_host": web["host"],
            "web_port": web["port"],
        },
        "job": dict(job or {}),
    }


def management_payload(guard):
    payload = web_actions.management_payload(guard, service_backend())
    payload["version"] = APP_VERSION
    web = payload["web"]
    web["local_ip"] = detect_primary_ipv4()
    web["browser_url"] = browser_access_url(web, web["local_ip"])
    web["http_warning"] = web["host"] == "0.0.0.0"
    return payload


def read_recent_logs(guard, limit=200):
    limit = max(20, min(500, int(limit)))
    path = Path(guard.LOG_FILE)
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError as exc:
        raise WebPanelError("无法读取日志: {}".format(exc), 500)
    return [line.rstrip("\r\n") for line in lines[-limit:]]


def save_config(guard, config):
    guard.validate_config(config)
    validate_web_config(config)
    guard.atomic_write_json(guard.CONFIG_FILE, config, mode=0o600)


def update_schedule(guard, index, data):
    config = guard.load_config()
    users = config.get("users", [])
    if index < 0 or index >= len(users):
        raise WebPanelError("实例不存在", 404)
    enabled = data.get("enabled")
    if not isinstance(enabled, bool):
        raise WebPanelError("enabled 必须是布尔值")
    current = guard.get_schedule_config(users[index])
    start_time = guard.normalize_schedule_time(
        data.get("start_time", current["start_time"]), "开机时间"
    )
    stop_time = guard.normalize_schedule_time(
        data.get("stop_time", current["stop_time"]), "关机时间"
    )
    if enabled and start_time == stop_time:
        raise WebPanelError("开机时间和关机时间不能相同")
    users[index]["schedule"] = {
        "enabled": enabled,
        "start_time": start_time,
        "stop_time": stop_time,
    }
    save_config(guard, config)
    return users[index]["schedule"]


def update_pause(guard, index, paused):
    if not isinstance(paused, bool):
        raise WebPanelError("paused 必须是布尔值")
    config = guard.load_config()
    users = config.get("users", [])
    if index < 0 or index >= len(users):
        raise WebPanelError("实例不存在", 404)
    users[index]["paused"] = paused
    save_config(guard, config)
    return paused


def update_settings(guard, data):
    config = guard.load_config()
    try:
        interval = int(data.get("interval_seconds"))
    except (TypeError, ValueError):
        raise WebPanelError("检测间隔必须是整数")
    if interval < 60 or interval > 86400:
        raise WebPanelError("检测间隔必须在 60 到 86400 秒之间")
    mode = str(data.get("notification_mode", ""))
    if mode not in ("always", "events", "errors"):
        raise WebPanelError("通知模式无效")
    config["interval_seconds"] = interval
    config["notification_mode"] = mode
    save_config(guard, config)
    return {"interval_seconds": interval, "notification_mode": mode}


def control_instance(guard, index, action):
    if action not in ("start", "stop"):
        raise WebPanelError("开关机动作无效")
    with guard.cycle_lock() as locked:
        if not locked:
            raise WebPanelError("检测任务正在运行，请稍后再试", 409)
        config = guard.load_config()
        users = config.get("users", [])
        if index < 0 or index >= len(users):
            raise WebPanelError("实例不存在", 404)
        user = users[index]
        name = str(user.get("name") or user.get("instance_id"))
        secrets_to_hide = (user.get("ak"), user.get("sk"))
        schedule_target = guard.schedule_target(user)
        automation_active = bool(user.get("actions_enabled", True)) and not bool(
            user.get("paused", False)
        )
        if action == "stop" and automation_active and schedule_target != "stopped":
            raise WebPanelError(
                "自动保活当前有效，直接关机会被重新启动；请先暂停该实例监控", 409
            )
        if action == "start" and automation_active and schedule_target == "stopped":
            raise WebPanelError(
                "当前处于计划关机时段；请先暂停监控或修改定时计划", 409
            )
        try:
            before = guard.query_instance_status(user)
            traffic = None
            performed = False
            if action == "start":
                traffic = guard.query_cdt_traffic_gb(user)
                limit = float(user.get("traffic_limit_gb", 0) or 0)
                if traffic >= limit:
                    raise WebPanelError(
                        "当前 CDT 流量 {:.2f} GB 已达到 {:.2f} GB 阈值，拒绝开机".format(
                            traffic, limit
                        ),
                        409,
                    )
                if before != "Running":
                    guard.start_instance(user)
                    performed = True
                    after, poll_error = guard.wait_for_status(
                        user,
                        "Running",
                        int(config.get("start_wait_seconds", 90)),
                        int(config.get("start_poll_seconds", 5)),
                    )
                else:
                    after, poll_error = before, None
            else:
                if before != "Stopped":
                    guard.stop_instance(user)
                    performed = True
                    after, poll_error = guard.wait_for_status(
                        user,
                        "Stopped",
                        int(config.get("stop_wait_seconds", 45)),
                        int(config.get("start_poll_seconds", 5)),
                    )
                else:
                    after, poll_error = before, None
        except WebPanelError:
            raise
        except Exception as exc:
            raise WebPanelError(
                "实例{}失败: {}".format(
                    "开机" if action == "start" else "关机",
                    guard.compact_error(exc, secrets=secrets_to_hide),
                ),
                502,
            )
        message = "网页控制台手动{}\n实例: {} ({})\n状态: {} -> {}".format(
            "开机" if action == "start" else "关机",
            name,
            user.get("instance_id"),
            before,
            after or "Unknown",
        )
        if poll_error:
            message += "\n状态复查: {}".format(poll_error)
        notify_error = None
        try:
            guard.send_telegram_message(config.get("telegram", {}), message)
        except Exception as exc:
            notify_error = guard.compact_error(
                exc, secrets=guard.telegram_secrets(config.get("telegram", {}))
            )
        checked_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
        state = guard.load_state()
        instances = state.setdefault("instances", {})
        previous = instances.get(str(user.get("instance_id", "")), {})
        if not isinstance(previous, dict):
            previous = {}
        if traffic is None:
            traffic = previous.get("traffic_gb")
        level = "action" if performed else "ok"
        instances[str(user.get("instance_id", ""))] = dict(
            previous,
            name=name,
            traffic_gb=traffic,
            status_after=after or before or "Unknown",
            level=level,
            message=message.replace("\n", "；"),
            checked_at=checked_at,
        )
        history = state.get("history", [])
        if not isinstance(history, list):
            history = []
        history.append(
            {
                "at": checked_at,
                "instances": {
                    str(user.get("instance_id", "")): {
                        "traffic_gb": traffic,
                        "status": after or before or "Unknown",
                        "status_before": before,
                        "status_after": after or before or "Unknown",
                        "action": "manual_{}".format(action),
                        "action_performed": performed,
                        "message": message.replace("\n", "；"),
                        "level": level,
                    }
                },
            }
        )
        state["history"] = history[-576:]
        guard.save_state(state)
        return {
            "before": before,
            "after": after or "Unknown",
            "message": message,
            "notification_error": notify_error,
        }


class PanelServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, guard, config, html):
        super().__init__(address, handler)
        self.guard = guard
        self.initial_config = config
        self.html = html
        self.sessions = {}
        self.session_lock = threading.Lock()
        self.login_attempts = {}
        self.login_attempt_lock = threading.Lock()
        self.job_lock = threading.Lock()
        self.job = {"running": False, "started_at": None, "finished_at": None, "error": None}

    def delayed_restart(self, delay=0.6):
        def restart():
            try:
                web_actions.service_command("restart")
            except Exception as exc:
                try:
                    self.guard.LOGGER.error("Web requested restart failed: %s", exc)
                except Exception:
                    pass

        timer = threading.Timer(delay, restart)
        timer.daemon = True
        timer.start()

    def create_session(self):
        session_id = secrets.token_urlsafe(32)
        now = time.time()
        data = {
            "csrf": secrets.token_urlsafe(24),
            "expires": now + SESSION_SECONDS,
        }
        with self.session_lock:
            self.sessions = {
                key: value
                for key, value in self.sessions.items()
                if value.get("expires", 0) >= now
            }
            self.sessions[session_id] = data
        return session_id, data

    def get_session(self, session_id):
        if not session_id:
            return None
        with self.session_lock:
            data = self.sessions.get(session_id)
            if not data:
                return None
            if data["expires"] < time.time():
                self.sessions.pop(session_id, None)
                return None
            data["expires"] = time.time() + SESSION_SECONDS
            return dict(data)

    def delete_session(self, session_id):
        with self.session_lock:
            self.sessions.pop(session_id, None)

    def login_allowed(self, address):
        now = time.time()
        with self.login_attempt_lock:
            attempts = [
                value
                for value in self.login_attempts.get(address, [])
                if now - value < 300
            ]
            self.login_attempts[address] = attempts
            return len(attempts) < 5

    def record_login_failure(self, address):
        with self.login_attempt_lock:
            self.login_attempts.setdefault(address, []).append(time.time())

    def clear_login_failures(self, address):
        with self.login_attempt_lock:
            self.login_attempts.pop(address, None)

    def start_cycle_job(self, dry_run=False):
        if not isinstance(dry_run, bool):
            raise WebPanelError("dry_run 必须是布尔值")
        with self.job_lock:
            if self.job.get("running"):
                raise WebPanelError("检测任务已经在运行", 409)
            self.job = {
                "running": True,
                "started_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
                "finished_at": None,
                "error": None,
                "dry_run": dry_run,
            }

        def worker():
            error = None
            try:
                with self.guard.cycle_lock() as locked:
                    if not locked:
                        raise WebPanelError("其他检测任务正在运行", 409)
                    self.guard.run_cycle(dry_run=dry_run)
            except Exception as exc:
                error = self.guard.compact_error(exc)
            with self.job_lock:
                self.job["running"] = False
                self.job["finished_at"] = dt.datetime.now().astimezone().isoformat(
                    timespec="seconds"
                )
                self.job["error"] = error

        threading.Thread(target=worker, name="aliyun-guard-web-cycle", daemon=True).start()
        return dict(self.job)


class PanelHandler(BaseHTTPRequestHandler):
    server_version = "AliyunGuardWeb"
    sys_version = ""

    def log_message(self, fmt, *args):
        try:
            self.server.guard.LOGGER.info("Web %s - %s", self.client_address[0], fmt % args)
        except Exception:
            pass

    def _base_headers(self, content_type, length, status=200, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'unsafe-inline'; img-src 'self' data:; "
            "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        )
        for key, value in extra or []:
            self.send_header(key, value)
        self.end_headers()

    def _json(self, value, status=200, extra=None):
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._base_headers("application/json; charset=utf-8", len(body), status, extra)
        self.wfile.write(body)

    def _html(self):
        body = self.server.html.encode("utf-8")
        self._base_headers("text/html; charset=utf-8", len(body))
        self.wfile.write(body)

    def _empty(self, status=204):
        self._base_headers("image/x-icon", 0, status)

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise WebPanelError("请求长度无效")
        if length <= 0 or length > MAX_BODY_BYTES:
            raise WebPanelError("请求内容为空或过大", 413)
        try:
            value = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise WebPanelError("JSON 请求格式无效")
        if not isinstance(value, dict):
            raise WebPanelError("JSON 顶层必须是对象")
        return value

    def _session_id(self):
        raw = self.headers.get("Cookie", "")
        jar = cookies.SimpleCookie()
        try:
            jar.load(raw)
        except cookies.CookieError:
            return ""
        morsel = jar.get(self._session_cookie_name())
        return morsel.value if morsel else ""

    def _session_cookie_name(self):
        return "ag_session_secure" if self._browser_uses_https() else "ag_session"

    def _session_cookie_header(self, value, max_age=SESSION_SECONDS):
        secure = self._browser_uses_https()
        cookie = "{}={}; Path=/; Max-Age={}; HttpOnly; SameSite=Strict".format(
            self._session_cookie_name(), value, int(max_age)
        )
        if secure:
            cookie += "; Secure"
        return cookie

    def _authenticated(self, require_csrf=False):
        session_id = self._session_id()
        session = self.server.get_session(session_id)
        if not session:
            raise WebPanelError("请先登录", 401)
        if require_csrf and not hmac.compare_digest(
            str(self.headers.get("X-CSRF-Token", "")), str(session["csrf"])
        ):
            raise WebPanelError("CSRF 校验失败", 403)
        return session_id, session

    def _route_parts(self):
        path = urllib.parse.urlsplit(self.path).path
        return [urllib.parse.unquote(value) for value in path.strip("/").split("/") if value]

    def do_GET(self):
        try:
            parts = self._route_parts()
            if not parts or parts == ["index.html"]:
                self._html()
                return
            if parts == ["favicon.ico"]:
                self._empty()
                return
            if parts == ["healthz"]:
                self._json({"ok": True, "version": APP_VERSION})
                return
            if parts == ["api", "session"]:
                session = self.server.get_session(self._session_id())
                self._json(
                    {
                        "authenticated": bool(session),
                        "csrf": session.get("csrf") if session else None,
                        "version": APP_VERSION,
                        "secure_cookie": self._browser_uses_https(),
                    }
                )
                return
            self._authenticated()
            if parts == ["api", "dashboard"]:
                with self.server.job_lock:
                    job = dict(self.server.job)
                self._json(dashboard_payload(self.server.guard, job=job))
                return
            if parts == ["api", "management"]:
                self._json(management_payload(self.server.guard))
                return
            if parts == ["api", "update"]:
                self._json(web_actions.check_update())
                return
            if parts == ["api", "logs"]:
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                limit = query.get("limit", ["200"])[0]
                self._json({"lines": read_recent_logs(self.server.guard, limit)})
                return
            if parts == ["api", "job"]:
                with self.server.job_lock:
                    self._json(dict(self.server.job))
                return
            raise WebPanelError("接口不存在", 404)
        except web_actions.ManagementError as exc:
            payload = {"ok": False, "error": str(exc)}
            if exc.details is not None:
                payload["details"] = exc.details
            self._json(payload, exc.status)
        except WebPanelError as exc:
            self._json({"ok": False, "error": str(exc)}, exc.status)
        except Exception as exc:
            self._json({"ok": False, "error": "服务器内部错误"}, 500)
            self.server.guard.LOGGER.exception("Web GET error: %s", exc)

    def do_POST(self):
        try:
            parts = self._route_parts()
            if parts == ["api", "login"]:
                self._handle_login()
                return
            session_id, _session = self._authenticated(require_csrf=True)
            if parts == ["api", "logout"]:
                self.server.delete_session(session_id)
                self._json(
                    {"ok": True},
                    extra=[("Set-Cookie", self._session_cookie_header("", max_age=0))],
                )
                return
            if parts == ["api", "run"]:
                data = self._read_json()
                self._json(
                    {
                        "ok": True,
                        "job": self.server.start_cycle_job(
                            data.get("dry_run", False)
                        ),
                    },
                    202,
                )
                return
            if parts == ["api", "settings"]:
                result = web_actions.update_global_settings(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "settings": result})
                return
            if parts == ["api", "web-settings"]:
                result = web_actions.update_web_settings(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "web": result})
                if result.get("restart_required"):
                    self.server.delayed_restart()
                return
            if parts == ["api", "telegram", "identity"]:
                result = web_actions.update_telegram_identity(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "telegram": result})
                return
            if parts == ["api", "telegram", "test"]:
                self._read_json()
                result = web_actions.test_current_telegram(self.server.guard)
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "telegram", "connection"]:
                result = web_actions.configure_telegram_connection(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "telegram", "nodes"]:
                result = web_actions.add_telegram_node(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "result": result})
                return
            if (
                len(parts) == 5
                and parts[:3] == ["api", "telegram", "nodes"]
            ):
                try:
                    node_index = int(parts[3])
                except ValueError:
                    raise WebPanelError("节点序号无效")
                self._read_json()
                result = web_actions.telegram_node_action(
                    self.server.guard, node_index, parts[4]
                )
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "instances"]:
                result = web_actions.save_instance(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "result": result})
                return
            if len(parts) == 3 and parts[:2] == ["api", "instances"]:
                try:
                    index = int(parts[2])
                except ValueError:
                    raise WebPanelError("实例序号无效")
                result = web_actions.save_instance(
                    self.server.guard, self._read_json(), index
                )
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "service", "restart"]:
                self._read_json()
                self.server.delayed_restart()
                self._json({"ok": True, "message": "后台服务重启已安排"}, 202)
                return
            if parts == ["api", "update", "install"]:
                self._read_json()
                pid = web_actions.install_update()
                self._json({"ok": True, "pid": pid}, 202)
                return
            if len(parts) == 4 and parts[:2] == ["api", "instances"]:
                try:
                    index = int(parts[2])
                except ValueError:
                    raise WebPanelError("实例序号无效")
                data = self._read_json()
                if parts[3] == "validate":
                    result = web_actions.validate_instance(self.server.guard, index)
                    self._json({"ok": True, "result": result})
                    return
                if parts[3] == "delete":
                    result = web_actions.delete_instance(
                        self.server.guard, index, data.get("instance_id")
                    )
                    self._json({"ok": True, "result": result})
                    return
                if parts[3] == "schedule":
                    result = update_schedule(self.server.guard, index, data)
                    self._json({"ok": True, "schedule": result})
                    return
                if parts[3] == "pause":
                    result = update_pause(self.server.guard, index, data.get("paused"))
                    self._json({"ok": True, "paused": result})
                    return
                if parts[3] == "power":
                    result = control_instance(self.server.guard, index, data.get("action"))
                    self._json({"ok": True, "result": result})
                    return
            raise WebPanelError("接口不存在", 404)
        except web_actions.ManagementError as exc:
            payload = {"ok": False, "error": str(exc)}
            if exc.details is not None:
                payload["details"] = exc.details
            self._json(payload, exc.status)
        except WebPanelError as exc:
            self._json({"ok": False, "error": str(exc)}, exc.status)
        except Exception as exc:
            self._json({"ok": False, "error": "服务器内部错误"}, 500)
            self.server.guard.LOGGER.exception("Web POST error: %s", exc)

    def _handle_login(self):
        address = self.client_address[0]
        if not self.server.login_allowed(address):
            raise WebPanelError("登录失败次数过多，请 5 分钟后再试", 429)
        data = self._read_json()
        config = self.server.guard.load_config()
        web = get_web_config(config)
        username_ok = hmac.compare_digest(
            str(data.get("username", "")), web["username"]
        )
        password_ok = verify_password(data.get("password", ""), web["password_hash"])
        if not username_ok or not password_ok:
            self.server.record_login_failure(address)
            raise WebPanelError("用户名或密码错误", 401)
        self.server.clear_login_failures(address)
        session_id, session = self.server.create_session()
        secure = self._browser_uses_https()
        self._json(
            {
                "ok": True,
                "csrf": session["csrf"],
                "secure_cookie": secure,
            },
            extra=[("Set-Cookie", self._session_cookie_header(session_id))],
        )

    def _browser_uses_https(self):
        forwarded_proto = self.headers.get("X-Forwarded-Proto", "")
        if forwarded_proto.split(",", 1)[0].strip().lower() == "https":
            return True
        for name in ("Origin", "Referer"):
            value = self.headers.get(name, "")
            if value and urllib.parse.urlsplit(value).scheme.lower() == "https":
                return True
        return False


def create_server(guard, config=None, host=None, port=None, html=None):
    config = config or guard.load_config()
    web = get_web_config(config)
    bind_host = host if host is not None else web["host"]
    bind_port = int(port if port is not None else web["port"])
    if html is None:
        try:
            html = HTML_FILE.read_text(encoding="utf-8")
        except OSError as exc:
            raise WebPanelError("无法读取网页文件: {}".format(exc), 500)
    return PanelServer((bind_host, bind_port), PanelHandler, guard, config, html)


def start_background(guard, config=None):
    config = config or guard.load_config()
    web = validate_web_config(config)
    if not web["enabled"]:
        return None
    server = create_server(guard, config)
    thread = threading.Thread(
        target=server.serve_forever,
        kwargs={"poll_interval": 0.5},
        name="aliyun-guard-web",
        daemon=True,
    )
    thread.start()
    guard.LOGGER.info("网页控制面板已启动: http://%s:%s", web["host"], web["port"])
    return server


def _load_guard():
    import aliyun_guard

    return aliyun_guard


def _pid_is_web_process(pid):
    if pid <= 1:
        return False
    path = Path("/proc") / str(pid) / "cmdline"
    try:
        command = path.read_bytes().decode("utf-8", errors="ignore")
    except OSError:
        return False
    return "web_panel.py" in command and "serve" in command


def _read_pid():
    try:
        return int(PID_FILE.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return 0


def stop_supervised():
    pid = _read_pid()
    if not _pid_is_web_process(pid):
        try:
            PID_FILE.unlink()
        except OSError:
            pass
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return False
    deadline = time.time() + 8
    while time.time() < deadline and _pid_is_web_process(pid):
        time.sleep(0.2)
    if _pid_is_web_process(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        deadline = time.time() + 2
        while time.time() < deadline and _pid_is_web_process(pid):
            time.sleep(0.1)
    stopped = not _pid_is_web_process(pid)
    try:
        PID_FILE.unlink()
    except OSError:
        pass
    return stopped


@contextlib.contextmanager
def supervisor_lock():
    SUPERVISOR_LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    handle = SUPERVISOR_LOCK_FILE.open("a+")
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


def serve_foreground():
    guard = _load_guard()
    guard.configure_logging(console=True)
    config = guard.load_config()
    web = validate_web_config(config)
    if not web["enabled"]:
        print("网页控制面板尚未启用。")
        return 2
    server = create_server(guard, config)
    PID_FILE.write_text(str(os.getpid()), encoding="ascii")
    os.chmod(str(PID_FILE), 0o600)

    def stop(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print("网页控制面板: http://{}:{}".format(web["host"], web["port"]))
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        try:
            PID_FILE.unlink()
        except OSError:
            pass
    return 0


def ensure_supervised():
    with supervisor_lock() as locked:
        if not locked:
            return 0
        guard = _load_guard()
        if BACKEND_FILE.exists() and BACKEND_FILE.read_text(encoding="utf-8").strip() != "cron":
            return 0
        config = guard.load_config()
        web = get_web_config(config)
        if DISABLED_FILE.exists() or not web["enabled"]:
            stop_supervised()
            return 0
        pid = _read_pid()
        if _pid_is_web_process(pid):
            return 0
        log_path = APP_DIR / "logs" / "web.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("ab", buffering=0) as log_handle:
            subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "serve"],
                stdin=subprocess.DEVNULL,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                close_fds=True,
                start_new_session=True,
            )
    return 0


def show_status():
    guard = _load_guard()
    config = guard.load_config()
    web = get_web_config(config)
    print("网页面板: {}".format("已启用" if web["enabled"] else "已关闭"))
    print("监听地址: http://{}:{}".format(web["host"], web["port"]))
    print("浏览器访问: {}".format(browser_access_url(web)))
    print("HTTPS 反向代理: 支持（会话 Cookie 自动适配）")
    backend = BACKEND_FILE.read_text(encoding="utf-8").strip() if BACKEND_FILE.exists() else "unknown"
    if backend == "cron":
        print("进程状态: {}".format("运行中" if _pid_is_web_process(_read_pid()) else "未运行"))
    else:
        print("进程状态: 随 aliyun-guard 后台服务运行")
    return 0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Aliyun Guard 网页控制面板")
    parser.add_argument("command", choices=("serve", "ensure", "stop", "restart", "status"))
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.command == "serve":
        return serve_foreground()
    if args.command == "ensure":
        return ensure_supervised()
    if args.command == "stop":
        stop_supervised()
        return 0
    if args.command == "restart":
        stop_supervised()
        return ensure_supervised()
    return show_status()


if __name__ == "__main__":
    sys.exit(main())
