#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Interactive configuration manager for Aliyun Guard."""

import argparse
import datetime as dt
import getpass
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

import aliyun_guard as guard
import telegram_proxy
import web_panel


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
CONFIG_FILE = Path(os.environ.get("ALIYUN_GUARD_CONFIG", APP_DIR / "config.json"))
CONTROL_FILE = APP_DIR / "control.sh"
UPDATE_BASE_URL = os.environ.get(
    "ALIYUN_GUARD_UPDATE_BASE",
    "https://raw.githubusercontent.com/Felix666-ship-It/aliyun-guard/main",
).rstrip("/")
APP_VERSION = "1.5.0"
LOCAL_RELEASE_ID = "__AG_RELEASE_ID__"
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


def prompt_schedule_time(text, default):
    while True:
        value = prompt(text, default, required=True)
        try:
            return guard.normalize_schedule_time(value, text)
        except guard.GuardError as exc:
            print(exc)


def default_config():
    return json.loads(json.dumps(guard.DEFAULT_CONFIG, ensure_ascii=False))


def load_config(allow_missing=False):
    if not CONFIG_FILE.exists():
        if allow_missing:
            return default_config()
        raise guard.GuardError("配置文件不存在: {}".format(CONFIG_FILE))
    return guard.load_config()


def save_config(config):
    telegram = config.get("telegram", {})
    if isinstance(telegram, dict):
        telegram["node_urls"] = guard.telegram_node_urls(telegram)
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


TELEGRAM_CONNECTION_LABELS = {
    "direct": "直连",
    "socks5": "SOCKS5 代理",
    "http": "HTTP/HTTPS 代理",
    "node": "节点链接（VLESS / VMess / Shadowsocks）",
    "api_proxy": "Telegram API 反向代理",
}


def _safe_proxy_url(value):
    try:
        parsed = urllib.parse.urlsplit(str(value or ""))
        host = parsed.hostname or ""
        if ":" in host:
            host = "[{}]".format(host)
        address = host
        if parsed.port:
            address = "{}:{}".format(address, parsed.port)
        if parsed.username:
            address = "{}:***@{}".format(parsed.username, address)
        return "{}://{}".format(parsed.scheme, address)
    except ValueError:
        return "地址无效"


def _safe_api_base_url(value):
    try:
        parsed = urllib.parse.urlsplit(str(value or ""))
        host = parsed.hostname or ""
        if ":" in host:
            host = "[{}]".format(host)
        address = host
        if parsed.port:
            address = "{}:{}".format(address, parsed.port)
        if parsed.username:
            credentials = parsed.username
            if parsed.password is not None:
                credentials += ":***"
            address = "{}@{}".format(credentials, address)
        return urllib.parse.urlunsplit(
            (parsed.scheme, address, parsed.path.rstrip("/"), "", "")
        )
    except ValueError:
        return "地址无效"


def describe_telegram_connection(telegram):
    mode = str(telegram.get("connection_mode", "direct") or "direct")
    label = TELEGRAM_CONNECTION_LABELS.get(mode, "未知")
    if mode in ("socks5", "http"):
        return "{}: {}".format(label, _safe_proxy_url(telegram.get("proxy_url")))
    if mode == "node":
        try:
            detail = telegram_proxy.describe_node_link(telegram.get("node_url", ""))
        except telegram_proxy.ProxyError:
            detail = "节点链接无效"
        return "{}: {}".format(label, detail)
    if mode == "api_proxy":
        return "{}: {}".format(label, _safe_api_base_url(telegram.get("api_base_url", "")))
    return label


def telegram_connection_status_lines(telegram, prefix="当前"):
    mode = str(telegram.get("connection_mode", "direct") or "direct")
    label = TELEGRAM_CONNECTION_LABELS.get(mode, "未知")
    lines = ["{}方式: {}".format(prefix, label)]
    if mode in ("socks5", "http"):
        lines.append("{}代理: {}".format(prefix, _safe_proxy_url(telegram.get("proxy_url"))))
    elif mode == "node":
        try:
            node = telegram_proxy.describe_node_link(telegram.get("node_url", ""))
        except telegram_proxy.ProxyError:
            node = "节点链接无效"
        lines.append("{}节点: {}".format(prefix, node))
    elif mode == "api_proxy":
        lines.append(
            "{}反代: {}".format(prefix, _safe_api_base_url(telegram.get("api_base_url", "")))
        )
    return lines


def _saved_node_description(node_url):
    try:
        return telegram_proxy.describe_node_link(node_url)
    except telegram_proxy.ProxyError:
        return "无效节点链接"


def _sync_saved_nodes(telegram):
    nodes = guard.telegram_node_urls(telegram)
    telegram["node_urls"] = nodes
    return nodes


def add_telegram_node(telegram):
    while True:
        node_url = prompt_secret("节点链接（vless://、vmess:// 或 ss://）")
        try:
            description = telegram_proxy.describe_node_link(node_url)
        except telegram_proxy.ProxyError as exc:
            print("节点链接无效: {}".format(exc))
            if yes_no("重新输入节点链接", default=True):
                continue
            return "cancelled"
        nodes = _sync_saved_nodes(telegram)
        is_new = node_url not in nodes
        if is_new:
            nodes.append(node_url)
        telegram["node_urls"] = nodes
        telegram["node_url"] = node_url
        telegram["connection_mode"] = "node"
        if is_new:
            print("已添加待检测节点: {}".format(description))
            return "added"
        else:
            print("节点已存在，已切换到: {}".format(description))
            return "selected"


def delete_telegram_node(telegram, nodes):
    title("删除 Telegram 节点")
    for index, node_url in enumerate(nodes, 1):
        print(" {:>2}) {}".format(index, _saved_node_description(node_url)))
    selection = prompt_int("要删除的节点序号", 1, 1, len(nodes))
    node_url = nodes[selection - 1]
    description = _saved_node_description(node_url)
    if not yes_no("确认删除 {}".format(description), default=False):
        print("已取消删除。")
        return False
    remaining = [value for value in nodes if value != node_url]
    telegram["node_urls"] = remaining
    if str(telegram.get("node_url", "") or "").strip() == node_url:
        telegram["node_url"] = remaining[0] if remaining else ""
        if not remaining and telegram.get("connection_mode") == "node":
            telegram["connection_mode"] = "direct"
    print("已删除节点: {}".format(description))
    if not remaining:
        print("已保存节点为 0 个，连接方式已切换为直连。")
    return True


def configure_telegram_nodes(telegram):
    nodes = _sync_saved_nodes(telegram)
    if not nodes:
        title("Telegram 节点")
        print("尚未保存节点，将添加第一个节点。")
        return add_telegram_node(telegram)
    while True:
        nodes = _sync_saved_nodes(telegram)
        title("Telegram 节点（已保存 {} 个）".format(len(nodes)))
        active_node = str(telegram.get("node_url", "") or "").strip()
        for index, node_url in enumerate(nodes, 1):
            marker = ""
            if node_url == active_node:
                marker = (
                    "（当前使用）"
                    if telegram.get("connection_mode") == "node"
                    else "（上次使用）"
                )
            print(" {:>2}) {} {}".format(index, _saved_node_description(node_url), marker))
        add_choice = len(nodes) + 1
        delete_choice = len(nodes) + 2
        back_choice = len(nodes) + 3
        print(" {:>2}) 添加新节点".format(add_choice))
        print(" {:>2}) 删除已保存节点".format(delete_choice))
        print(" {:>2}) 返回连接方式菜单".format(back_choice))
        default_choice = nodes.index(active_node) + 1 if active_node in nodes else 1
        choice = prompt_int("请选择节点或操作", default_choice, 1, back_choice)
        if choice <= len(nodes):
            telegram["node_url"] = nodes[choice - 1]
            telegram["connection_mode"] = "node"
            print("已选择: {}".format(_saved_node_description(telegram["node_url"])))
            return "selected"
        if choice == add_choice:
            return add_telegram_node(telegram)
        if choice == delete_choice:
            delete_telegram_node(telegram, nodes)
            if not _sync_saved_nodes(telegram):
                return "changed"
            continue
        return "cancelled"


def _telegram_connection_signature(telegram):
    connection = tuple(
        str(telegram.get(field, "") or "").strip()
        for field in ("connection_mode", "proxy_url", "node_url", "api_base_url")
    )
    return connection + (tuple(guard.telegram_node_urls(telegram)),)


def run_telegram_connection_test(telegram):
    print("本次测试方式: {}".format(describe_telegram_connection(telegram)))
    print("正在测试当前连接到 Telegram Bot API 的往返延迟（3 次）并发送消息...")
    details = {}
    username = guard.test_telegram(
        telegram,
        latency_attempts=3,
        result_details=details,
    )
    print(
        "Telegram 往返延迟: {:.0f} ms（{} 次平均）".format(
            details["latency_ms"],
            details["latency_attempts"],
        )
    )
    return username


def test_telegram_connection(telegram, force_ipv4=True):
    try:
        guard.validate_telegram_config(telegram)
    except Exception as exc:
        print("连接配置无效: {}".format(guard.compact_error(exc)))
        return False
    if telegram.get("connection_mode") == "node" and not telegram_proxy.find_sing_box():
        if not yes_no(
            "未检测到 sing-box，是否从官方 GitHub 下载并校验安装",
            default=True,
        ):
            print("节点模式需要 sing-box，检测已取消。")
            return False
        try:
            path = telegram_proxy.install_sing_box(progress=print)
            print("sing-box 已安装: {}".format(path))
        except Exception as exc:
            print("sing-box 安装失败: {}".format(guard.compact_error(exc)))
            return False
    if force_ipv4:
        guard.enable_ipv4_only()
    try:
        username = run_telegram_connection_test(telegram)
        print("Telegram 检测成功，Bot: @{}".format(username))
        return True
    except Exception as exc:
        print(
            "Telegram 检测失败: {}".format(
                guard.compact_error(exc, secrets=guard.telegram_secrets(telegram))
            )
        )
        return False


def confirm_connection_change(candidate, active):
    if active is None or _telegram_connection_signature(candidate) == _telegram_connection_signature(active):
        return True
    current_mode = str(active.get("connection_mode", "direct") or "direct")
    pending_mode = str(candidate.get("connection_mode", "direct") or "direct")
    current_label = TELEGRAM_CONNECTION_LABELS.get(current_mode, "未知")
    pending_label = TELEGRAM_CONNECTION_LABELS.get(pending_mode, "未知")
    if current_mode == pending_mode:
        question = "将更新“{}”连接配置，并使用待保存方式连接 Telegram Bot API 进行测试".format(
            pending_label
        )
    else:
        question = "将从“{}”切换为“{}”，并使用待保存方式连接 Telegram Bot API 进行测试".format(
            current_label,
            pending_label,
        )
    if current_mode == "node" and pending_mode != "node":
        question += "（原节点链接仍会保留）"
    return yes_no(question + "，确认继续", default=False)


def _set_telegram_identity(candidate):
    token = prompt_secret(
        "Telegram Bot Token", keep_existing=bool(candidate.get("bot_token"))
    )
    if token:
        candidate["bot_token"] = token
    candidate["chat_id"] = prompt(
        "Telegram Chat ID", candidate.get("chat_id"), required=True
    )


def configure_telegram_connection(candidate, force_ipv4=True, initial=False, active=None):
    while True:
        title("Telegram 连接方式")
        status_source = active if active is not None else candidate
        for line in telegram_connection_status_lines(status_source):
            print(line)
        if active is not None and _telegram_connection_signature(candidate) != _telegram_connection_signature(active):
            for line in telegram_connection_status_lines(candidate, prefix="待保存"):
                print(line)
        print("")
        print(" 1) 直连")
        print(" 2) SOCKS5 代理")
        print(" 3) HTTP/HTTPS 代理")
        print(
            " 4) 节点链接（VLESS / VMess / Shadowsocks）  [已保存 {} 个]".format(
                len(guard.telegram_node_urls(candidate))
            )
        )
        print(" 5) Telegram API 反向代理")
        print(" 6) 查看当前选择")
        print(" 7) 取消并返回")
        print(" 8) 单独检测当前选择（不保存）")
        print(" 9) 测试并保存")
        choice = prompt_int("请选择", 9, 1, 9)
        if choice == 1:
            previous = json.loads(json.dumps(candidate, ensure_ascii=False))
            candidate["connection_mode"] = "direct"
            print("正在检测 Telegram 直连，检测通过后将直接切换并保存...")
            if test_telegram_connection(candidate, force_ipv4=force_ipv4):
                candidate["node_urls"] = guard.telegram_node_urls(candidate)
                print("Telegram 直连检测通过，已直接切换并保存。")
                return candidate, True
            candidate.clear()
            candidate.update(previous)
            print("Telegram 直连检测失败，未切换，原连接配置保持不变。")
        elif choice == 2:
            candidate["connection_mode"] = "socks5"
            candidate["proxy_url"] = prompt(
                "SOCKS5 地址（推荐 socks5h://）",
                candidate.get("proxy_url") or "socks5h://127.0.0.1:1080",
                required=True,
            )
        elif choice == 3:
            candidate["connection_mode"] = "http"
            candidate["proxy_url"] = prompt(
                "HTTP/HTTPS 代理地址",
                candidate.get("proxy_url") or "http://127.0.0.1:8080",
                required=True,
            )
        elif choice == 4:
            previous = json.loads(json.dumps(candidate, ensure_ascii=False))
            node_action = configure_telegram_nodes(candidate)
            if node_action == "added":
                print("正在检测新节点，检测通过后将自动保存...")
                if test_telegram_connection(candidate, force_ipv4=force_ipv4):
                    saved_nodes = guard.telegram_node_urls(candidate)
                    candidate.clear()
                    candidate.update(previous)
                    candidate["node_urls"] = saved_nodes
                    print("新节点延迟检测通过，已保存到节点列表，当前连接方式保持不变。")
                    return candidate, True
                candidate.clear()
                candidate.update(previous)
                telegram_proxy.stop_node_proxy()
                print("新节点检测失败，未保存，原连接配置保持不变。")
        elif choice == 5:
            candidate["connection_mode"] = "api_proxy"
            candidate["api_base_url"] = prompt(
                "Telegram API 反向代理基础地址",
                candidate.get("api_base_url") or "https://api.telegram.org",
                required=True,
            ).rstrip("/")
        elif choice == 6:
            print("当前选择: {}".format(describe_telegram_connection(candidate)))
        elif choice == 7:
            if initial:
                print("首次配置必须保存一种 Telegram 连接方式。")
                continue
            return None
        elif choice == 8:
            print("开始单独检测，本次检测不会保存配置...")
            if test_telegram_connection(candidate, force_ipv4=force_ipv4):
                print("单独检测完成，本次配置未保存。")
            prompt("按回车返回连接方式菜单")
        elif choice == 9:
            if not confirm_connection_change(candidate, active):
                print("已取消切换，当前连接方式和节点保持不变。")
                continue
            if test_telegram_connection(candidate, force_ipv4=force_ipv4):
                return candidate, True
            if yes_no("重新输入 Token 或 Chat ID", default=False):
                _set_telegram_identity(candidate)
            if yes_no("测试失败，仍保存当前 Telegram 配置", default=False):
                return candidate, False


def configure_telegram(config, initial=False):
    title("Telegram 通知配置")
    current = config.setdefault("telegram", {})
    candidate = json.loads(json.dumps(current, ensure_ascii=False))
    print("Token、代理密码和节点链接只保存在本机 root 可读的配置文件中。")
    _set_telegram_identity(candidate)
    candidate["timeout_seconds"] = prompt_int(
        "Telegram 请求超时（秒）", candidate.get("timeout_seconds", 12), 3, 60
    )
    candidate["retries"] = prompt_int(
        "Telegram 临时失败重试次数", candidate.get("retries", 3), 1, 5
    )
    result = configure_telegram_connection(
        candidate,
        force_ipv4=bool(config.get("force_ipv4", True)),
        initial=initial,
    )
    if result is None:
        print("已取消 Telegram 配置修改。")
        return None
    selected, test_ok = result
    current.clear()
    current.update(selected)
    return test_ok


def test_current_telegram(config):
    title("测试 Telegram 通知")
    telegram = config.get("telegram", {})
    print("当前连接: {}".format(describe_telegram_connection(telegram)))
    if config.get("force_ipv4", True):
        guard.enable_ipv4_only()
    try:
        username = run_telegram_connection_test(telegram)
        print("Telegram 测试成功，Bot: @{}".format(username))
        return True
    except Exception as exc:
        print(
            "Telegram 测试失败: {}".format(
                guard.compact_error(exc, secrets=guard.telegram_secrets(telegram))
            )
        )
        return False


def configure_telegram_connection_settings(config):
    current = config.setdefault("telegram", {})
    candidate = json.loads(json.dumps(current, ensure_ascii=False))
    result = configure_telegram_connection(
        candidate,
        force_ipv4=bool(config.get("force_ipv4", True)),
        initial=False,
        active=current,
    )
    if result is None:
        print("已取消 Telegram 连接方式修改。")
        return None
    selected, test_ok = result
    current.clear()
    current.update(selected)
    return test_ok


def schedule_text(user):
    schedule = guard.get_schedule_config(user)
    if not schedule["enabled"]:
        return "关闭"
    suffix = " (+1日)" if schedule["start_time"] > schedule["stop_time"] else ""
    return "{}-{}{}".format(
        schedule["start_time"], schedule["stop_time"], suffix
    )


def print_schedule_details(user):
    schedule = guard.get_schedule_config(user)
    now = dt.datetime.now().astimezone()
    print(
        "服务器时间: {} ({})".format(
            now.strftime("%Y-%m-%d %H:%M:%S"), now.strftime("%Z%z")
        )
    )
    if not schedule["enabled"]:
        print("当前计划: 已关闭")
        return
    target = guard.schedule_target(user, now)
    print("每日开机: {}".format(schedule["start_time"]))
    print("每日关机: {}".format(schedule["stop_time"]))
    if schedule["start_time"] > schedule["stop_time"]:
        print("运行时段: 跨午夜，关机时间属于次日")
    print("当前时段: {}".format("计划运行" if target == "running" else "计划关机"))
    next_event = guard.next_schedule_event(user, now)
    if next_event:
        event_at, action = next_event
        print(
            "下一动作: {} {}".format(
                event_at.strftime("%Y-%m-%d %H:%M"),
                "开机" if action == "start" else "关机",
            )
        )


def collect_schedule(existing_user=None, ask_enabled=True):
    existing_user = existing_user or {}
    current = guard.get_schedule_config(existing_user)
    title("每日定时开关机")
    print("计划按服务器本地时间执行；流量达到阈值时不会执行计划开机。")
    enabled = True
    if ask_enabled:
        enabled = yes_no("启用该实例的每日定时开关机", current["enabled"])
    if not enabled:
        return {
            "enabled": False,
            "start_time": current["start_time"],
            "stop_time": current["stop_time"],
        }
    while True:
        start_time = prompt_schedule_time("每日开机时间 (HH:MM)", current["start_time"])
        stop_time = prompt_schedule_time("每日关机时间 (HH:MM)", current["stop_time"])
        if start_time == stop_time:
            print("开机时间和关机时间不能相同。")
            continue
        schedule = {
            "enabled": True,
            "start_time": start_time,
            "stop_time": stop_time,
        }
        preview = dict(existing_user)
        preview["schedule"] = schedule
        print_schedule_details(preview)
        return schedule


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
    user["instance_log_enabled"] = yes_no(
        "为该实例启用独立日志",
        bool(existing.get("instance_log_enabled", False)),
    )
    user["schedule"] = collect_schedule(existing)
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
    print("序号  状态    名称                  Region                实例 ID                 定时计划               账单       AccessKey")
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
            "{:<5} {:<7} {:<21} {:<21} {:<23} {:<22} {:<10} {}".format(
                index,
                status,
                str(user.get("name", ""))[:20],
                str(user.get("region", ""))[:20],
                str(user.get("instance_id", ""))[:22],
                schedule_text(user),
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


def edit_user_schedule(config):
    index = choose_user(config, "设置定时开关机")
    if index is None:
        return
    user = config["users"][index]
    title("{} - 定时开关机".format(user.get("name") or user.get("instance_id")))
    print_schedule_details(user)
    print("\n 1) 启用或修改计划")
    print(" 2) 关闭计划")
    print(" 3) 返回")
    choice = prompt_int("请输入序号", 1, 1, 3)
    if choice == 3:
        return
    if choice == 2:
        if not guard.get_schedule_config(user)["enabled"]:
            print("该实例的定时开关机已经关闭。")
            return
        if not yes_no("确认关闭该实例的定时开关机", False):
            print("已取消。")
            return
        current = guard.get_schedule_config(user)
        user["schedule"] = {
            "enabled": False,
            "start_time": current["start_time"],
            "stop_time": current["stop_time"],
        }
        save_config(config)
        print("定时开关机已关闭。")
        return
    user["schedule"] = collect_schedule(user, ask_enabled=False)
    if yes_no("保存以上定时计划", True):
        save_config(config)
        print("定时计划已保存，后台会在 1 分钟内读取新设置。")
    else:
        print("未保存修改。")


def _set_web_password(web):
    while True:
        password = prompt_secret("网页登录密码")
        confirm_password = prompt_secret("再次输入网页登录密码")
        if password != confirm_password:
            print("两次输入的密码不一致。")
            continue
        try:
            web["password_hash"] = web_panel.hash_password(password)
            return
        except ValueError as exc:
            print(exc)


def print_web_panel_access(web):
    print("网页监听: http://{}:{}".format(web["host"], web["port"]))
    if web["host"] == "127.0.0.1":
        print("SSH 隧道: ssh -L {0}:127.0.0.1:{0} root@服务器IP".format(web["port"]))
    print("浏览器访问: {}".format(web_panel.browser_access_url(web)))
    print("HTTPS 反向代理: 支持（会话 Cookie 自动适配）")


def configure_web_panel(config, initial=False, restart=True):
    current = web_panel.get_web_config(config)
    title("网页控制面板")
    if not initial:
        print("当前状态: {}".format("已启用" if current["enabled"] else "已关闭"))
        if current["enabled"]:
            print_web_panel_access(current)
    enabled = yes_no("启用网页控制面板", current["enabled"] if not initial else True)
    candidate = dict(current)
    candidate["enabled"] = enabled
    if not enabled:
        config["web_panel"] = candidate
        save_config(config)
        if restart:
            run_control("restart")
        print("网页控制面板已关闭。")
        return False

    if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
        candidate["host"] = "0.0.0.0"
        candidate["port"] = int(
            os.environ.get("ALIYUN_GUARD_CONTAINER_WEB_PORT", "8765")
        )
        print("Docker 内部网页固定监听 0.0.0.0:{}。".format(candidate["port"]))
        print("公网 IP 和宿主机端口由 .env 与 Compose 映射控制。")
        print("公网 HTTP 会明文传输登录信息，建议限制来源并配置 HTTPS。")
    else:
        print("\n监听方式：")
        print(" 1) 仅本机（推荐，通过 SSH 隧道或 HTTPS 反向代理访问）")
        print(" 2) 所有 IPv4 网卡（必须配合防火墙，HTTP 会明文传输）")
        default_host = 2 if current["host"] == "0.0.0.0" else 1
        host_choice = prompt_int("监听方式序号", default_host, 1, 2)
        if host_choice == 2 and not yes_no("确认允许其他机器直接连接该端口", False):
            print("已改为仅本机监听。")
            host_choice = 1
        candidate["host"] = "0.0.0.0" if host_choice == 2 else "127.0.0.1"
        candidate["port"] = prompt_int("网页端口", current["port"], 1024, 65535)
    candidate["username"] = prompt(
        "网页登录用户名", current["username"] or "admin", required=True
    )
    candidate["cookie_secure"] = False
    if not current.get("password_hash") or yes_no("修改网页登录密码", False):
        _set_web_password(candidate)
    config["web_panel"] = candidate
    try:
        save_config(config)
    except Exception:
        config["web_panel"] = current
        raise
    if restart:
        if run_control("restart") != 0:
            print("配置已保存，但后台服务重启失败。")
    print("网页控制面板配置已保存。")
    print_web_panel_access(candidate)
    return True


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


def show_logs(config, lines=80):
    users = config.get("users", [])
    title("选择日志来源")
    print(" 1) 系统总日志")
    for index, user in enumerate(users, 2):
        status = "已启用" if guard.instance_log_enabled(user) else "已关闭"
        print(
            " {:>2}) {} ({})  [独立日志{}]".format(
                index,
                user.get("name") or user.get("instance_id"),
                user.get("instance_id"),
                status,
            )
        )
    choice = prompt_int("日志来源序号", 1, 1, len(users) + 1)
    if choice == 1:
        path = guard.LOG_FILE
        label = "系统总日志"
    else:
        user = users[choice - 2]
        path = guard.instance_log_path(user)
        label = "{} 独立日志".format(user.get("name") or user.get("instance_id"))
        if not guard.instance_log_enabled(user):
            print("该实例独立日志当前已关闭，仅显示已有历史记录。")
    print("\n{}（最近 {} 行）: {}".format(label, lines, path))
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


def local_release_id():
    try:
        return parse_release_id(LOCAL_RELEASE_ID)
    except Exception:
        pass
    for path in (APP_DIR / "version.json", APP_DIR.parent / "version.json"):
        try:
            return parse_version_manifest(path.read_text(encoding="utf-8"))[
                "release_id"
            ]
        except (OSError, ValueError, guard.GuardError):
            continue
    raise guard.GuardError("本地版本构建标识无效")


def check_for_github_update():
    """Return remote release details, or None when the startup check is unavailable."""
    try:
        current_release_id = local_release_id()
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
    remote["available"] = remote["release_id"] != current_release_id
    return remote


def update_from_github(confirm_update=True, release_info=None):
    if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
        title("更新 GitHub 版本")
        print("Docker 部署请在宿主机执行：")
        print("git pull && docker compose up -d --build")
        return False
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
    configure_web_panel(config, initial=True, restart=False)
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
            print(yellow_text("发现新版本: v{}（请选择 16 更新）".format(update_info["version"])))
        print(" 1) 查看运行状态")
        print(" 2) 立即执行一轮检测")
        print(" 3) 演练一轮（不执行开关机）")
        print(" 4) 测试 Telegram 通知")
        print(" 5) Telegram 连接方式")
        print(" 6) 查看监控实例")
        print(" 7) 添加监控实例")
        print(" 8) 编辑监控实例")
        print(" 9) 定时开关机设置")
        print("10) 网页控制面板")
        print("11) 暂停/恢复监控实例")
        print("12) 删除监控实例")
        print("13) 修改全局设置")
        print("14) 查看最近日志")
        print("15) 重启后台服务")
        update_hint = ""
        if update_info and update_info.get("available"):
            update_hint = "  " + yellow_text("[有新版本 v{}]".format(update_info["version"]))
        print("16) 更新 GitHub 版本{}".format(update_hint))
        print("17) 退出")
        choice = prompt_int("请输入序号", 1, 1, 17)
        try:
            if choice == 1:
                show_status(config)
            elif choice == 2:
                run_once(False)
            elif choice == 3:
                run_once(True)
            elif choice == 4:
                test_current_telegram(config)
            elif choice == 5:
                if configure_telegram_connection_settings(config) is not None:
                    save_config(config)
            elif choice == 6:
                list_users(config)
            elif choice == 7:
                add_user(config)
            elif choice == 8:
                edit_user(config)
            elif choice == 9:
                edit_user_schedule(config)
            elif choice == 10:
                configure_web_panel(config)
            elif choice == 11:
                toggle_user(config)
            elif choice == 12:
                delete_user(config)
            elif choice == 13:
                edit_settings(config)
            elif choice == 14:
                show_logs(config)
            elif choice == 15:
                run_control("restart")
            elif choice == 16:
                if update_from_github(release_info=update_info) is True:
                    return 0
            elif choice == 17:
                return 0
        except KeyboardInterrupt:
            print("\n操作已取消。")
        if choice != 17:
            prompt("按回车返回菜单")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="阿里云保活交互式管理器")
    subparsers = parser.add_subparsers(dest="command")
    setup = subparsers.add_parser("setup", help="执行首次设置")
    setup.add_argument("--force", action="store_true", help="忽略已有配置并重新设置")
    subparsers.add_parser("menu", help="打开管理面板")
    subparsers.add_parser("status", help="显示状态")
    subparsers.add_parser("add", help="添加实例")
    update = subparsers.add_parser("update", help="从 GitHub 更新程序")
    update.add_argument("--yes", action="store_true", help="无需交互确认")
    subparsers.add_parser("version", help="显示当前版本")
    subparsers.add_parser("web", help="显示网页控制面板状态")
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
            result = update_from_github(confirm_update=not args.yes)
            return 1 if result is False else 0
        if args.command == "version":
            print("Aliyun Guard v{}".format(APP_VERSION))
            return 0
        if args.command == "web":
            return web_panel.show_status()
        return menu()
    except guard.GuardError as exc:
        print("错误: {}".format(exc), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\n已退出。")
        return 130


if __name__ == "__main__":
    sys.exit(main())
