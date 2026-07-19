#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""External heartbeat watchdog for Aliyun Guard."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import time


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
HEARTBEAT_FILE = Path(
    os.environ.get("ALIYUN_GUARD_HEARTBEAT", APP_DIR / "heartbeat.json")
)
WATCHDOG_STATE_FILE = Path(
    os.environ.get("ALIYUN_GUARD_WATCHDOG_STATE", APP_DIR / "watchdog-state.json")
)
BACKEND_FILE = APP_DIR / "service_backend"
DISABLED_FILE = APP_DIR / "disabled"
SERVICE_NAME = "aliyun-guard"


def _atomic_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(str(temporary), 0o600)
    os.replace(str(temporary), str(path))


def read_json(path):
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def heartbeat_age(now=None):
    now = time.time() if now is None else float(now)
    heartbeat = read_json(HEARTBEAT_FILE)
    try:
        epoch = float(heartbeat.get("epoch"))
    except (TypeError, ValueError):
        return None, heartbeat
    return max(0.0, now - epoch), heartbeat


def backend_name():
    try:
        return BACKEND_FILE.read_text(encoding="utf-8").strip() or "unknown"
    except OSError:
        return "unknown"


def restart_backend(backend=None):
    backend = backend or backend_name()
    if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
        return False, "Docker 容器由 restart policy 负责重启"
    if backend == "systemd":
        command = ["systemctl", "restart", SERVICE_NAME + ".service"]
    elif backend == "openrc":
        command = ["rc-service", SERVICE_NAME, "restart"]
    else:
        return False, "{} 后端不支持主动重启".format(backend)
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except Exception as exc:
        return False, str(exc)
    output = (result.stdout or "").strip()
    return result.returncode == 0, output or "exit {}".format(result.returncode)


def _notify(text):
    import aliyun_guard as guard

    config = guard.load_config()
    telegram = config.get("telegram", {})
    if not str(telegram.get("bot_token", "")).strip() or not str(
        telegram.get("chat_id", "")
    ).strip():
        return "Telegram 未配置"
    guard.send_telegram_message(telegram, text)
    return None


def has_valid_instance(config):
    for user in config.get("users", []):
        if not isinstance(user, dict):
            continue
        if all(
            str(user.get(field, "") or "").strip()
            for field in ("ak", "sk", "region", "instance_id")
        ):
            return True
    return False


def disabled_result(reason):
    state = read_json(WATCHDOG_STATE_FILE)
    state.update(
        {
            "checked_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
            "failed_checks": 0,
            "outage_notified": False,
            "last_status": "disabled",
            "disabled_reason": reason,
        }
    )
    _atomic_write(WATCHDOG_STATE_FILE, state)
    return {"status": "disabled", "reason": reason, "failed_checks": 0}


def check_once(now=None, restart=True, notify=True):
    import aliyun_guard as guard

    now = time.time() if now is None else float(now)
    config = guard.load_config()
    watchdog = config.get("watchdog", {})
    if not isinstance(watchdog, dict) or not watchdog.get("enabled", True):
        return disabled_result("watchdog_disabled")
    if DISABLED_FILE.exists():
        return disabled_result("service_paused")
    if not has_valid_instance(config):
        return disabled_result("no_valid_instances")
    timeout_seconds = max(120, int(watchdog.get("timeout_seconds", 600)))
    failure_threshold = max(1, int(watchdog.get("failure_threshold", 2)))
    age, heartbeat = heartbeat_age(now)
    state = read_json(WATCHDOG_STATE_FILE)
    stale = age is None or age > timeout_seconds
    failed = int(state.get("failed_checks", 0) or 0)
    outage_notified = bool(state.get("outage_notified", False))
    result = {
        "status": "healthy",
        "heartbeat_age_seconds": age,
        "failed_checks": 0,
        "last_heartbeat": heartbeat.get("at"),
        "restart_attempted": False,
        "restart_ok": None,
        "notification_error": None,
    }
    if stale:
        failed += 1
        result["status"] = "stale"
        result["failed_checks"] = failed
        if failed >= failure_threshold:
            result["status"] = "outage"
            if restart:
                result["restart_attempted"] = True
                result["restart_ok"], result["restart_detail"] = restart_backend()
            if notify and not outage_notified:
                age_text = "尚未生成心跳" if age is None else "已失联 {:.0f} 秒".format(age)
                try:
                    result["notification_error"] = _notify(
                        "Aliyun Guard 监控失联\n"
                        "时间: {}\n"
                        "状态: {}\n"
                        "连续检查失败: {} 次\n"
                        "自动重启: {}".format(
                            dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S"),
                            age_text,
                            failed,
                            "成功" if result.get("restart_ok") else "未成功或不支持",
                        )
                    )
                except Exception as exc:
                    result["notification_error"] = guard.compact_error(exc)
                outage_notified = True
    else:
        if outage_notified and notify:
            try:
                result["notification_error"] = _notify(
                    "Aliyun Guard 监控已恢复\n"
                    "时间: {}\n"
                    "当前心跳延迟: {:.0f} 秒".format(
                        dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S"),
                        age,
                    )
                )
            except Exception as exc:
                result["notification_error"] = guard.compact_error(exc)
            result["status"] = "recovered"
        failed = 0
        outage_notified = False
    state.update(
        {
            "checked_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
            "failed_checks": failed,
            "outage_notified": outage_notified,
            "last_status": result["status"],
            "last_heartbeat": heartbeat.get("at"),
        }
    )
    _atomic_write(WATCHDOG_STATE_FILE, state)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description="Aliyun Guard 外部心跳看门狗")
    parser.add_argument("--no-restart", action="store_true")
    parser.add_argument("--no-notify", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = check_once(
            restart=not args.no_restart, notify=not args.no_notify
        )
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 1 if result.get("status") == "outage" else 0
    except Exception as exc:
        print("看门狗检查失败: {}".format(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
