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
APP_VERSION = "1.1.1"
LOCAL_RELEASE_ID = "__AG_RELEASE_ID__"
UPDATE_MANIFEST_NAME = "version.json"
UPDATE_CHECK_TIMEOUT_SECONDS = 5

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
    if target_version:
        status = ""
        if not release_info.get("available"):
            status = "（当前已是最新版）"
        print("最新版本: v{}{}".format(target_version, status))
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
            update_hint = "  [有新版本 v{}]".format(update_info["version"])
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
