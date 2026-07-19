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
PRESERVE_DIR=""

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

TTY_AVAILABLE=no
if [ "$INSTALL_ACTION" = update ]; then
    # Web/systemd updates are deliberately non-interactive and need no controlling terminal.
    exec 3</dev/null
elif { : </dev/tty; } 2>/dev/null; then
    exec 3</dev/tty
    TTY_AVAILABLE=yes
else
    die "这是交互式安装器，但当前没有可用终端。请在 SSH/VNC 终端中运行。"
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

cleanup_preserved_data() {
    if [ -n "$PRESERVE_DIR" ] && [ -d "$PRESERVE_DIR" ]; then
        rm -rf "$PRESERVE_DIR"
    fi
    PRESERVE_DIR=""
}

trap cleanup_preserved_data EXIT
trap 'exit 130' HUP INT TERM

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

preserve_local_data() {
    if [ ! -f "$APP_DIR/config.json" ]; then
        return
    fi
    PRESERVE_DIR=$(mktemp -d)
    cp "$APP_DIR/config.json" "$PRESERVE_DIR/config.json"
    [ ! -f "$APP_DIR/state.json" ] || cp "$APP_DIR/state.json" "$PRESERVE_DIR/state.json"
    if [ -f "$APP_DIR/bin/sing-box" ]; then
        mkdir -p "$PRESERVE_DIR/bin"
        cp "$APP_DIR/bin/sing-box" "$PRESERVE_DIR/bin/sing-box"
    fi
    chmod 600 "$PRESERVE_DIR/config.json"
    say "${GREEN}已保护现有配置（包括 Telegram 连接方式、节点和网页面板设置）。${RESET}"
}

restore_local_data() {
    if [ -z "$PRESERVE_DIR" ] || [ ! -f "$PRESERVE_DIR/config.json" ]; then
        return
    fi
    cp "$PRESERVE_DIR/config.json" "$APP_DIR/config.json"
    chmod 600 "$APP_DIR/config.json"
    if [ -f "$PRESERVE_DIR/state.json" ]; then
        cp "$PRESERVE_DIR/state.json" "$APP_DIR/state.json"
        chmod 600 "$APP_DIR/state.json"
    fi
    if [ -f "$PRESERVE_DIR/bin/sing-box" ] && [ ! -x "$APP_DIR/bin/sing-box" ]; then
        mkdir -p "$APP_DIR/bin"
        cp "$PRESERVE_DIR/bin/sing-box" "$APP_DIR/bin/sing-box"
        chmod 700 "$APP_DIR/bin/sing-box"
    fi
    say "${GREEN}已恢复现有配置，Telegram 代理、节点和网页面板设置保持不变。${RESET}"
    cleanup_preserved_data
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
        'aliyun-python-sdk-ecs>=4.24,<5' \
        'requests[socks]>=2.31,<3' \
        'cryptography>=42,<46' \
        'boto3>=1.34,<2'
}

stop_old_backend() {
    if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/$SERVICE_NAME" ]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    fi
    if [ -x "$VENV_DIR/bin/python" ] && [ -f "$APP_DIR/web_panel.py" ]; then
        "$VENV_DIR/bin/python" "$APP_DIR/web_panel.py" stop >/dev/null 2>&1 || true
    fi
}

write_payload() {
    say "${YELLOW}[3/6] 写入程序文件...${RESET}"
    mkdir -p "$APP_DIR/logs"
    cat > "$APP_DIR/backup_manager.py" <<'__AG_BACKUP_PY_EOF__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Authenticated backups and local program rollback snapshots."""

import base64
import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import tarfile
import tempfile

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    CRYPTOGRAPHY_IMPORT_ERROR = None
except ImportError as exc:
    AESGCM = None
    CRYPTOGRAPHY_IMPORT_ERROR = exc


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
BACKUP_DIR = Path(os.environ.get("ALIYUN_GUARD_BACKUP_DIR", APP_DIR / "backups"))
BACKUP_FORMAT = "aliyun-guard-backup-v1"
SNAPSHOT_FORMAT = "aliyun-guard-program-v1"
PBKDF2_ITERATIONS = 240000
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_BACKUP_BYTES = 64 * 1024 * 1024
MAX_BACKUP_FILE_BYTES = 88 * 1024 * 1024

DATA_FILES = (
    "config.json",
    "state.json",
    "telegram-control-state.json",
    "s3-backup-state.json",
    "service_backend",
)
PROGRAM_FILES = (
    "aliyun_guard.py",
    "s3_backup.py",
    "manager.py",
    "telegram_proxy.py",
    "telegram_control.py",
    "web_actions.py",
    "web_panel.py",
    "web_panel.html",
    "control.sh",
    "uninstall.sh",
    "version.json",
)


class BackupError(RuntimeError):
    pass


def _now_text():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def _stamp():
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def _b64encode(value):
    return base64.b64encode(value).decode("ascii")


def _b64decode(value, label):
    try:
        return base64.b64decode(str(value).encode("ascii"), validate=True)
    except Exception as exc:
        raise BackupError("备份中的 {} 格式无效".format(label)) from exc


def _derive_keys(passphrase, salt, iterations):
    phrase = str(passphrase or "")
    if len(phrase) < 8:
        raise BackupError("备份密码至少需要 8 个字符")
    return hashlib.pbkdf2_hmac(
        "sha256", phrase.encode("utf-8"), salt, int(iterations), dklen=32
    )


def _require_cryptography():
    if CRYPTOGRAPHY_IMPORT_ERROR is not None:
        raise BackupError(
            "缺少备份加密依赖 cryptography: {}".format(CRYPTOGRAPHY_IMPORT_ERROR)
        )


def encrypt_payload(payload, passphrase, iterations=PBKDF2_ITERATIONS):
    _require_cryptography()
    plaintext = json.dumps(
        payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    if len(plaintext) > MAX_BACKUP_BYTES:
        raise BackupError("备份内容超过 {} MiB 限制".format(MAX_BACKUP_BYTES // 1048576))
    salt = secrets.token_bytes(16)
    nonce = secrets.token_bytes(12)
    encryption_key = _derive_keys(passphrase, salt, iterations)
    associated_data = (
        BACKUP_FORMAT.encode("ascii") + b"\0" + str(int(iterations)).encode("ascii")
    )
    ciphertext = AESGCM(encryption_key).encrypt(nonce, plaintext, associated_data)
    return {
        "format": BACKUP_FORMAT,
        "created_at": _now_text(),
        "kdf": "pbkdf2-hmac-sha256",
        "cipher": "aes-256-gcm",
        "iterations": int(iterations),
        "salt": _b64encode(salt),
        "nonce": _b64encode(nonce),
        "ciphertext": _b64encode(ciphertext),
    }


def decrypt_payload(envelope, passphrase):
    _require_cryptography()
    if not isinstance(envelope, dict) or envelope.get("format") != BACKUP_FORMAT:
        raise BackupError("不是受支持的 Aliyun Guard 备份")
    try:
        iterations = int(envelope.get("iterations"))
    except (TypeError, ValueError) as exc:
        raise BackupError("备份 KDF 参数无效") from exc
    if iterations < 100000 or iterations > 2000000:
        raise BackupError("备份 KDF 参数超出安全范围")
    salt = _b64decode(envelope.get("salt", ""), "salt")
    nonce = _b64decode(envelope.get("nonce", ""), "nonce")
    ciphertext = _b64decode(envelope.get("ciphertext", ""), "ciphertext")
    if len(ciphertext) > MAX_BACKUP_BYTES + 16:
        raise BackupError("备份内容过大")
    if envelope.get("cipher") != "aes-256-gcm":
        raise BackupError("备份加密算法不受支持")
    encryption_key = _derive_keys(passphrase, salt, iterations)
    associated_data = BACKUP_FORMAT.encode("ascii") + b"\0" + str(iterations).encode("ascii")
    try:
        plaintext = AESGCM(encryption_key).decrypt(
            nonce, ciphertext, associated_data
        )
    except Exception as exc:
        raise BackupError("备份密码错误或文件已损坏") from exc
    try:
        payload = json.loads(plaintext.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise BackupError("备份解密后内容无效") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("files"), dict):
        raise BackupError("备份内容结构无效")
    return payload


def _safe_relative_path(value):
    text = str(value or "").replace("\\", "/").strip("/")
    path = Path(text)
    if (
        not text
        or path.is_absolute()
        or ".." in path.parts
        or text.startswith(".")
    ):
        raise BackupError("备份包含不安全路径")
    allowed = text in DATA_FILES or text.startswith("logs/")
    if not allowed:
        raise BackupError("备份包含不允许恢复的文件: {}".format(text))
    return text


def _read_file(path):
    size = path.stat().st_size
    if size > MAX_FILE_BYTES:
        raise BackupError("文件过大，未加入备份: {}".format(path.name))
    return path.read_bytes()


def collect_data_files(app_dir=APP_DIR, include_state=True, include_logs=True):
    root = Path(app_dir)
    files = {}
    selected = ["config.json", "service_backend"]
    if include_state:
        selected.extend(("state.json", "telegram-control-state.json"))
    for name in selected:
        path = root / name
        if path.is_file():
            data = _read_file(path)
            files[name] = {
                "content": _b64encode(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "mode": int(path.stat().st_mode & 0o777),
            }
    if include_logs:
        log_dir = root / "logs"
        if log_dir.is_dir():
            for path in sorted(log_dir.rglob("*")):
                if not path.is_file():
                    continue
                relative = "logs/" + path.relative_to(log_dir).as_posix()
                data = _read_file(path)
                files[relative] = {
                    "content": _b64encode(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "mode": int(path.stat().st_mode & 0o777),
                }
    return files


def create_backup(
    passphrase,
    app_dir=APP_DIR,
    output_path=None,
    include_state=True,
    include_logs=True,
):
    root = Path(app_dir)
    files = collect_data_files(root, include_state, include_logs)
    if "config.json" not in files:
        raise BackupError("未找到 config.json，无法创建完整备份")
    payload = {
        "format": BACKUP_FORMAT,
        "created_at": _now_text(),
        "source": "Aliyun Guard",
        "files": files,
    }
    envelope = encrypt_payload(payload, passphrase)
    destination = Path(output_path) if output_path else root / "backups" / (
        "aliyun-guard-{}.agbackup".format(_stamp())
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(envelope, ensure_ascii=True, indent=2) + "\n", encoding="utf-8"
    )
    os.chmod(str(destination), 0o600)
    return destination


def load_backup(path, passphrase):
    backup_path = Path(path)
    try:
        envelope = json.loads(backup_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise BackupError("无法读取备份: {}".format(exc)) from exc
    return decrypt_payload(envelope, passphrase)


def _config_summary(content):
    try:
        config = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return {"valid_json": False, "instances": 0, "nodes": 0}
    users = config.get("users", []) if isinstance(config, dict) else []
    telegram = config.get("telegram", {}) if isinstance(config, dict) else {}
    nodes = telegram.get("node_urls", []) if isinstance(telegram, dict) else []
    return {
        "valid_json": isinstance(config, dict),
        "instances": len(users) if isinstance(users, list) else 0,
        "nodes": len(nodes) if isinstance(nodes, list) else 0,
        "web_enabled": bool(
            isinstance(config, dict)
            and isinstance(config.get("web_panel"), dict)
            and config["web_panel"].get("enabled")
        ),
    }


def preview_restore(path, passphrase, app_dir=APP_DIR):
    payload = load_backup(path, passphrase)
    root = Path(app_dir)
    changes = []
    config_summary = None
    for raw_name, metadata in sorted(payload["files"].items()):
        name = _safe_relative_path(raw_name)
        if not isinstance(metadata, dict):
            raise BackupError("备份文件元数据无效")
        data = _b64decode(metadata.get("content", ""), name)
        expected = str(metadata.get("sha256", "")).lower()
        if hashlib.sha256(data).hexdigest() != expected:
            raise BackupError("备份内部校验失败: {}".format(name))
        current = root / name
        if not current.exists():
            action = "add"
        elif hashlib.sha256(current.read_bytes()).hexdigest() == expected:
            action = "unchanged"
        else:
            action = "replace"
        changes.append({"path": name, "action": action, "size": len(data)})
        if name == "config.json":
            config_summary = _config_summary(data)
    return {
        "created_at": payload.get("created_at"),
        "files": changes,
        "summary": config_summary or {},
    }


def restore_backup(path, passphrase, app_dir=APP_DIR, include_logs=True):
    preview = preview_restore(path, passphrase, app_dir)
    payload = load_backup(path, passphrase)
    root = Path(app_dir)
    config_entry = payload["files"].get("config.json")
    if not isinstance(config_entry, dict):
        raise BackupError("备份缺少 config.json")
    try:
        config_value = json.loads(
            _b64decode(config_entry.get("content", ""), "config.json").decode(
                "utf-8"
            )
        )
        import aliyun_guard as guard

        guard.validate_config(guard.deep_merge(guard.DEFAULT_CONFIG, config_value))
    except BackupError:
        raise
    except Exception as exc:
        raise BackupError("备份配置校验失败: {}".format(exc)) from exc
    safety = create_backup(
        passphrase,
        root,
        root / "backups" / "before-restore-{}.agbackup".format(_stamp()),
        include_state=True,
        include_logs=include_logs,
    )
    restored = []
    for raw_name, metadata in sorted(payload["files"].items()):
        name = _safe_relative_path(raw_name)
        if name.startswith("logs/") and not include_logs:
            continue
        data = _b64decode(metadata.get("content", ""), name)
        destination = root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".restore.tmp")
        temporary.write_bytes(data)
        mode = int(metadata.get("mode", 0o600)) & 0o777
        os.chmod(str(temporary), mode or 0o600)
        os.replace(str(temporary), str(destination))
        restored.append(name)
    return {"preview": preview, "restored": restored, "safety_backup": str(safety)}


def create_program_snapshot(app_dir=APP_DIR, version="unknown"):
    root = Path(app_dir)
    destination = root / "backups" / "program-{}-{}.tar.gz".format(
        _stamp(), str(version or "unknown").replace("/", "-")
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    existing = [name for name in PROGRAM_FILES if (root / name).is_file()]
    if not existing:
        raise BackupError("未找到可快照的程序文件")
    manifest = {
        "format": SNAPSHOT_FORMAT,
        "created_at": _now_text(),
        "version": str(version or "unknown"),
        "files": existing,
    }
    with tarfile.open(str(destination), "w:gz") as archive:
        for name in existing:
            archive.add(str(root / name), arcname=name, recursive=False)
        encoded = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            handle.write(encoded)
            manifest_path = Path(handle.name)
        try:
            archive.add(str(manifest_path), arcname="snapshot-manifest.json", recursive=False)
        finally:
            manifest_path.unlink(missing_ok=True)
    os.chmod(str(destination), 0o600)
    return destination


def list_program_snapshots(backup_dir=None, app_dir=APP_DIR):
    directory = Path(backup_dir) if backup_dir else Path(app_dir) / "backups"
    if not directory.exists():
        return []
    return sorted(directory.glob("program-*.tar.gz"), reverse=True)


def restore_program_snapshot(snapshot_path=None, app_dir=APP_DIR):
    root = Path(app_dir)
    snapshots = list_program_snapshots(app_dir=root)
    snapshot_source = (
        Path(snapshot_path) if snapshot_path else (snapshots[0] if snapshots else None)
    )
    if snapshot_source is None or not snapshot_source.is_file():
        raise BackupError("没有可用的程序回滚快照")
    try:
        snapshot_source.resolve().relative_to((root / "backups").resolve())
    except (OSError, ValueError) as exc:
        raise BackupError("程序快照必须位于本机备份目录") from exc
    with tempfile.TemporaryDirectory(prefix="aliyun-guard-rollback-") as directory:
        staging = Path(directory)
        try:
            with tarfile.open(str(snapshot_source), "r:gz") as archive:
                members = archive.getmembers()
                allowed = set(PROGRAM_FILES) | {"snapshot-manifest.json"}
                names = [member.name for member in members]
                if (
                    len(names) != len(set(names))
                    or names.count("snapshot-manifest.json") != 1
                    or any(
                        member.name not in allowed
                        or not member.isfile()
                        or member.size > MAX_FILE_BYTES
                        for member in members
                    )
                ):
                    raise BackupError("程序快照包含不安全文件")
                for member in members:
                    member_source = archive.extractfile(member)
                    if member_source is None:
                        raise BackupError("程序快照文件无法读取")
                    destination = staging / member.name
                    with member_source, destination.open("wb") as handle:
                        shutil.copyfileobj(member_source, handle)
        except (OSError, tarfile.TarError) as exc:
            raise BackupError("无法读取程序快照: {}".format(exc)) from exc
        manifest_path = staging / "snapshot-manifest.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise BackupError("程序快照清单无效") from exc
        if manifest.get("format") != SNAPSHOT_FORMAT:
            raise BackupError("程序快照版本不受支持")
        manifest_files = manifest.get("files")
        if (
            not isinstance(manifest_files, list)
            or not manifest_files
            or len(manifest_files) != len(set(manifest_files))
            or any(
                name not in PROGRAM_FILES or not (staging / name).is_file()
                for name in manifest_files
            )
        ):
            raise BackupError("程序快照文件列表无效")
        current_snapshot = create_program_snapshot(root, "before-rollback")
        restored = []
        for name in manifest_files:
            destination = root / name
            temporary = destination.with_name(destination.name + ".rollback.tmp")
            shutil.copy2(str(staging / name), str(temporary))
            os.chmod(str(temporary), 0o755 if name.endswith(".sh") else 0o600)
            os.replace(str(temporary), str(destination))
            restored.append(name)
    return {
        "snapshot": str(snapshot_source),
        "version": str(manifest.get("version", "unknown")),
        "restored": restored,
        "safety_snapshot": str(current_snapshot),
    }
__AG_BACKUP_PY_EOF__
    cat > "$APP_DIR/s3_backup.py" <<'__AG_S3_BACKUP_PY_EOF__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Encrypted backup storage for AWS S3 and S3-compatible services."""

import contextlib
import datetime as dt
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.parse

import backup_manager

try:
    import boto3
    from botocore.config import Config
    from botocore.exceptions import BotoCoreError, ClientError
    from boto3.s3.transfer import TransferConfig
    BOTO_IMPORT_ERROR = None
except ImportError as exc:  # pragma: no cover - installer supplies boto3
    boto3 = None
    Config = None
    TransferConfig = None
    BotoCoreError = ClientError = Exception
    BOTO_IMPORT_ERROR = exc

try:
    import fcntl
except ImportError:  # pragma: no cover - deployed targets are Linux
    fcntl = None


DEFAULT_CONFIG = {
    "enabled": False,
    "bucket": "",
    "region": "us-east-1",
    "endpoint_url": "",
    "addressing_style": "auto",
    "prefix": "aliyun-guard",
    "access_key_id": "",
    "secret_access_key": "",
    "session_token": "",
    "backup_password": "",
    "schedule": "daily",
    "time": "03:00",
    "weekday": 0,
    "retention": 30,
    "include_state": True,
    "include_logs": False,
    "notification_mode": "errors",
    "server_side_encryption": "AES256",
    "kms_key_id": "",
}

STATE_NAME = "s3-backup-state.json"
LOCK_NAME = "s3-backup.lock"
MAX_REMOTE_ITEMS = 5000
RETRY_SECONDS = 15 * 60


class S3BackupError(RuntimeError):
    pass


def normalized_config(value):
    result = dict(DEFAULT_CONFIG)
    if isinstance(value, dict):
        result.update(value)
    result["bucket"] = str(result.get("bucket", "") or "").strip()
    result["region"] = str(result.get("region", "") or "us-east-1").strip()
    result["endpoint_url"] = str(result.get("endpoint_url", "") or "").strip().rstrip("/")
    result["prefix"] = str(result.get("prefix", "") or "aliyun-guard").strip().strip("/")
    for field in ("access_key_id", "secret_access_key", "session_token", "backup_password", "kms_key_id"):
        result[field] = str(result.get(field, "") or "").strip()
    return result


def validate_config(value, require_ready=None):
    config = normalized_config(value)
    for field in ("enabled", "include_state", "include_logs"):
        if not isinstance(config.get(field), bool):
            raise S3BackupError("s3_backup.{} 必须是布尔值".format(field))
    if config["schedule"] not in ("hourly", "daily", "weekly"):
        raise S3BackupError("S3 备份周期必须是 hourly、daily 或 weekly")
    if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", str(config.get("time", ""))):
        raise S3BackupError("S3 备份时间必须是 HH:MM")
    try:
        config["weekday"] = int(config.get("weekday", 0))
        config["retention"] = int(config.get("retention", 30))
    except (TypeError, ValueError) as exc:
        raise S3BackupError("S3 星期和保留份数必须是整数") from exc
    if config["weekday"] < 0 or config["weekday"] > 6:
        raise S3BackupError("S3 每周备份日期必须在 0 到 6 之间")
    if config["retention"] < 1 or config["retention"] > 365:
        raise S3BackupError("S3 备份保留份数必须在 1 到 365 之间")
    if config["notification_mode"] not in ("always", "errors", "none"):
        raise S3BackupError("S3 通知模式必须是 always、errors 或 none")
    if config["server_side_encryption"] not in ("", "AES256", "aws:kms"):
        raise S3BackupError("S3 服务端加密必须是 AES256、aws:kms 或关闭")
    if config["addressing_style"] not in ("auto", "path", "virtual"):
        raise S3BackupError("S3 寻址方式必须是 auto、path 或 virtual")
    if config["server_side_encryption"] == "aws:kms" and not config["kms_key_id"]:
        raise S3BackupError("使用 SSE-KMS 时必须填写 KMS Key ID")
    if bool(config["access_key_id"]) != bool(config["secret_access_key"]):
        raise S3BackupError("S3 Access Key ID 和 Secret Access Key 必须同时填写或同时留空")
    if config["session_token"] and not config["access_key_id"]:
        raise S3BackupError("S3 Session Token 需要同时配置 Access Key")
    if config["endpoint_url"]:
        parsed = urllib.parse.urlsplit(config["endpoint_url"])
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password:
            raise S3BackupError("S3 Endpoint 必须是无账号密码的 HTTP/HTTPS 地址")
        if parsed.scheme == "http" and parsed.hostname not in (
            "127.0.0.1",
            "localhost",
            "::1",
        ):
            raise S3BackupError("远程 S3 Endpoint 必须使用 HTTPS；HTTP 仅允许本机 MinIO")
    if config["prefix"]:
        if len(config["prefix"]) > 256 or any(part in (".", "..") for part in config["prefix"].split("/")):
            raise S3BackupError("S3 对象前缀无效")
    ready = config["enabled"] if require_ready is None else bool(require_ready)
    if ready:
        if not config["bucket"]:
            raise S3BackupError("S3 Bucket 不能为空")
        if not config["region"]:
            raise S3BackupError("S3 Region 不能为空")
        if len(config["backup_password"]) < 8:
            raise S3BackupError("S3 自动备份密码至少需要 8 个字符")
    return config


def _require_boto3():
    if BOTO_IMPORT_ERROR is not None:
        raise S3BackupError("缺少 S3 依赖 boto3: {}".format(BOTO_IMPORT_ERROR))


def create_client(value):
    _require_boto3()
    config = validate_config(value, require_ready=True)
    kwargs = {
        "service_name": "s3",
        "region_name": config["region"],
        "config": Config(
            connect_timeout=10,
            read_timeout=60,
            retries={"max_attempts": 3, "mode": "standard"},
            signature_version="s3v4",
            s3={"addressing_style": config["addressing_style"]},
        ),
    }
    if config["endpoint_url"]:
        kwargs["endpoint_url"] = config["endpoint_url"]
    if config["access_key_id"]:
        kwargs["aws_access_key_id"] = config["access_key_id"]
        kwargs["aws_secret_access_key"] = config["secret_access_key"]
        if config["session_token"]:
            kwargs["aws_session_token"] = config["session_token"]
    return boto3.client(**kwargs)


def _compact_error(exc, secrets=()):
    if BOTO_IMPORT_ERROR is None and isinstance(exc, ClientError):
        error = exc.response.get("Error", {})
        text = "{}: {}".format(error.get("Code", "S3Error"), error.get("Message", str(exc)))
    else:
        text = str(exc)
    for secret in secrets:
        if secret:
            text = text.replace(str(secret), "***")
    return text.replace("\r", " ").replace("\n", " ")[:600]


def _config_secrets(config):
    return tuple(
        config.get(field, "")
        for field in ("access_key_id", "secret_access_key", "session_token", "backup_password")
        if config.get(field, "")
    )


def _call(label, operation, secrets=()):
    try:
        return operation()
    except (BotoCoreError, ClientError, OSError) as exc:
        raise S3BackupError(
            "{}失败: {}".format(label, _compact_error(exc, secrets=secrets))
        ) from exc


def object_prefix(value):
    config = normalized_config(value)
    return config["prefix"] + "/" if config["prefix"] else ""


def test_connection(value):
    config = validate_config(value, require_ready=True)
    client = create_client(config)
    started = dt.datetime.now().astimezone()
    _call(
        "S3 连接测试",
        lambda: client.list_objects_v2(
            Bucket=config["bucket"], Prefix=object_prefix(config), MaxKeys=1
        ),
        secrets=_config_secrets(config),
    )
    elapsed = (dt.datetime.now().astimezone() - started).total_seconds()
    return {
        "ok": True,
        "bucket": config["bucket"],
        "region": config["region"],
        "endpoint": config["endpoint_url"] or "AWS S3",
        "latency_ms": max(0, int(elapsed * 1000)),
    }


def _extra_args(config):
    result = {
        "ContentType": "application/json",
        "Metadata": {"format": backup_manager.BACKUP_FORMAT},
    }
    encryption = config["server_side_encryption"]
    if encryption:
        result["ServerSideEncryption"] = encryption
    if encryption == "aws:kms":
        result["SSEKMSKeyId"] = config["kms_key_id"]
    return result


def list_backups(value, limit=100, client=None):
    config = validate_config(value, require_ready=True)
    client = client or create_client(config)
    prefix = object_prefix(config)
    items = []
    token = None
    while len(items) < MAX_REMOTE_ITEMS:
        kwargs = {"Bucket": config["bucket"], "Prefix": prefix, "MaxKeys": 1000}
        if token:
            kwargs["ContinuationToken"] = token
        response = _call(
            "读取 S3 备份列表",
            lambda kwargs=kwargs: client.list_objects_v2(**kwargs),
            secrets=_config_secrets(config),
        )
        for item in response.get("Contents", []):
            key = str(item.get("Key", ""))
            name = key[len(prefix):] if key.startswith(prefix) else ""
            if name and "/" not in name and key.endswith(".agbackup"):
                modified = item.get("LastModified")
                items.append(
                    {
                        "key": key,
                        "name": name,
                        "size": int(item.get("Size", 0)),
                        "modified_at": modified.isoformat() if hasattr(modified, "isoformat") else str(modified or ""),
                        "etag": str(item.get("ETag", "")).strip('"'),
                    }
                )
        if not response.get("IsTruncated"):
            break
        token = response.get("NextContinuationToken")
        if not token:
            break
    items.sort(key=lambda item: (item["modified_at"], item["key"]), reverse=True)
    return items[: max(1, min(int(limit), MAX_REMOTE_ITEMS))]


def prune_backups(value, client=None):
    config = validate_config(value, require_ready=True)
    client = client or create_client(config)
    items = list_backups(config, limit=MAX_REMOTE_ITEMS, client=client)
    expired = items[config["retention"] :]
    for item in expired:
        _call(
            "清理旧 S3 备份",
            lambda key=item["key"]: client.delete_object(Bucket=config["bucket"], Key=key),
            secrets=_config_secrets(config),
        )
    return [item["key"] for item in expired]


def prune_local_backups(app_dir, retention):
    local_items = sorted(
        (Path(app_dir) / "backups").glob("aliyun-guard-s3-*.agbackup"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    deleted = []
    for expired in local_items[int(retention) :]:
        expired.unlink(missing_ok=True)
        deleted.append(str(expired))
    return deleted


def create_and_upload(value, app_dir, now=None):
    config = validate_config(value, require_ready=True)
    now = now or dt.datetime.now().astimezone()
    stamp = now.strftime("%Y%m%d-%H%M%S-%f")
    filename = "aliyun-guard-s3-{}.agbackup".format(stamp)
    local_path = Path(app_dir) / "backups" / filename
    backup_manager.create_backup(
        config["backup_password"],
        app_dir=Path(app_dir),
        output_path=local_path,
        include_state=config["include_state"],
        include_logs=config["include_logs"],
    )
    client = create_client(config)
    key = object_prefix(config) + filename
    try:
        _call(
            "上传 S3 加密备份",
            lambda: client.upload_file(
                str(local_path),
                config["bucket"],
                key,
                ExtraArgs=_extra_args(config),
                Config=TransferConfig(
                    multipart_threshold=backup_manager.MAX_BACKUP_FILE_BYTES + 1
                ),
            ),
            secrets=_config_secrets(config),
        )
        deleted = prune_backups(config, client=client)
    finally:
        local_deleted = prune_local_backups(app_dir, config["retention"])
    return {
        "ok": True,
        "key": key,
        "filename": filename,
        "size": local_path.stat().st_size,
        "local_path": str(local_path),
        "deleted": deleted,
        "local_deleted": local_deleted,
        "bucket": config["bucket"],
    }


def _validate_remote_key(value, key):
    prefix = object_prefix(value)
    key = str(key or "").strip()
    name = key[len(prefix):] if key.startswith(prefix) else ""
    if (
        not name
        or len(key) > 1024
        or len(name) > 255
        or "/" in name
        or "\\" in name
        or not name.endswith(".agbackup")
    ):
        raise S3BackupError("S3 备份对象不在当前配置前缀下")
    return key, name


def download_backup(value, key, app_dir):
    config = validate_config(value, require_ready=True)
    key, name = _validate_remote_key(config, key)
    directory = Path(app_dir) / "backups"
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=str(directory), prefix=".s3-download-", suffix=".agbackup", delete=False
    ) as handle:
        destination = Path(handle.name)
    temporary = destination.with_name(destination.name + ".tmp")
    client = create_client(config)
    try:
        metadata = _call(
            "读取 S3 备份信息",
            lambda: client.head_object(Bucket=config["bucket"], Key=key),
            secrets=_config_secrets(config),
        )
        if int(metadata.get("ContentLength", 0)) > backup_manager.MAX_BACKUP_FILE_BYTES:
            raise S3BackupError("S3 备份文件超过大小限制")
        _call(
            "下载 S3 加密备份",
            lambda: client.download_file(config["bucket"], key, str(temporary)),
            secrets=_config_secrets(config),
        )
        if temporary.stat().st_size > backup_manager.MAX_BACKUP_FILE_BYTES:
            raise S3BackupError("S3 备份文件超过大小限制")
        os.chmod(str(temporary), 0o600)
        os.replace(str(temporary), str(destination))
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def schedule_slot(value, now=None):
    config = validate_config(value, require_ready=True)
    now = now or dt.datetime.now().astimezone()
    hour, minute = (int(part) for part in config["time"].split(":"))
    if config["schedule"] == "hourly":
        target = now.replace(minute=minute, second=0, microsecond=0)
        return now.strftime("hourly:%Y%m%d%H") if now >= target else None
    if config["schedule"] == "daily":
        target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        return now.strftime("daily:%Y%m%d") if now >= target else None
    week_start = (now - dt.timedelta(days=now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    target = week_start + dt.timedelta(
        days=config["weekday"], hours=hour, minutes=minute
    )
    return "weekly:{}".format(week_start.strftime("%Y%m%d")) if now >= target else None


def _read_state(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def read_status(app_dir):
    return _read_state(Path(app_dir) / STATE_NAME)


def _write_state(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(str(temporary), 0o600)
    os.replace(str(temporary), str(path))


@contextlib.contextmanager
def backup_lock(app_dir):
    path = Path(app_dir) / LOCK_NAME
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    locked = True
    if fcntl is not None:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            locked = False
    try:
        yield locked
    finally:
        if locked and fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def run_if_due(value, app_dir, now=None):
    config = validate_config(value, require_ready=False)
    if not config["enabled"]:
        return None
    config = validate_config(config, require_ready=True)
    now = now or dt.datetime.now().astimezone()
    slot = schedule_slot(config, now)
    if slot is None:
        return None
    state_path = Path(app_dir) / STATE_NAME
    with backup_lock(app_dir) as locked:
        if not locked:
            return {"ok": True, "skipped": "locked", "slot": slot}
        state = _read_state(state_path)
        if state.get("last_success_slot") == slot:
            return None
        if state.get("last_attempt_slot") == slot:
            try:
                last_attempt = dt.datetime.fromisoformat(state["last_attempt_at"])
                if (now - last_attempt).total_seconds() < RETRY_SECONDS:
                    return None
            except (KeyError, TypeError, ValueError):
                pass
        state.update(
            {
                "last_attempt_slot": slot,
                "last_attempt_at": now.isoformat(timespec="seconds"),
            }
        )
        _write_state(state_path, state)
        try:
            result = create_and_upload(config, app_dir, now=now)
            state.update(
                {
                    "last_success_slot": slot,
                    "last_success_at": now.isoformat(timespec="seconds"),
                    "last_key": result["key"],
                    "last_error": None,
                }
            )
            result["slot"] = slot
        except Exception as exc:
            error = _compact_error(
                exc,
                secrets=(
                    config["access_key_id"],
                    config["secret_access_key"],
                    config["session_token"],
                    config["backup_password"],
                ),
            )
            state["last_error"] = error
            result = {"ok": False, "slot": slot, "error": error}
        _write_state(state_path, state)
        return result
__AG_S3_BACKUP_PY_EOF__
    cat > "$APP_DIR/watchdog.py" <<'__AG_WATCHDOG_PY_EOF__'
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
__AG_WATCHDOG_PY_EOF__
    cat > "$APP_DIR/telegram_proxy.py" <<'__AG_PROXY_PY_EOF__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Telegram proxy helpers backed by an official sing-box binary."""

import atexit
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import tarfile
import tempfile
import threading
import time
import urllib.parse
import urllib.request


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
SING_BOX_VERSION = "1.13.14"
SING_BOX_BINARY = APP_DIR / "bin" / "sing-box"
SING_BOX_RELEASE_BASE = (
    "https://github.com/SagerNet/sing-box/releases/download/v{}".format(SING_BOX_VERSION)
)
SING_BOX_ASSETS = {
    "386": (
        "sing-box-1.13.14-linux-386.tar.gz",
        "4d1c66260dfcb2120fde6c1c5ad125ce0f94769843c34aab4eef53c8d3bf3ae9",
    ),
    "amd64": (
        "sing-box-1.13.14-linux-amd64.tar.gz",
        "f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697",
    ),
    "arm64": (
        "sing-box-1.13.14-linux-arm64.tar.gz",
        "4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e",
    ),
    "armv7": (
        "sing-box-1.13.14-linux-armv7.tar.gz",
        "e01a58d28512b1447ab6156017afdeeaa306169a95d27abc00e112599e4ae46c",
    ),
}

_PROCESS = None
_PROCESS_KEY = None
_PROCESS_PROXY_URL = None
_PROCESS_DIR = None
_PROCESS_LOG = None
_PROCESS_LOCK = threading.RLock()


class ProxyError(RuntimeError):
    pass


def _decode_base64(value):
    value = urllib.parse.unquote(str(value or "").strip())
    value += "=" * (-len(value) % 4)
    try:
        return base64.urlsafe_b64decode(value.encode("ascii")).decode("utf-8")
    except Exception:
        raise ProxyError("节点链接包含无效的 Base64 数据")


def _query_value(query, *names, **kwargs):
    default = kwargs.get("default", "")
    for name in names:
        values = query.get(name)
        if values:
            return str(values[0])
    return default


def _truthy(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def _require_server(parsed):
    try:
        port = parsed.port
    except ValueError:
        raise ProxyError("节点端口无效")
    if not parsed.hostname or not port:
        raise ProxyError("节点链接缺少服务器地址或端口")
    return parsed.hostname, port


def _build_tls(query, server, security):
    if security not in ("tls", "reality"):
        return None
    tls = {
        "enabled": True,
        "server_name": _query_value(query, "sni", "serverName", default=server),
    }
    if _truthy(_query_value(query, "allowInsecure", "insecure")):
        tls["insecure"] = True
    alpn = _query_value(query, "alpn")
    if alpn:
        tls["alpn"] = [item.strip() for item in alpn.split(",") if item.strip()]
    fingerprint = _query_value(query, "fp", "fingerprint")
    if fingerprint and fingerprint.lower() != "none":
        tls["utls"] = {"enabled": True, "fingerprint": fingerprint}
    if security == "reality":
        public_key = _query_value(query, "pbk", "publicKey")
        if not public_key:
            raise ProxyError("Reality 节点缺少 public key（pbk）")
        tls["reality"] = {
            "enabled": True,
            "public_key": public_key,
            "short_id": _query_value(query, "sid", "shortId"),
        }
    return tls


def _build_transport(network, query, host="", path=""):
    network = str(network or "tcp").strip().lower()
    if network in ("", "tcp", "raw"):
        return None
    if network == "ws":
        transport = {
            "type": "ws",
            "path": urllib.parse.unquote(path or _query_value(query, "path", default="/")),
        }
        ws_host = host or _query_value(query, "host")
        if ws_host:
            transport["headers"] = {"Host": ws_host}
        return transport
    if network == "grpc":
        return {
            "type": "grpc",
            "service_name": urllib.parse.unquote(
                path or _query_value(query, "serviceName", "service_name", "path")
            ),
        }
    if network in ("http", "h2"):
        transport = {
            "type": "http",
            "path": urllib.parse.unquote(path or _query_value(query, "path", default="/")),
        }
        http_host = host or _query_value(query, "host")
        if http_host:
            transport["host"] = [http_host]
        return transport
    if network in ("httpupgrade", "http-upgrade"):
        transport = {
            "type": "httpupgrade",
            "path": urllib.parse.unquote(path or _query_value(query, "path", default="/")),
        }
        upgrade_host = host or _query_value(query, "host")
        if upgrade_host:
            transport["host"] = upgrade_host
        return transport
    raise ProxyError("暂不支持节点传输类型: {}".format(network))


def parse_vless_link(link):
    parsed = urllib.parse.urlsplit(link)
    server, port = _require_server(parsed)
    uuid = urllib.parse.unquote(parsed.username or "").strip()
    if not uuid:
        raise ProxyError("VLESS 节点缺少 UUID")
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    outbound = {
        "type": "vless",
        "tag": "telegram-node",
        "server": server,
        "server_port": port,
        "uuid": uuid,
    }
    flow = _query_value(query, "flow")
    if flow:
        outbound["flow"] = flow
    packet_encoding = _query_value(query, "packetEncoding", "packet_encoding")
    if packet_encoding:
        outbound["packet_encoding"] = packet_encoding
    security = _query_value(query, "security").lower()
    tls = _build_tls(query, server, security)
    if tls:
        outbound["tls"] = tls
    transport = _build_transport(
        _query_value(query, "type", default="tcp"),
        query,
        _query_value(query, "host"),
        _query_value(query, "path"),
    )
    if transport:
        outbound["transport"] = transport
    return outbound


def parse_vmess_link(link):
    encoded = link[len("vmess://"):].split("#", 1)[0].strip()
    try:
        data = json.loads(_decode_base64(encoded))
    except ValueError:
        raise ProxyError("VMess 节点内容不是有效 JSON")
    if not isinstance(data, dict):
        raise ProxyError("VMess 节点内容格式无效")
    server = str(data.get("add", "")).strip()
    uuid = str(data.get("id", "")).strip()
    try:
        port = int(data.get("port", 0))
        alter_id = int(data.get("aid", 0) or 0)
    except (TypeError, ValueError):
        raise ProxyError("VMess 节点端口或 alterId 无效")
    if not server or not port or not uuid:
        raise ProxyError("VMess 节点缺少服务器、端口或 UUID")
    outbound = {
        "type": "vmess",
        "tag": "telegram-node",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "security": str(data.get("scy", "auto") or "auto"),
        "alter_id": alter_id,
    }
    query = {
        "sni": [str(data.get("sni", ""))],
        "alpn": [str(data.get("alpn", ""))],
        "fp": [str(data.get("fp", ""))],
        "allowInsecure": [str(data.get("allowInsecure", ""))],
    }
    security = "tls" if str(data.get("tls", "")).lower() in ("tls", "1", "true") else ""
    tls = _build_tls(query, server, security)
    if tls:
        outbound["tls"] = tls
    transport = _build_transport(
        data.get("net", "tcp"),
        {},
        str(data.get("host", "")),
        str(data.get("path", "")),
    )
    if transport:
        outbound["transport"] = transport
    return outbound


def parse_shadowsocks_link(link):
    raw = link[len("ss://"):]
    raw = raw.split("#", 1)[0]
    main, separator, raw_query = raw.partition("?")
    if "@" not in main:
        main = _decode_base64(main)
    userinfo, marker, server_part = main.rpartition("@")
    if not marker:
        raise ProxyError("Shadowsocks 节点格式无效")
    userinfo = urllib.parse.unquote(userinfo)
    if ":" not in userinfo:
        userinfo = _decode_base64(userinfo)
    method, marker, password = userinfo.partition(":")
    if not marker or not method or not password:
        raise ProxyError("Shadowsocks 节点缺少加密方式或密码")
    parsed = urllib.parse.urlsplit("ss://placeholder@{}".format(server_part))
    server, port = _require_server(parsed)
    outbound = {
        "type": "shadowsocks",
        "tag": "telegram-node",
        "server": server,
        "server_port": port,
        "method": method,
        "password": urllib.parse.unquote(password),
    }
    query = urllib.parse.parse_qs(raw_query, keep_blank_values=True)
    plugin_spec = urllib.parse.unquote(_query_value(query, "plugin"))
    if plugin_spec:
        plugin_parts = plugin_spec.split(";")
        outbound["plugin"] = plugin_parts[0]
        if len(plugin_parts) > 1:
            outbound["plugin_opts"] = ";".join(plugin_parts[1:])
    return outbound


def parse_node_link(link):
    link = str(link or "").strip()
    scheme = urllib.parse.urlsplit(link).scheme.lower()
    if scheme == "vless":
        return parse_vless_link(link)
    if scheme == "vmess":
        return parse_vmess_link(link)
    if scheme == "ss":
        return parse_shadowsocks_link(link)
    raise ProxyError("节点链接必须以 vless://、vmess:// 或 ss:// 开头")


def _clean_display_label(value, limit=80):
    value = "".join(char if char.isprintable() else " " for char in str(value or ""))
    return " ".join(value.split())[:limit]


def _node_remark(link, outbound):
    parsed = urllib.parse.urlsplit(link)
    remark = _clean_display_label(urllib.parse.unquote(parsed.fragment))
    if not remark and outbound.get("type") == "vmess":
        encoded = link[len("vmess://"):].split("#", 1)[0].strip()
        try:
            data = json.loads(_decode_base64(encoded))
            if isinstance(data, dict):
                remark = _clean_display_label(data.get("ps"))
        except (ProxyError, ValueError):
            pass
    if remark:
        return remark
    server = _clean_display_label(outbound.get("server"))
    port = outbound.get("server_port")
    if ":" in server:
        server = "[{}]".format(server)
    return "{}:{}".format(server, port) if server and port else server


def describe_node_link(link):
    outbound = parse_node_link(link)
    remark = _node_remark(str(link or "").strip(), outbound)
    if remark:
        return "{} 节点（{}）".format(outbound["type"].upper(), remark)
    return "{} 节点".format(outbound["type"].upper())


def build_sing_box_config(node_link, listen_port):
    return {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [
            {
                "type": "socks",
                "tag": "telegram-in",
                "listen": "127.0.0.1",
                "listen_port": int(listen_port),
            }
        ],
        "outbounds": [parse_node_link(node_link)],
    }


def _architecture():
    machine = platform.machine().lower()
    mapping = {
        "x86_64": "amd64",
        "amd64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
        "armv7l": "armv7",
        "armv7": "armv7",
        "i386": "386",
        "i686": "386",
        "x86": "386",
    }
    architecture = mapping.get(machine)
    if not architecture:
        raise ProxyError("暂不支持当前 CPU 架构: {}".format(machine or "unknown"))
    return architecture


def find_sing_box():
    candidates = [
        os.environ.get("ALIYUN_GUARD_SING_BOX", ""),
        str(SING_BOX_BINARY),
        shutil.which("sing-box") or "",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _check_binary(path):
    try:
        result = subprocess.run(
            [str(path), "version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
            text=True,
        )
    except Exception as exc:
        raise ProxyError("无法执行 sing-box: {}".format(exc))
    if result.returncode != 0:
        raise ProxyError("sing-box 自检失败")


def install_sing_box(progress=None):
    existing = find_sing_box()
    if existing:
        _check_binary(existing)
        return existing
    if platform.system().lower() != "linux":
        raise ProxyError("自动安装 sing-box 仅支持 Linux")
    architecture = _architecture()
    asset_name, expected_sha256 = SING_BOX_ASSETS[architecture]
    url = "{}/{}".format(SING_BOX_RELEASE_BASE, asset_name)
    if progress:
        progress("正在下载官方 sing-box {} ({})...".format(SING_BOX_VERSION, architecture))
    APP_DIR.mkdir(parents=True, exist_ok=True)
    bin_dir = SING_BOX_BINARY.parent
    bin_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(str(bin_dir), 0o700)
    with tempfile.TemporaryDirectory(prefix="aliyun-guard-sing-box-") as directory:
        archive_path = Path(directory) / asset_name
        digest = hashlib.sha256()
        request = urllib.request.Request(url, headers={"User-Agent": "Aliyun-Guard-Installer"})
        try:
            with urllib.request.urlopen(request, timeout=90) as response, archive_path.open("wb") as handle:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                    handle.write(chunk)
        except Exception as exc:
            raise ProxyError("sing-box 下载失败: {}".format(exc))
        if digest.hexdigest() != expected_sha256:
            raise ProxyError("sing-box SHA-256 校验失败，已拒绝安装")
        try:
            with tarfile.open(str(archive_path), "r:gz") as archive:
                members = [
                    member for member in archive.getmembers()
                    if member.isfile() and Path(member.name).name == "sing-box"
                ]
                if len(members) != 1:
                    raise ProxyError("sing-box 压缩包结构无效")
                source = archive.extractfile(members[0])
                if source is None:
                    raise ProxyError("无法读取 sing-box 可执行文件")
                temporary_binary = bin_dir / "sing-box.tmp"
                with temporary_binary.open("wb") as target:
                    shutil.copyfileobj(source, target)
                    target.flush()
                    os.fsync(target.fileno())
                os.chmod(str(temporary_binary), 0o700)
                os.replace(str(temporary_binary), str(SING_BOX_BINARY))
        except ProxyError:
            raise
        except Exception as exc:
            raise ProxyError("sing-box 解压失败: {}".format(exc))
    _check_binary(SING_BOX_BINARY)
    return str(SING_BOX_BINARY)


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def _read_log(directory):
    if not directory:
        return ""
    path = Path(directory) / "sing-box.log"
    try:
        return path.read_text(encoding="utf-8", errors="replace")[-1200:].strip()
    except OSError:
        return ""


def _terminate_process(process):
    if process is None:
        return
    try:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def _cleanup_runtime(process=None, log_handle=None, directory=None):
    try:
        _terminate_process(process)
    finally:
        if log_handle is not None:
            try:
                log_handle.close()
            except OSError:
                pass
        if directory:
            shutil.rmtree(directory, ignore_errors=True)


def stop_node_proxy():
    global _PROCESS, _PROCESS_KEY, _PROCESS_PROXY_URL, _PROCESS_DIR, _PROCESS_LOG
    with _PROCESS_LOCK:
        process = _PROCESS
        log_handle = _PROCESS_LOG
        directory = _PROCESS_DIR
        _PROCESS = None
        _PROCESS_KEY = None
        _PROCESS_PROXY_URL = None
        _PROCESS_DIR = None
        _PROCESS_LOG = None
        _cleanup_runtime(process, log_handle, directory)


def ensure_node_proxy(node_link, startup_timeout=12):
    global _PROCESS, _PROCESS_KEY, _PROCESS_PROXY_URL, _PROCESS_DIR, _PROCESS_LOG
    node_link = str(node_link or "").strip()
    key = hashlib.sha256(node_link.encode("utf-8")).hexdigest()
    with _PROCESS_LOCK:
        if _PROCESS is not None and _PROCESS.poll() is None and _PROCESS_KEY == key:
            return _PROCESS_PROXY_URL
        stop_node_proxy()
        binary = find_sing_box()
        if not binary:
            raise ProxyError("未安装 sing-box，请在 Telegram 连接设置中重新测试并安装")
        port = _free_port()
        config = build_sing_box_config(node_link, port)
        runtime_root = APP_DIR / "runtime"
        runtime_root.mkdir(parents=True, exist_ok=True)
        os.chmod(str(runtime_root), 0o700)
        directory = None
        log_handle = None
        process = None
        managed = False
        try:
            directory = tempfile.mkdtemp(prefix="telegram-node-", dir=str(runtime_root))
            os.chmod(directory, 0o700)
            config_path = Path(directory) / "config.json"
            config_path.write_text(
                json.dumps(config, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            os.chmod(str(config_path), 0o600)
            try:
                check = subprocess.run(
                    [binary, "check", "-c", str(config_path)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=15,
                    check=False,
                    text=True,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                raise ProxyError("无法执行 sing-box 节点配置校验") from exc
            if check.returncode != 0:
                raise ProxyError("sing-box 节点配置校验失败")
            log_path = Path(directory) / "sing-box.log"
            log_handle = log_path.open("a", encoding="utf-8")
            os.chmod(str(log_path), 0o600)
            try:
                process = subprocess.Popen(
                    [binary, "run", "-c", str(config_path)],
                    stdin=subprocess.DEVNULL,
                    stdout=log_handle,
                    stderr=subprocess.STDOUT,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                raise ProxyError("无法启动 sing-box 进程") from exc
            deadline = time.monotonic() + max(3, startup_timeout)
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    break
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                        _PROCESS = process
                        _PROCESS_KEY = key
                        _PROCESS_PROXY_URL = "socks5h://127.0.0.1:{}".format(port)
                        _PROCESS_DIR = directory
                        _PROCESS_LOG = log_handle
                        managed = True
                        return _PROCESS_PROXY_URL
                except OSError:
                    time.sleep(0.15)
            _terminate_process(process)
            detail = _read_log(directory)
            if detail:
                raise ProxyError("sing-box 启动失败: {}".format(detail))
            raise ProxyError("sing-box 启动失败或本地代理端口未就绪")
        finally:
            if not managed:
                _cleanup_runtime(process, log_handle, directory)


atexit.register(stop_node_proxy)
__AG_PROXY_PY_EOF__
    cat > "$APP_DIR/telegram_control.py" <<'__AG_CONTROL_PY_EOF__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Secure Telegram command polling for Aliyun Guard."""

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import secrets
import threading
import time


POLL_TIMEOUT_SECONDS = 20
RETRY_WAIT_SECONDS = 5
CONFIRM_TTL_SECONDS = 90
SCHEDULE_INPUT_TTL_SECONDS = 300

BOT_COMMANDS = [
    {"command": "status", "description": "查看最近检测状态"},
    {"command": "instances", "description": "查看监控实例"},
    {"command": "check", "description": "立即执行一轮检测"},
    {"command": "poweron", "description": "选择实例开机"},
    {"command": "poweroff", "description": "选择实例关机"},
    {"command": "schedule", "description": "管理定时开关机"},
    {"command": "help", "description": "显示控制菜单"},
]


def _token_fingerprint(token):
    return hashlib.sha256(str(token or "").encode("utf-8")).hexdigest()[:24]


def _control_state_path(guard):
    configured = os.environ.get("ALIYUN_GUARD_TELEGRAM_CONTROL_STATE")
    if configured:
        return Path(configured)
    return guard.STATE_FILE.with_name("telegram-control-state.json")


def _load_offset(guard, fingerprint):
    path = _control_state_path(guard)
    try:
        data = guard.load_json(path, {})
        if data.get("token_fingerprint") != fingerprint:
            return None
        offset = int(data.get("offset", 0))
        return max(0, offset)
    except Exception:
        return None


def _save_offset(guard, fingerprint, offset):
    guard.atomic_write_json(
        _control_state_path(guard),
        {"token_fingerprint": fingerprint, "offset": max(0, int(offset))},
        mode=0o600,
    )


def _format_traffic(value):
    try:
        return "{:.2f} GB".format(float(value))
    except (TypeError, ValueError):
        return "暂无"


def build_status_text(guard, config=None, state=None):
    config = config or guard.load_config()
    state = state or guard.load_state()
    finished = state.get("last_cycle_finished_at") or "尚未完成检测"
    if state.get("last_cycle_finished_at"):
        result = "正常" if state.get("last_cycle_ok") else "存在错误"
    else:
        result = "暂无"
    lines = [
        "Aliyun Guard 状态",
        "最近检测: {}".format(finished),
        "检测结果: {}".format(result),
        "检测次数: {}".format(int(state.get("cycle_count", 0) or 0)),
        "监控实例: {} 个".format(len(config.get("users", []))),
    ]
    telegram_error = str(state.get("telegram_error", "") or "").strip()
    if telegram_error:
        lines.append("通知状态: 上次发送失败")
    return "\n".join(lines)


def build_instances_text(guard, config=None, state=None):
    config = config or guard.load_config()
    state = state or guard.load_state()
    previous = state.get("instances", {})
    if not isinstance(previous, dict):
        previous = {}
    users = config.get("users", [])
    if not users:
        return "尚未配置监控实例。"
    lines = ["监控实例"]
    for index, user in enumerate(users, 1):
        instance_id = str(user.get("instance_id", ""))
        current = previous.get(instance_id, {})
        if not isinstance(current, dict):
            current = {}
        status = current.get("status_after") or "Unknown"
        mode = "已暂停" if user.get("paused") else "监控中"
        lines.extend(
            [
                "",
                "#{:d} {}".format(index, user.get("name") or instance_id),
                "ID: {}".format(instance_id),
                "状态: {} · {}".format(status, mode),
                "流量: {} / {:.2f} GB".format(
                    _format_traffic(current.get("traffic_gb")),
                    float(user.get("traffic_limit_gb", 0) or 0),
                ),
            ]
        )
    return "\n".join(lines)


def resolve_instance(config, selector):
    users = config.get("users", [])
    selector = str(selector or "").strip()
    if selector.isdigit():
        index = int(selector) - 1
        if 0 <= index < len(users):
            return users[index]
    exact = [
        user
        for user in users
        if selector
        and selector.casefold()
        in {
            str(user.get("instance_id", "")).casefold(),
            str(user.get("name", "")).casefold(),
        }
    ]
    return exact[0] if len(exact) == 1 else None


def build_schedule_text(guard, user, now=None):
    now = now or dt.datetime.now().astimezone()
    schedule = guard.get_schedule_config(user)
    name = str(user.get("name") or user.get("instance_id", ""))
    lines = [
        "定时开关机",
        "实例: {} ({})".format(name, user.get("instance_id", "")),
        "服务器时间: {}".format(now.strftime("%Y-%m-%d %H:%M %Z%z")),
        "计划状态: {}".format("已启用" if schedule["enabled"] else "已关闭"),
        "每日开机: {}".format(schedule["start_time"]),
        "每日关机: {}".format(schedule["stop_time"]),
    ]
    if schedule["enabled"]:
        target = guard.schedule_target(user, now)
        event = guard.next_schedule_event(user, now)
        lines.append(
            "运行时段: {}".format(
                "跨午夜" if schedule["start_time"] > schedule["stop_time"] else "当日"
            )
        )
        lines.append("当前目标: {}".format("运行" if target == "running" else "关机"))
        if event:
            event_time, action = event
            lines.append(
                "下一动作: {} {}".format(
                    event_time.strftime("%Y-%m-%d %H:%M"),
                    "开机" if action == "start" else "关机",
                )
            )
    if user.get("paused"):
        lines.append("提示: 实例监控已暂停，计划暂不执行。")
    else:
        lines.append("提示: 达到流量阈值时不会执行计划开机。")
    return "\n".join(lines)


class TelegramControlService:
    def __init__(self, guard):
        self.guard = guard
        self.stop_event = threading.Event()
        self.thread = threading.Thread(
            target=self._run,
            name="aliyun-guard-telegram-control",
            daemon=True,
        )
        self.pending = {}
        self.schedule_inputs = {}
        self.offset = None
        self.fingerprint = None
        self.commands_fingerprint = None
        self.last_error = None
        self.last_inactive_reason = None
        self.drain_pending = True

    def start(self):
        self.thread.start()
        return self

    def shutdown(self):
        self.stop_event.set()
        self.thread.join(timeout=POLL_TIMEOUT_SECONDS + 5)

    def _log_inactive(self, reason):
        if reason != self.last_inactive_reason:
            self.guard.LOGGER.info("Telegram Bot 控制未运行: %s", reason)
            self.last_inactive_reason = reason

    def _poll_config(self):
        config = self.guard.load_config()
        telegram = config.get("telegram", {})
        if not telegram.get("control_enabled", True):
            self.drain_pending = True
            self._log_inactive("已在配置中关闭")
            return None, None, None
        if not str(telegram.get("bot_token", "") or "").strip():
            self.drain_pending = True
            self._log_inactive("Bot Token 未配置")
            return None, None, None
        admins = self.guard.telegram_control_admin_ids(telegram)
        if not admins:
            self.drain_pending = True
            self._log_inactive("未配置有效的管理员用户 ID")
            return None, None, None
        self.last_inactive_reason = None
        return config, telegram, set(admins)

    def _telegram_api(self, telegram, method, data=None, long_poll=False):
        candidate = dict(telegram)
        if long_poll:
            candidate["retries"] = 1
        request_timeout = POLL_TIMEOUT_SECONDS + 10 if long_poll else None
        return self.guard.telegram_api(
            candidate,
            method,
            data or {},
            request_timeout=request_timeout,
        )

    def _send(self, telegram, chat_id, text, reply_markup=None):
        chunks = self.guard.split_message(str(text or ""))
        result = None
        for index, chunk in enumerate(chunks):
            data = {"chat_id": str(chat_id), "text": chunk}
            if reply_markup is not None and index == len(chunks) - 1:
                data["reply_markup"] = json.dumps(reply_markup, ensure_ascii=False)
            result = self._telegram_api(telegram, "sendMessage", data)
        return result

    @staticmethod
    def _callback_message_ref(callback):
        message = callback.get("message", {}) if isinstance(callback, dict) else {}
        chat_id = message.get("chat", {}).get("id")
        message_id = message.get("message_id")
        if chat_id is None or message_id is None:
            return None, None
        return int(chat_id), int(message_id)

    def _edit(self, telegram, chat_id, message_id, text, reply_markup=None):
        chunks = self.guard.split_message(str(text or ""))
        if len(chunks) != 1:
            return self._send(telegram, chat_id, text, reply_markup)
        data = {
            "chat_id": str(chat_id),
            "message_id": str(message_id),
            "text": chunks[0],
            "reply_markup": json.dumps(
                reply_markup or {"inline_keyboard": []}, ensure_ascii=False
            ),
        }
        try:
            return self._telegram_api(telegram, "editMessageText", data)
        except Exception as exc:
            detail = self.guard.compact_error(exc)
            if "message is not modified" in detail.lower():
                return None
            self.guard.LOGGER.warning("Telegram 消息编辑失败，改为发送新消息: %s", detail)
            return self._send(telegram, chat_id, text, reply_markup)

    def _display(self, telegram, chat_id, text, reply_markup=None, message_id=None):
        if message_id is not None:
            return self._edit(
                telegram, chat_id, message_id, text, reply_markup=reply_markup
            )
        return self._send(telegram, chat_id, text, reply_markup)

    def _edit_callback(self, telegram, callback, text, reply_markup=None):
        chat_id, message_id = self._callback_message_ref(callback)
        if chat_id is None:
            return None
        return self._edit(
            telegram, chat_id, message_id, text, reply_markup=reply_markup
        )

    def _answer_callback(self, telegram, callback_id, text="", alert=False):
        data = {
            "callback_query_id": str(callback_id),
            "text": str(text or "")[:190],
            "show_alert": "true" if alert else "false",
        }
        try:
            self._telegram_api(telegram, "answerCallbackQuery", data)
        except Exception as exc:
            self.guard.LOGGER.warning("Telegram 回调确认失败: %s", self.guard.compact_error(exc))

    def _close_menu(self, telegram, callback):
        chat_id, message_id = self._callback_message_ref(callback)
        if chat_id is None:
            return None
        try:
            return self._telegram_api(
                telegram,
                "deleteMessage",
                {"chat_id": str(chat_id), "message_id": str(message_id)},
            )
        except Exception as exc:
            self.guard.LOGGER.warning(
                "Telegram 菜单删除失败，改为收起按钮: %s",
                self.guard.compact_error(exc),
            )
            return self._edit(
                telegram,
                chat_id,
                message_id,
                "Aliyun Guard Bot 菜单已关闭。\n\n发送 /help 可重新打开菜单。",
            )

    @staticmethod
    def _menu_markup():
        return {
            "inline_keyboard": [
                [
                    {"text": "📊 状态", "callback_data": "ag:status"},
                    {"text": "🖥 实例", "callback_data": "ag:instances"},
                ],
                [{"text": "🔍 立即检测", "callback_data": "ag:req:check"}],
                [
                    {"text": "▶ 实例开机", "callback_data": "ag:list:start"},
                    {"text": "⏹ 实例关机", "callback_data": "ag:list:stop"},
                ],
                [{"text": "🕒 定时计划", "callback_data": "ag:schedule"}],
                [{"text": "✖ 关闭菜单", "callback_data": "ag:close"}],
            ]
        }

    @staticmethod
    def _main_text():
        return (
            "Aliyun Guard Bot 控制\n\n"
            "/status - 查看最近检测状态\n"
            "/instances - 查看监控实例\n"
            "/check - 立即执行一轮检测\n"
            "/poweron <序号或实例ID> - 开机\n"
            "/poweroff <序号或实例ID> - 关机\n"
            "/schedule [序号或实例ID] - 定时计划\n"
            "/help - 显示控制菜单\n\n"
            "检测和关机需要确认；关机状态开机需要连续确认两次。"
        )

    @staticmethod
    def _view_markup(refresh_data):
        return {
            "inline_keyboard": [
                [
                    {"text": "刷新", "callback_data": refresh_data},
                    {"text": "返回主菜单", "callback_data": "ag:menu"},
                ]
            ]
        }

    def _send_help(self, telegram, chat_id, message_id=None):
        self._display(
            telegram,
            chat_id,
            self._main_text(),
            self._menu_markup(),
            message_id=message_id,
        )

    def _show_status(self, telegram, chat_id, config, message_id=None):
        self._display(
            telegram,
            chat_id,
            build_status_text(self.guard, config=config),
            self._view_markup("ag:status"),
            message_id=message_id,
        )

    def _show_instances(self, telegram, chat_id, config, message_id=None):
        self._display(
            telegram,
            chat_id,
            build_instances_text(self.guard, config=config),
            self._view_markup("ag:instances"),
            message_id=message_id,
        )

    def _instance_choices(self, telegram, chat_id, config, action, message_id=None):
        label = "开机" if action == "start" else "关机"
        rows = []
        for index, user in enumerate(config.get("users", [])):
            name = str(user.get("name") or user.get("instance_id"))[:32]
            rows.append(
                [
                    {
                        "text": "{} {}".format(label, name),
                        "callback_data": "ag:req:{}:{}".format(action, index),
                    }
                ]
            )
        if not rows:
            self._display(
                telegram,
                chat_id,
                "尚未配置监控实例。",
                self._view_markup("ag:list:{}".format(action)),
                message_id=message_id,
            )
            return
        rows.append([{"text": "返回主菜单", "callback_data": "ag:menu"}])
        self._display(
            telegram,
            chat_id,
            "请选择需要{}的实例：".format(label),
            {"inline_keyboard": rows},
            message_id=message_id,
        )

    def _schedule_choices(self, telegram, chat_id, config, message_id=None):
        rows = []
        for index, user in enumerate(config.get("users", [])):
            schedule = self.guard.get_schedule_config(user)
            name = str(user.get("name") or user.get("instance_id"))[:24]
            suffix = (
                "{}-{}".format(schedule["start_time"], schedule["stop_time"])
                if schedule["enabled"]
                else "已关闭"
            )
            rows.append(
                [
                    {
                        "text": "{} · {}".format(name, suffix),
                        "callback_data": "ag:sched:view:{}".format(index),
                    }
                ]
            )
        rows.append([{"text": "返回主菜单", "callback_data": "ag:menu"}])
        text = "请选择需要管理定时计划的实例："
        if not config.get("users", []):
            text = "尚未配置监控实例。"
        self._display(
            telegram,
            chat_id,
            text,
            {"inline_keyboard": rows},
            message_id=message_id,
        )

    def _schedule_detail(self, telegram, chat_id, config, index, message_id=None):
        users = config.get("users", [])
        if index < 0 or index >= len(users):
            self._display(
                telegram,
                chat_id,
                "实例不存在或配置已经变化。",
                self._view_markup("ag:schedule"),
                message_id=message_id,
            )
            return
        user = users[index]
        schedule = self.guard.get_schedule_config(user)
        toggle_label = "关闭计划" if schedule["enabled"] else "启用计划"
        markup = {
            "inline_keyboard": [
                [
                    {
                        "text": "修改时间",
                        "callback_data": "ag:sched:edit:{}".format(index),
                    },
                    {
                        "text": toggle_label,
                        "callback_data": "ag:sched:ask:{}".format(index),
                    },
                ],
                [
                    {
                        "text": "刷新",
                        "callback_data": "ag:sched:view:{}".format(index),
                    },
                    {"text": "返回实例列表", "callback_data": "ag:schedule"},
                ],
                [{"text": "返回主菜单", "callback_data": "ag:menu"}],
            ]
        }
        self._display(
            telegram,
            chat_id,
            build_schedule_text(self.guard, user),
            markup,
            message_id=message_id,
        )

    def _new_confirmation(
        self,
        telegram,
        chat_id,
        user_id,
        action,
        instance_id=None,
        stage=1,
        threshold_override=False,
        traffic_gb=None,
        limit_gb=None,
        message_id=None,
    ):
        self._expire_pending()
        self.pending = {
            token: item
            for token, item in self.pending.items()
            if item.get("user_id") != int(user_id)
        }
        token = secrets.token_urlsafe(9)
        self.pending[token] = {
            "user_id": int(user_id),
            "chat_id": int(chat_id),
            "action": action,
            "instance_id": instance_id,
            "stage": int(stage),
            "threshold_override": bool(threshold_override),
            "message_id": message_id,
            "expires": time.monotonic() + CONFIRM_TTL_SECONDS,
        }
        if action == "check":
            text = "确认立即执行一轮真实检测？检测可能根据当前规则执行开关机。"
        else:
            config = self.guard.load_config()
            user = next(
                (
                    item
                    for item in config.get("users", [])
                    if str(item.get("instance_id", "")) == str(instance_id)
                ),
                None,
            )
            if user is None:
                self.pending.pop(token, None)
                self._display(
                    telegram,
                    chat_id,
                    "实例不存在或配置已经变化。",
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            label = "开机" if action == "start" else "关机"
            if action == "start" and int(stage) == 1:
                text = "第一次确认：准备{}实例 {}（{}）？".format(
                    label,
                    user.get("name") or instance_id,
                    instance_id,
                )
            elif action == "start" and threshold_override:
                text = (
                    "第二次确认：当前 CDT 流量 {:.2f} GB 已达到 {:.2f} GB 阈值。\n"
                    "继续将强制开机，并自动暂停该实例监控。"
                ).format(float(traffic_gb), float(limit_gb))
            elif action == "start":
                text = "第二次确认：实例当前已关机，确认执行开机？"
            else:
                text = "确认{}实例 {}（{}）？".format(
                    label,
                    user.get("name") or instance_id,
                    instance_id,
                )
        markup = {
            "inline_keyboard": [
                [
                    {"text": "确认执行", "callback_data": "ag:confirm:{}".format(token)},
                    {"text": "取消", "callback_data": "ag:cancel:{}".format(token)},
                ]
            ]
        }
        self._display(
            telegram,
            chat_id,
            text,
            markup,
            message_id=message_id,
        )

    def _expire_pending(self):
        now = time.monotonic()
        self.pending = {
            token: item
            for token, item in self.pending.items()
            if float(item.get("expires", 0)) > now
        }

    def _prompt_schedule_input(
        self, telegram, chat_id, user_id, config, index, message_id
    ):
        users = config.get("users", [])
        if index < 0 or index >= len(users):
            self._display(
                telegram,
                chat_id,
                "实例不存在或配置已经变化。",
                self._view_markup("ag:schedule"),
                message_id=message_id,
            )
            return
        user = users[index]
        schedule = self.guard.get_schedule_config(user)
        self.schedule_inputs[int(user_id)] = {
            "chat_id": int(chat_id),
            "message_id": int(message_id),
            "instance_id": str(user.get("instance_id", "")),
            "expires": time.monotonic() + SCHEDULE_INPUT_TTL_SECONDS,
        }
        text = (
            "修改定时计划\n\n"
            "实例: {} ({})\n"
            "当前时间: {} 开机，{} 关机\n\n"
            "请发送新的开机和关机时间：\n"
            "格式: HH:MM HH:MM\n"
            "示例: 08:30 23:15\n\n"
            "输入有效期 5 分钟。"
        ).format(
            user.get("name") or user.get("instance_id"),
            user.get("instance_id", ""),
            schedule["start_time"],
            schedule["stop_time"],
        )
        self._display(
            telegram,
            chat_id,
            text,
            {
                "inline_keyboard": [
                    [
                        {
                            "text": "取消修改",
                            "callback_data": "ag:sched:view:{}".format(index),
                        }
                    ]
                ]
            },
            message_id=message_id,
        )

    def _handle_schedule_input(self, telegram, user_id, chat_id, text):
        pending = self.schedule_inputs.get(int(user_id))
        if pending is None or pending.get("chat_id") != int(chat_id):
            return False
        if float(pending.get("expires", 0)) <= time.monotonic():
            self.schedule_inputs.pop(int(user_id), None)
            self._display(
                telegram,
                chat_id,
                "时间输入已过期，请重新进入定时计划修改。",
                self._view_markup("ag:schedule"),
                message_id=pending.get("message_id"),
            )
            return True
        if text.startswith("/") and text.lower() != "/cancel":
            self.schedule_inputs.pop(int(user_id), None)
            return False
        message_id = pending.get("message_id")
        instance_id = str(pending.get("instance_id", ""))
        if text.lower() == "/cancel":
            self.schedule_inputs.pop(int(user_id), None)
            config = self.guard.load_config()
            index = next(
                (
                    index
                    for index, user in enumerate(config.get("users", []))
                    if str(user.get("instance_id", "")) == instance_id
                ),
                -1,
            )
            self._schedule_detail(
                telegram, chat_id, config, index, message_id=message_id
            )
            return True
        try:
            parts = text.replace(",", " ").split()
            if len(parts) != 2:
                raise self.guard.GuardError("请同时输入开机时间和关机时间")
            start_time = self.guard.normalize_schedule_time(parts[0], "开机时间")
            stop_time = self.guard.normalize_schedule_time(parts[1], "关机时间")
            if start_time == stop_time:
                raise self.guard.GuardError("开机时间和关机时间不能相同")
            with self.guard.cycle_lock() as locked:
                if not locked:
                    raise self.guard.GuardError("检测任务正在运行，请稍后重新输入")
                config = self.guard.load_config()
                index = next(
                    (
                        index
                        for index, user in enumerate(config.get("users", []))
                        if str(user.get("instance_id", "")) == instance_id
                    ),
                    None,
                )
                if index is None:
                    raise self.guard.GuardError("实例不存在或配置已经变化")
                user = config["users"][index]
                schedule = self.guard.get_schedule_config(user)
                user["schedule"] = {
                    "enabled": bool(schedule["enabled"]),
                    "start_time": start_time,
                    "stop_time": stop_time,
                }
                self.guard.validate_config(config)
                self.guard.atomic_write_json(self.guard.CONFIG_FILE, config, mode=0o600)
            self.schedule_inputs.pop(int(user_id), None)
            self.guard.LOGGER.info(
                "Telegram 管理员 %s 修改实例 %s 定时计划为 %s-%s",
                user_id,
                instance_id,
                start_time,
                stop_time,
            )
            self._schedule_detail(
                telegram, chat_id, config, index, message_id=message_id
            )
        except Exception as exc:
            detail = self.guard.compact_error(exc)
            self._display(
                telegram,
                chat_id,
                "定时计划保存失败: {}\n\n请重新发送，例如：08:30 23:15".format(
                    detail
                ),
                {
                    "inline_keyboard": [
                        [{"text": "取消修改", "callback_data": "ag:schedule"}]
                    ]
                },
                message_id=message_id,
            )
        return True

    def _confirm_schedule_toggle(
        self, telegram, chat_id, config, index, message_id=None
    ):
        users = config.get("users", [])
        if index < 0 or index >= len(users):
            self._schedule_choices(
                telegram, chat_id, config, message_id=message_id
            )
            return
        user = users[index]
        schedule = self.guard.get_schedule_config(user)
        enabled = not schedule["enabled"]
        action = "启用" if enabled else "关闭"
        effect = (
            "启用后，后台会在 1 分钟内按当前时段执行计划。"
            if enabled
            else "关闭后不会立即改变实例当前状态。"
        )
        text = (
            "确认{}定时计划？\n\n"
            "实例: {} ({})\n"
            "每日开机: {}\n"
            "每日关机: {}\n\n{}"
        ).format(
            action,
            user.get("name") or user.get("instance_id"),
            user.get("instance_id", ""),
            schedule["start_time"],
            schedule["stop_time"],
            effect,
        )
        self._display(
            telegram,
            chat_id,
            text,
            {
                "inline_keyboard": [
                    [
                        {
                            "text": "确认{}".format(action),
                            "callback_data": "ag:sched:set:{}:{}".format(
                                index, 1 if enabled else 0
                            ),
                        },
                        {
                            "text": "取消",
                            "callback_data": "ag:sched:view:{}".format(index),
                        },
                    ]
                ]
            },
            message_id=message_id,
        )

    def _set_schedule_enabled(
        self, telegram, chat_id, user_id, index, enabled, message_id=None
    ):
        with self.guard.cycle_lock() as locked:
            if not locked:
                raise self.guard.GuardError("检测任务正在运行，请稍后再试")
            config = self.guard.load_config()
            users = config.get("users", [])
            if index < 0 or index >= len(users):
                raise self.guard.GuardError("实例不存在或配置已经变化")
            user = users[index]
            schedule = self.guard.get_schedule_config(user)
            user["schedule"] = {
                "enabled": bool(enabled),
                "start_time": schedule["start_time"],
                "stop_time": schedule["stop_time"],
            }
            self.guard.validate_config(config)
            self.guard.atomic_write_json(self.guard.CONFIG_FILE, config, mode=0o600)
        self.guard.LOGGER.info(
            "Telegram 管理员 %s %s实例 %s 定时计划",
            user_id,
            "启用" if enabled else "关闭",
            user.get("instance_id", ""),
        )
        self._schedule_detail(
            telegram, chat_id, config, index, message_id=message_id
        )

    def _authorized(self, telegram, admins, source, callback_id=None):
        user_id = source.get("from", {}).get("id")
        chat = source.get("chat")
        if chat is None:
            chat = source.get("message", {}).get("chat", {})
        chat_id = chat.get("id")
        if chat.get("type") != "private":
            self.guard.LOGGER.warning("Telegram Bot 控制忽略非私聊命令: %s", chat_id)
            if callback_id:
                self._answer_callback(telegram, callback_id, "仅支持私聊", alert=True)
            return None
        if user_id not in admins:
            self.guard.LOGGER.warning("Telegram Bot 控制拒绝未授权用户: %s", user_id)
            if callback_id:
                self._answer_callback(telegram, callback_id, "无权限", alert=True)
            elif chat_id is not None:
                self._send(telegram, chat_id, "无权限。")
            return None
        return int(user_id), int(chat_id)

    def _handle_message(self, config, telegram, admins, message):
        auth = self._authorized(telegram, admins, message)
        if auth is None:
            return
        user_id, chat_id = auth
        text = str(message.get("text", "") or "").strip()
        if self._handle_schedule_input(telegram, user_id, chat_id, text):
            return
        if not text.startswith("/"):
            self._send_help(telegram, chat_id)
            return
        parts = text.split()
        command = parts[0].split("@", 1)[0].lower()
        argument = " ".join(parts[1:]).strip()
        if command in ("/start", "/help", "/menu"):
            self._send_help(telegram, chat_id)
        elif command == "/status":
            self._show_status(telegram, chat_id, config)
        elif command in ("/instances", "/list"):
            self._show_instances(telegram, chat_id, config)
        elif command == "/check":
            self._new_confirmation(telegram, chat_id, user_id, "check")
        elif command in ("/schedule", "/plan"):
            if not argument:
                self._schedule_choices(telegram, chat_id, config)
                return
            user = resolve_instance(config, argument)
            if user is None:
                self._send(
                    telegram,
                    chat_id,
                    "实例不存在，请使用 /instances 查看序号。",
                    self._view_markup("ag:schedule"),
                )
                return
            index = config.get("users", []).index(user)
            self._schedule_detail(telegram, chat_id, config, index)
        elif command in ("/poweron", "/on", "/poweroff", "/off"):
            action = "start" if command in ("/poweron", "/on") else "stop"
            if not argument:
                self._instance_choices(telegram, chat_id, config, action)
                return
            user = resolve_instance(config, argument)
            if user is None:
                self._send(telegram, chat_id, "实例不存在，请使用 /instances 查看序号。")
                return
            self._new_confirmation(
                telegram,
                chat_id,
                user_id,
                action,
                str(user.get("instance_id", "")),
            )
        else:
            self._send_help(telegram, chat_id)

    def _execute_pending(self, telegram, pending):
        chat_id = pending["chat_id"]
        user_id = pending["user_id"]
        action = pending["action"]
        message_id = pending.get("message_id")
        if action == "check":
            self._display(
                telegram,
                chat_id,
                "正在执行检测，请稍候。",
                message_id=message_id,
            )
            with self.guard.cycle_lock() as locked:
                if not locked:
                    self._display(
                        telegram,
                        chat_id,
                        "已有检测任务正在运行，请稍后再试。",
                        self._menu_markup(),
                        message_id=message_id,
                    )
                    return
                code = self.guard.run_cycle(no_notify=True)
                summary = str(self.guard.load_state().get("last_summary", "") or "")
            self._display(
                telegram,
                chat_id,
                summary or "检测已完成，返回状态码 {}。".format(code),
                self._menu_markup(),
                message_id=message_id,
            )
            self.guard.LOGGER.info("Telegram 管理员 %s 执行了一轮检测", user_id)
            return

        if action == "start" and int(pending.get("stage", 1)) == 1:
            self._prepare_second_start_confirmation(telegram, pending)
            return

        config = self.guard.load_config()
        instance_id = str(pending.get("instance_id", ""))
        index = next(
            (
                index
                for index, user in enumerate(config.get("users", []))
                if str(user.get("instance_id", "")) == instance_id
            ),
            None,
        )
        if index is None:
            self._display(
                telegram,
                chat_id,
                "实例不存在或配置已经变化。",
                self._menu_markup(),
                message_id=message_id,
            )
            return
        import web_panel

        self.guard.LOGGER.info(
            "Telegram 管理员 %s 请求%s实例 %s",
            user_id,
            "启动" if action == "start" else "停止",
            instance_id,
        )
        self._display(
            telegram,
            chat_id,
            "正在{}实例 {}，请稍候。".format(
                "启动" if action == "start" else "停止", instance_id
            ),
            message_id=message_id,
        )
        result = web_panel.control_instance(
            self.guard,
            index,
            action,
            source="Telegram Bot",
            notify=False,
            allow_threshold_override=bool(pending.get("threshold_override", False)),
            pause_on_threshold_override=True,
        )
        self._display(
            telegram,
            chat_id,
            result["message"],
            self._menu_markup(),
            message_id=message_id,
        )

    def _prepare_second_start_confirmation(self, telegram, pending):
        chat_id = pending["chat_id"]
        user_id = pending["user_id"]
        instance_id = str(pending.get("instance_id", ""))
        message_id = pending.get("message_id")
        with self.guard.cycle_lock() as locked:
            if not locked:
                self._display(
                    telegram,
                    chat_id,
                    "已有检测任务正在运行，请稍后重新操作。",
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            config = self.guard.load_config()
            user = next(
                (
                    item
                    for item in config.get("users", [])
                    if str(item.get("instance_id", "")) == instance_id
                ),
                None,
            )
            if user is None:
                self._display(
                    telegram,
                    chat_id,
                    "实例不存在或配置已经变化。",
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            status = self.guard.query_instance_status(user)
            if status == "Running":
                self._display(
                    telegram,
                    chat_id,
                    "实例已经处于运行状态，无需开机。",
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            if status != "Stopped":
                self._display(
                    telegram,
                    chat_id,
                    "实例当前状态为 {}，暂不执行开机。".format(status),
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            traffic = self.guard.query_cdt_traffic_gb(user)
            limit = float(user.get("traffic_limit_gb", 0) or 0)
        self._new_confirmation(
            telegram,
            chat_id,
            user_id,
            "start",
            instance_id,
            stage=2,
            threshold_override=traffic >= limit,
            traffic_gb=traffic,
            limit_gb=limit,
            message_id=message_id,
        )

    def _handle_callback(self, config, telegram, admins, callback):
        callback_id = callback.get("id")
        auth = self._authorized(telegram, admins, callback, callback_id=callback_id)
        if auth is None:
            return
        user_id, chat_id = auth
        _callback_chat_id, message_id = self._callback_message_ref(callback)
        data = str(callback.get("data", "") or "")
        self.schedule_inputs.pop(int(user_id), None)
        if not data.startswith(("ag:confirm:", "ag:cancel:")):
            self.pending = {
                token: item
                for token, item in self.pending.items()
                if item.get("user_id") != int(user_id)
            }
        if data == "ag:menu":
            self._answer_callback(telegram, callback_id)
            self._send_help(telegram, chat_id, message_id=message_id)
            return
        if data == "ag:close":
            self._answer_callback(telegram, callback_id, "菜单已关闭")
            self._close_menu(telegram, callback)
            return
        if data == "ag:status":
            self._answer_callback(telegram, callback_id)
            self._show_status(telegram, chat_id, config, message_id=message_id)
            return
        if data == "ag:instances":
            self._answer_callback(telegram, callback_id)
            self._show_instances(telegram, chat_id, config, message_id=message_id)
            return
        if data == "ag:schedule":
            self._answer_callback(telegram, callback_id)
            self._schedule_choices(telegram, chat_id, config, message_id=message_id)
            return
        if data.startswith("ag:sched:view:"):
            try:
                index = int(data.rsplit(":", 1)[-1])
            except ValueError:
                self._answer_callback(telegram, callback_id, "实例序号无效", alert=True)
                return
            self._answer_callback(telegram, callback_id)
            self._schedule_detail(
                telegram, chat_id, config, index, message_id=message_id
            )
            return
        if data.startswith("ag:sched:edit:"):
            try:
                index = int(data.rsplit(":", 1)[-1])
            except ValueError:
                self._answer_callback(telegram, callback_id, "实例序号无效", alert=True)
                return
            self._answer_callback(telegram, callback_id)
            self._prompt_schedule_input(
                telegram, chat_id, user_id, config, index, message_id
            )
            return
        if data.startswith("ag:sched:ask:"):
            try:
                index = int(data.rsplit(":", 1)[-1])
            except ValueError:
                self._answer_callback(telegram, callback_id, "实例序号无效", alert=True)
                return
            self._answer_callback(telegram, callback_id)
            self._confirm_schedule_toggle(
                telegram, chat_id, config, index, message_id=message_id
            )
            return
        if data.startswith("ag:sched:set:"):
            parts = data.split(":")
            if len(parts) != 5 or parts[4] not in ("0", "1"):
                self._answer_callback(telegram, callback_id, "计划操作无效", alert=True)
                return
            try:
                index = int(parts[3])
            except ValueError:
                self._answer_callback(telegram, callback_id, "实例序号无效", alert=True)
                return
            self._answer_callback(telegram, callback_id, "正在保存")
            try:
                self._set_schedule_enabled(
                    telegram,
                    chat_id,
                    user_id,
                    index,
                    parts[4] == "1",
                    message_id=message_id,
                )
            except Exception as exc:
                detail = self.guard.compact_error(exc)
                self._display(
                    telegram,
                    chat_id,
                    "定时计划保存失败: {}".format(detail),
                    self._view_markup("ag:schedule"),
                    message_id=message_id,
                )
            return
        if data == "ag:req:check":
            self._answer_callback(telegram, callback_id)
            self._new_confirmation(
                telegram,
                chat_id,
                user_id,
                "check",
                message_id=message_id,
            )
            return
        if data.startswith("ag:list:"):
            action = data.rsplit(":", 1)[-1]
            self._answer_callback(telegram, callback_id)
            if action in ("start", "stop"):
                self._instance_choices(
                    telegram, chat_id, config, action, message_id=message_id
                )
            return
        if data.startswith("ag:req:"):
            parts = data.split(":", 3)
            self._answer_callback(telegram, callback_id)
            if len(parts) == 4 and parts[2] in ("start", "stop"):
                try:
                    index = int(parts[3])
                    if index < 0:
                        raise IndexError
                    user = config.get("users", [])[index]
                except (IndexError, TypeError, ValueError):
                    self._display(
                        telegram,
                        chat_id,
                        "实例不存在或配置已经变化。",
                        self._menu_markup(),
                        message_id=message_id,
                    )
                    return
                self._new_confirmation(
                    telegram,
                    chat_id,
                    user_id,
                    parts[2],
                    str(user.get("instance_id", "")),
                    message_id=message_id,
                )
            return
        if data.startswith("ag:cancel:"):
            token = data.split(":", 2)[-1]
            pending = self.pending.get(token)
            if pending and pending.get("user_id") == user_id:
                self.pending.pop(token, None)
                self._answer_callback(telegram, callback_id, "已取消")
                self._send_help(telegram, chat_id, message_id=message_id)
            else:
                self._answer_callback(telegram, callback_id, "操作已失效", alert=True)
            return
        if data.startswith("ag:confirm:"):
            token = data.split(":", 2)[-1]
            self._expire_pending()
            pending = self.pending.get(token)
            if (
                pending is None
                or pending.get("user_id") != user_id
                or pending.get("chat_id") != chat_id
            ):
                self._answer_callback(telegram, callback_id, "确认已过期或无效", alert=True)
                return
            self.pending.pop(token, None)
            pending["message_id"] = message_id
            self._answer_callback(telegram, callback_id, "正在执行")
            try:
                self._execute_pending(telegram, pending)
            except Exception as exc:
                detail = self.guard.compact_error(
                    exc, secrets=self.guard.telegram_secrets(telegram)
                )
                self.guard.LOGGER.exception("Telegram Bot 控制执行失败: %s", detail)
                self._display(
                    telegram,
                    chat_id,
                    "操作失败: {}".format(detail),
                    self._menu_markup(),
                    message_id=message_id,
                )
            return
        self._answer_callback(telegram, callback_id, "按钮无效", alert=True)

    def _handle_update(self, config, telegram, admins, update):
        if isinstance(update.get("message"), dict):
            self._handle_message(config, telegram, admins, update["message"])
        elif isinstance(update.get("callback_query"), dict):
            self._handle_callback(config, telegram, admins, update["callback_query"])

    def _prepare_token(self, telegram):
        fingerprint = _token_fingerprint(telegram.get("bot_token"))
        token_changed = fingerprint != self.fingerprint
        if (
            not token_changed
            and self.offset is not None
            and not self.drain_pending
        ):
            return
        if token_changed:
            self.drain_pending = True
        self.fingerprint = fingerprint
        self.offset = None if self.drain_pending else _load_offset(self.guard, fingerprint)
        if self.offset is None:
            updates = self._telegram_api(
                telegram,
                "getUpdates",
                {
                    "offset": -1,
                    "limit": 1,
                    "timeout": 0,
                    "allowed_updates": json.dumps(["message", "callback_query"]),
                },
            ) or []
            self.offset = (
                max(int(item.get("update_id", -1)) for item in updates) + 1
                if updates
                else 0
            )
            _save_offset(self.guard, fingerprint, self.offset)
            self.guard.LOGGER.info("Telegram Bot 控制已丢弃启用前的待处理消息")
        self.drain_pending = False
        if self.commands_fingerprint != fingerprint:
            try:
                self._telegram_api(
                    telegram,
                    "setMyCommands",
                    {
                        "commands": json.dumps(BOT_COMMANDS, ensure_ascii=False),
                        "scope": json.dumps({"type": "all_private_chats"}),
                    },
                )
            except Exception as exc:
                self.guard.LOGGER.warning(
                    "Telegram Bot 命令菜单注册失败，文本命令仍可使用: %s",
                    self.guard.compact_error(exc),
                )
            self.commands_fingerprint = fingerprint

    def _run(self):
        while not self.stop_event.is_set():
            try:
                config, telegram, admins = self._poll_config()
                if telegram is None:
                    self.stop_event.wait(RETRY_WAIT_SECONDS)
                    continue
                self._prepare_token(telegram)
                updates = self._telegram_api(
                    telegram,
                    "getUpdates",
                    {
                        "offset": self.offset,
                        "limit": 100,
                        "timeout": POLL_TIMEOUT_SECONDS,
                        "allowed_updates": json.dumps(["message", "callback_query"]),
                    },
                    long_poll=True,
                ) or []
                if updates:
                    self.offset = max(
                        int(item.get("update_id", -1)) for item in updates
                    ) + 1
                    _save_offset(self.guard, self.fingerprint, self.offset)
                    latest_config, latest_telegram, latest_admins = self._poll_config()
                    if latest_telegram is None:
                        continue
                    if _token_fingerprint(latest_telegram.get("bot_token")) != self.fingerprint:
                        self.drain_pending = True
                        continue
                    for update in updates:
                        try:
                            self._handle_update(
                                latest_config,
                                latest_telegram,
                                latest_admins,
                                update,
                            )
                        except Exception as exc:
                            self.guard.LOGGER.exception(
                                "Telegram Bot 单条更新处理失败: %s",
                                self.guard.compact_error(
                                    exc,
                                    secrets=self.guard.telegram_secrets(latest_telegram),
                                ),
                            )
                if self.last_error is not None:
                    self.guard.LOGGER.info("Telegram Bot 控制连接已恢复")
                    self.last_error = None
            except Exception as exc:
                detail = self.guard.compact_error(exc)
                if detail != self.last_error:
                    self.guard.LOGGER.warning("Telegram Bot 控制轮询失败: %s", detail)
                    self.last_error = detail
                self.stop_event.wait(RETRY_WAIT_SECONDS)


def start_background(guard):
    return TelegramControlService(guard).start()
__AG_CONTROL_PY_EOF__
    cat > "$APP_DIR/web_actions.py" <<'__AG_WEB_ACTIONS_PY_EOF__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Management operations exposed by the authenticated web panel."""

import copy
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

import telegram_proxy
import backup_manager
import s3_backup


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
DATA_DIR = Path(
    os.environ.get("ALIYUN_GUARD_CONFIG", APP_DIR / "config.json")
).parent
UPDATE_LOG_NAME = "web-update.log"
UPDATE_STATE_NAME = "web-update-state.json"
UPDATE_EXIT_MARKER = "__AG_UPDATE_EXIT_CODE="

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
            "watchdog": {
                "enabled": bool(config.get("watchdog", {}).get("enabled", True)),
                "timeout_seconds": int(
                    config.get("watchdog", {}).get("timeout_seconds", 600)
                ),
                "failure_threshold": int(
                    config.get("watchdog", {}).get("failure_threshold", 2)
                ),
            },
        },
        "web": {
            "enabled": bool(web.get("enabled", False)),
            "host": str(web.get("host", "127.0.0.1")),
            "port": int(web.get("port", 8765)),
            "username": str(web.get("username", "admin")),
            "password_configured": bool(str(web.get("password_hash", "")).strip()),
        },
        "backend": backend,
        "s3_backup": s3_backup_payload(config.get("s3_backup", {})),
        "rollback_snapshots": [
            {
                "name": path.name,
                "size": path.stat().st_size,
                "modified_at": int(path.stat().st_mtime),
            }
            for path in backup_manager.list_program_snapshots(app_dir=APP_DIR)
        ],
    }


def s3_backup_payload(value):
    config = s3_backup.normalized_config(value)
    status = s3_backup.read_status(DATA_DIR)
    return {
        "enabled": bool(config.get("enabled", False)),
        "bucket": config["bucket"],
        "region": config["region"],
        "endpoint_url": config["endpoint_url"],
        "prefix": config["prefix"],
        "addressing_style": config["addressing_style"],
        "access_key_configured": bool(config["access_key_id"]),
        "uses_iam_role": not bool(config["access_key_id"]),
        "session_token_configured": bool(config["session_token"]),
        "backup_password_configured": bool(config["backup_password"]),
        "schedule": config["schedule"],
        "time": config["time"],
        "weekday": int(config["weekday"]),
        "retention": int(config["retention"]),
        "include_state": bool(config["include_state"]),
        "include_logs": bool(config["include_logs"]),
        "notification_mode": config["notification_mode"],
        "server_side_encryption": config["server_side_encryption"],
        "kms_key_configured": bool(config["kms_key_id"]),
        "status": {
            "last_attempt_at": status.get("last_attempt_at"),
            "last_success_at": status.get("last_success_at"),
            "last_key": status.get("last_key"),
            "last_error": status.get("last_error"),
        },
    }


def _s3_candidate(guard, data, save=False):
    if not isinstance(data, dict):
        raise ManagementError("S3 配置必须是对象")
    config = guard.load_config()
    current = s3_backup.normalized_config(config.get("s3_backup", {}))
    candidate = dict(current)
    for field in (
        "bucket",
        "region",
        "endpoint_url",
        "prefix",
        "schedule",
        "time",
        "notification_mode",
        "server_side_encryption",
        "addressing_style",
    ):
        if field in data:
            candidate[field] = str(data.get(field, "") or "").strip()
    for field in ("enabled", "include_state", "include_logs"):
        if field in data:
            candidate[field] = _boolean(data, field, candidate[field])
    candidate["weekday"] = _integer(
        data, "weekday", candidate["weekday"], 0, 6
    )
    candidate["retention"] = _integer(
        data, "retention", candidate["retention"], 1, 365
    )
    use_iam_role = _boolean(
        data, "use_iam_role", not bool(current["access_key_id"])
    )
    if use_iam_role:
        candidate["access_key_id"] = ""
        candidate["secret_access_key"] = ""
        candidate["session_token"] = ""
    else:
        for field in ("access_key_id", "secret_access_key", "session_token"):
            entered = str(data.get(field, "") or "").strip()
            if entered:
                candidate[field] = entered
        if _boolean(data, "clear_session_token", False):
            candidate["session_token"] = ""
        if (
            (candidate["enabled"] or not save)
            and (not candidate["access_key_id"] or not candidate["secret_access_key"])
        ):
            raise ManagementError("未使用 IAM Role 时必须填写 S3 Access Key 和 Secret")
    entered_password = str(data.get("backup_password", "") or "").strip()
    if entered_password:
        candidate["backup_password"] = entered_password
    entered_kms = str(data.get("kms_key_id", "") or "").strip()
    if entered_kms:
        candidate["kms_key_id"] = entered_kms
    elif candidate.get("server_side_encryption") != "aws:kms":
        candidate["kms_key_id"] = ""
    try:
        candidate = s3_backup.validate_config(
            candidate, require_ready=bool(candidate.get("enabled")) or not save
        )
    except s3_backup.S3BackupError as exc:
        raise ManagementError(str(exc))
    if save:
        config["s3_backup"] = candidate
        _save_config(guard, config)
    return candidate


def save_s3_backup_settings(guard, data):
    candidate = _s3_candidate(guard, data, save=True)
    return s3_backup_payload(candidate)


def test_s3_backup_settings(guard, data):
    candidate = _s3_candidate(guard, data, save=False)
    try:
        return s3_backup.test_connection(candidate)
    except s3_backup.S3BackupError as exc:
        raise ManagementError(
            guard.compact_error(
                exc,
                secrets=(
                    candidate["access_key_id"],
                    candidate["secret_access_key"],
                    candidate["session_token"],
                    candidate["backup_password"],
                ),
            ),
            502,
        )


def run_s3_backup_now(guard):
    config = guard.load_config()
    backup = s3_backup.normalized_config(config.get("s3_backup", {}))
    try:
        return s3_backup.create_and_upload(
            backup, DATA_DIR
        )
    except (s3_backup.S3BackupError, backup_manager.BackupError) as exc:
        raise ManagementError(
            guard.compact_error(
                exc,
                secrets=(
                    backup["access_key_id"],
                    backup["secret_access_key"],
                    backup["session_token"],
                    backup["backup_password"],
                ),
            ),
            502,
        )


def list_s3_backups(guard):
    config = guard.load_config()
    backup = s3_backup.normalized_config(config.get("s3_backup", {}))
    try:
        return s3_backup.list_backups(backup, limit=100)
    except s3_backup.S3BackupError as exc:
        raise ManagementError(
            guard.compact_error(
                exc,
                secrets=(backup["access_key_id"], backup["secret_access_key"], backup["session_token"]),
            ),
            502,
        )


def preview_s3_backup(guard, key):
    config = guard.load_config()
    backup = s3_backup.normalized_config(config.get("s3_backup", {}))
    path = None
    try:
        path = s3_backup.download_backup(backup, key, DATA_DIR)
        return backup_manager.preview_restore(
            path, backup["backup_password"], DATA_DIR
        )
    except (s3_backup.S3BackupError, backup_manager.BackupError) as exc:
        raise ManagementError(
            guard.compact_error(
                exc,
                secrets=(backup["access_key_id"], backup["secret_access_key"], backup["session_token"], backup["backup_password"]),
            ),
            502,
        )
    finally:
        if path is not None:
            path.unlink(missing_ok=True)


def restore_s3_backup(guard, key, include_logs=True):
    config = guard.load_config()
    backup = s3_backup.normalized_config(config.get("s3_backup", {}))
    path = None
    try:
        path = s3_backup.download_backup(backup, key, DATA_DIR)
        return backup_manager.restore_backup(
            path,
            backup["backup_password"],
            DATA_DIR,
            include_logs=bool(include_logs),
        )
    except (s3_backup.S3BackupError, backup_manager.BackupError) as exc:
        raise ManagementError(
            guard.compact_error(
                exc,
                secrets=(backup["access_key_id"], backup["secret_access_key"], backup["session_token"], backup["backup_password"]),
            ),
            502,
        )
    finally:
        if path is not None:
            path.unlink(missing_ok=True)


def _decode_backup(data):
    encoded = str(data.get("backup_base64", "") or "").strip()
    if not encoded:
        raise ManagementError("请选择备份文件")
    try:
        content = base64.b64decode(encoded.encode("ascii"), validate=True)
    except Exception as exc:
        raise ManagementError("备份文件编码无效") from exc
    if len(content) > backup_manager.MAX_BACKUP_FILE_BYTES:
        raise ManagementError("备份文件过大", 413)
    return content


def _backup_tempfile(content):
    directory = DATA_DIR / "backups"
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / ".web-upload-{}-{}.agbackup".format(
        os.getpid(), int(time.time() * 1000)
    )
    temporary.write_bytes(content)
    os.chmod(str(temporary), 0o600)
    return temporary


def create_encrypted_backup(data):
    password = str(data.get("password", "") or "")
    include_state = _boolean(data, "include_state", True)
    include_logs = _boolean(data, "include_logs", True)
    try:
        path = backup_manager.create_backup(
            password,
            app_dir=DATA_DIR,
            include_state=include_state,
            include_logs=include_logs,
        )
        content = path.read_bytes()
        return {
            "filename": path.name,
            "backup_base64": base64.b64encode(content).decode("ascii"),
            "size": len(content),
        }
    except backup_manager.BackupError as exc:
        raise ManagementError(str(exc))


def preview_encrypted_backup(data):
    content = _decode_backup(data)
    temporary = _backup_tempfile(content)
    try:
        return backup_manager.preview_restore(
            temporary, str(data.get("password", "") or ""), app_dir=DATA_DIR
        )
    except backup_manager.BackupError as exc:
        raise ManagementError(str(exc))
    finally:
        temporary.unlink(missing_ok=True)


def restore_encrypted_backup(data):
    content = _decode_backup(data)
    include_logs = _boolean(data, "include_logs", True)
    temporary = _backup_tempfile(content)
    try:
        return backup_manager.restore_backup(
            temporary,
            str(data.get("password", "") or ""),
            app_dir=DATA_DIR,
            include_logs=include_logs,
        )
    except backup_manager.BackupError as exc:
        raise ManagementError(str(exc))
    finally:
        temporary.unlink(missing_ok=True)


def rollback_program(snapshot_name=None):
    snapshot = None
    if snapshot_name:
        name = Path(str(snapshot_name)).name
        if name != str(snapshot_name) or not name.startswith("program-"):
            raise ManagementError("程序快照名称无效")
        snapshot = APP_DIR / "backups" / name
    try:
        return backup_manager.restore_program_snapshot(snapshot, app_dir=APP_DIR)
    except backup_manager.BackupError as exc:
        raise ManagementError(str(exc), 409)


def discover_instances(guard, data):
    if not isinstance(data, dict):
        raise ManagementError("实例发现参数无效")
    ak = _required_text(data, "ak", label="AccessKey ID")
    sk = _required_text(data, "sk", label="AccessKey Secret")
    regions = data.get("regions", [])
    if isinstance(regions, str):
        regions = [item.strip() for item in regions.replace(";", ",").split(",") if item.strip()]
    if not isinstance(regions, list):
        raise ManagementError("Region 列表格式无效")
    if not regions:
        try:
            regions = guard.discover_ecs_regions(ak, sk)
        except Exception as exc:
            raise ManagementError(
                "自动获取 Region 失败: {}".format(
                    guard.compact_error(exc, secrets=(ak, sk))
                ),
                502,
            )
    try:
        result = guard.discover_ecs_instances(
            ak,
            sk,
            regions,
            tag_key=str(data.get("tag_key", "") or "").strip(),
            tag_value=str(data.get("tag_value", "") or "").strip(),
        )
    except Exception as exc:
        raise ManagementError(
            guard.compact_error(exc, secrets=(ak, sk)), 502
        )
    existing = {
        (str(item.get("ak", "")), str(item.get("region", "")), str(item.get("instance_id", "")))
        for item in guard.load_config().get("users", [])
    }
    for item in result.get("instances", []):
        item["already_configured"] = (ak, item["region"], item["instance_id"]) in existing
    return result


def import_discovered_instances(guard, data):
    ak = _required_text(data, "ak", label="AccessKey ID")
    sk = _required_text(data, "sk", label="AccessKey Secret")
    selected = data.get("instances", [])
    if not isinstance(selected, list) or not selected:
        raise ManagementError("请选择至少一个实例")
    if len(selected) > 100:
        raise ManagementError("一次最多导入 100 个实例")
    limit = _number(data, "traffic_limit_gb", 180, 0.01)
    actions_enabled = _boolean(data, "actions_enabled", True)
    billing_site = str(data.get("billing_site", "china") or "china")
    billing = _copy(BILLING_PRESETS.get(billing_site, BILLING_PRESETS["china"]))
    config = guard.load_config()
    users = config.setdefault("users", [])
    identities = {
        (str(item.get("ak", "")), str(item.get("region", "")), str(item.get("instance_id", "")))
        for item in users
    }
    imported = []
    skipped = []
    for raw in selected:
        if not isinstance(raw, dict):
            continue
        region = str(raw.get("region", "") or "").strip()
        instance_id = str(raw.get("instance_id", "") or "").strip()
        identity = (ak, region, instance_id)
        if not region or not instance_id or identity in identities:
            skipped.append(instance_id or "无效实例")
            continue
        user = {
            "name": str(raw.get("name", "") or instance_id).strip()[:80],
            "ak": ak,
            "sk": sk,
            "region": region,
            "instance_id": instance_id,
            "traffic_limit_gb": limit,
            "actions_enabled": actions_enabled,
            "instance_log_enabled": False,
            "paused": False,
            "billing": _copy(billing),
            "schedule": _copy(guard.DEFAULT_SCHEDULE),
        }
        users.append(user)
        identities.add(identity)
        imported.append(instance_id)
    if not imported:
        raise ManagementError("所选实例均已存在或数据无效", 409)
    _save_config(guard, config)
    return {"imported": imported, "skipped": skipped, "count": len(imported)}


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
    watchdog_data = data.get("watchdog", {})
    if not isinstance(watchdog_data, dict):
        raise ManagementError("watchdog 必须是对象")
    current_watchdog = config.get("watchdog", {})
    if not isinstance(current_watchdog, dict):
        current_watchdog = {}
    config["watchdog"] = {
        "enabled": _boolean(
            watchdog_data,
            "enabled",
            bool(current_watchdog.get("enabled", True)),
        ),
        "timeout_seconds": _integer(
            watchdog_data,
            "timeout_seconds",
            current_watchdog.get("timeout_seconds", 600),
            120,
            86400,
        ),
        "failure_threshold": _integer(
            watchdog_data,
            "failure_threshold",
            current_watchdog.get("failure_threshold", 2),
            1,
            10,
        ),
    }
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


def _update_paths():
    log_dir = APP_DIR / "logs"
    return log_dir / UPDATE_LOG_NAME, log_dir / UPDATE_STATE_NAME


def _write_update_state(data):
    _log_path, state_path = _update_paths()
    state_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = state_path.with_name(state_path.name + ".tmp")
    temporary.write_text(
        json.dumps(data, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    os.chmod(temporary, 0o600)
    os.replace(str(temporary), str(state_path))


def _read_update_state():
    _log_path, state_path = _update_paths()
    try:
        data = json.loads(state_path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _prepare_update_tracking(target_version=None, backend=""):
    log_path, _state_path = _update_paths()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text("网页更新任务已启动。\n", encoding="utf-8")
    os.chmod(log_path, 0o600)
    version = str(target_version or "").strip()
    if len(version) > 32 or any(
        character not in "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+"
        for character in version
    ):
        version = ""
    state = {
        "status": "running",
        "started_at": int(time.time()),
        "target_version": version or None,
        "backend": str(backend or ""),
        "job": None,
    }
    _write_update_state(state)
    return state


def _update_log_text(limit=262144):
    log_path, _state_path = _update_paths()
    try:
        with log_path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - int(limit)), os.SEEK_SET)
            return handle.read().decode("utf-8", "replace")
    except OSError:
        return ""


def update_progress():
    state = _read_update_state()
    text = _update_log_text()
    if not state and not text:
        return {
            "status": "idle",
            "progress": 0,
            "message": "尚未启动更新",
            "target_version": None,
        }

    stages = [
        ("网页更新任务已启动", 3, "正在启动更新任务"),
        ("正在下载更新和校验文件", 12, "正在下载正式版文件"),
        ("SHA-256 校验通过", 25, "文件校验通过"),
        ("[1/6]", 35, "正在检查系统依赖"),
        ("[2/6]", 48, "正在更新 Python 环境"),
        ("[3/6]", 62, "正在写入程序文件"),
        ("[4/6]", 74, "正在恢复本机配置"),
        ("[5/6]", 86, "正在重启后台服务"),
        ("[6/6]", 95, "正在验证更新结果"),
        ("安装完成。", 98, "程序文件已安装"),
    ]
    progress = 0
    message = "等待更新进程输出"
    for marker, value, label in stages:
        if marker in text and value >= progress:
            progress = value
            message = label

    exit_code = None
    if UPDATE_EXIT_MARKER in text:
        tail = text.rsplit(UPDATE_EXIT_MARKER, 1)[-1].splitlines()[0].strip()
        try:
            exit_code = int(tail)
        except ValueError:
            exit_code = None
    success = "GitHub 最新版本已安装，后台服务已重启" in text or exit_code == 0
    started_at = int(state.get("started_at", 0) or 0)
    timed_out = bool(started_at and time.time() - started_at > 3600)
    failure = (
        state.get("status") == "error"
        or timed_out
        or exit_code not in (None, 0)
        or any(
            marker in text
            for marker in (
                "更新下载失败:",
                "执行更新失败:",
                "更新安装器退出码:",
                "错误:",
            )
        )
    )
    if success:
        status = "success"
        progress = 100
        message = "更新完成，后台服务已重新加载"
    elif failure:
        status = "error"
        message = "更新失败，请查看 web-update.log"
    else:
        status = "running"

    return {
        "status": status,
        "progress": max(0, min(100, int(progress))),
        "message": message,
        "target_version": state.get("target_version"),
        "started_at": state.get("started_at"),
        "job": state.get("job"),
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


def _update_wrapper_command(command, log_path):
    shell_command = (
        'log_path=$1; shift; "$@" >>"$log_path" 2>&1; '
        'rc=$?; printf "\\n{}%s\\n" "$rc" >>"$log_path"; exit "$rc"'
    ).format(UPDATE_EXIT_MARKER)
    return [
        "/bin/sh",
        "-c",
        shell_command,
        "aliyun-guard-update",
        str(log_path),
        *command,
    ]


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
    launcher = [
        systemd_run,
        "--quiet",
        "--no-block",
        "--property=StandardInput=null",
        "--unit={}".format(unit),
        *_update_wrapper_command(command, log_path),
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


def install_update(target_version=None):
    if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
        raise ManagementError(
            "Docker 部署请在宿主机执行 git pull && docker compose up -d --build",
            409,
        )
    manager_path = APP_DIR / "manager.py"
    if not manager_path.exists():
        raise ManagementError("更新程序不存在", 500)
    if update_progress().get("status") == "running":
        raise ManagementError("已有更新任务正在运行，请等待当前任务完成", 409)
    command = [sys.executable, "-u", str(manager_path), "update", "--yes"]
    backend_path = APP_DIR / "service_backend"
    try:
        backend = backend_path.read_text(encoding="utf-8").strip().lower()
    except OSError:
        backend = ""
    state = _prepare_update_tracking(target_version=target_version, backend=backend)
    try:
        if backend == "systemd":
            job = systemd_update_process(command, UPDATE_LOG_NAME)
        else:
            log_path, _state_path = _update_paths()
            job = detached_process(
                _update_wrapper_command(command, log_path), UPDATE_LOG_NAME
            )
        state["job"] = str(job)
        _write_update_state(state)
        return job
    except ManagementError as exc:
        state["status"] = "error"
        state["message"] = str(exc)
        _write_update_state(state)
        raise
    except Exception as exc:
        state["status"] = "error"
        state["message"] = str(exc)
        _write_update_state(state)
        raise ManagementError("启动更新失败: {}".format(exc), 500)
__AG_WEB_ACTIONS_PY_EOF__
    cat > "$APP_DIR/web_panel.py" <<'__AG_WEB_PY_EOF__'
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


APP_VERSION = "1.5.9"
APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
HTML_FILE = APP_DIR / "web_panel.html"
PID_FILE = APP_DIR / "web-panel.pid"
SUPERVISOR_LOCK_FILE = APP_DIR / "web-panel-supervisor.lock"
DISABLED_FILE = APP_DIR / "disabled"
BACKEND_FILE = APP_DIR / "service_backend"
MAX_BODY_BYTES = 128 * 1024 * 1024
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


def container_public_ipv4():
    candidate = str(os.environ.get("ALIYUN_GUARD_PUBLIC_IP", "") or "").strip()
    return candidate if _usable_ipv4(candidate) else ""


def container_public_web_port(default):
    try:
        port = int(os.environ.get("ALIYUN_GUARD_PUBLIC_WEB_PORT", default))
    except (TypeError, ValueError):
        return int(default)
    return port if 1 <= port <= 65535 else int(default)


def container_host_bind_ip():
    candidate = str(
        os.environ.get("ALIYUN_GUARD_HOST_BIND_IP", "0.0.0.0") or "0.0.0.0"
    ).strip()
    if candidate == "127.0.0.1":
        return candidate
    return candidate if _usable_ipv4(candidate) else "0.0.0.0"


def browser_access_url(web, local_ip=None):
    host = str(web.get("host", "127.0.0.1"))
    port = int(web.get("port", 8765))
    if host == "0.0.0.0":
        if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
            bind_ip = container_host_bind_ip()
            if bind_ip == "127.0.0.1":
                host = bind_ip
            elif bind_ip != "0.0.0.0":
                host = bind_ip
            else:
                host = container_public_ipv4() or "服务器公网IP"
            port = container_public_web_port(port)
        else:
            host = detect_primary_ipv4() if local_ip is None else local_ip
            host = host or "服务器IP"
    return "http://{}:{}".format(host, port)


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
                "instance_log_enabled": bool(
                    user.get("instance_log_enabled", False)
                ),
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
    if os.environ.get("ALIYUN_GUARD_CONTAINER") == "1":
        bind_ip = container_host_bind_ip()
        web["local_ip"] = (
            bind_ip if bind_ip != "0.0.0.0" else container_public_ipv4()
        )
    else:
        web["local_ip"] = detect_primary_ipv4()
    web["browser_url"] = browser_access_url(web, web["local_ip"])
    web["http_warning"] = web["host"] == "0.0.0.0"
    return payload


def _read_recent_log_path(path, limit):
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError as exc:
        raise WebPanelError("无法读取日志: {}".format(exc), 500)
    return [line.rstrip("\r\n") for line in lines[-limit:]]


def logs_payload(guard, limit=200, instance_index=None):
    try:
        limit = max(20, min(500, int(limit)))
    except (TypeError, ValueError):
        raise WebPanelError("日志行数必须是整数")
    if instance_index in (None, "", "system"):
        return {
            "lines": _read_recent_log_path(Path(guard.LOG_FILE), limit),
            "source": "system",
            "name": "系统总日志",
            "instance_id": None,
            "index": None,
            "enabled": True,
            "toggle_available": False,
        }
    try:
        index = int(instance_index)
    except (TypeError, ValueError):
        raise WebPanelError("实例日志序号无效")
    config = guard.load_config()
    users = config.get("users", [])
    if index < 0 or index >= len(users):
        raise WebPanelError("实例不存在", 404)
    user = users[index]
    return {
        "lines": _read_recent_log_path(guard.instance_log_path(user), limit),
        "source": "instance",
        "name": str(user.get("name") or user.get("instance_id")),
        "instance_id": str(user.get("instance_id", "")),
        "index": index,
        "enabled": guard.instance_log_enabled(user),
        "toggle_available": True,
    }


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


def _write_manual_instance_log(
    guard,
    user,
    action,
    before=None,
    after=None,
    traffic=None,
    performed=False,
    message="",
    errors=None,
    level="error",
    source="网页",
):
    guard.write_instance_log(
        user,
        {
            "name": str(user.get("name") or user.get("instance_id")),
            "instance_id": str(user.get("instance_id", "")),
            "traffic_gb": traffic,
            "limit_gb": float(user.get("traffic_limit_gb", 0) or 0),
            "status_before": before,
            "status_after": after or before,
            "billing_enabled": bool(
                guard.get_billing_config(user).get("enabled", True)
            ),
            "billing_checked": False,
            "action": "manual_{}".format(action),
            "action_performed": performed,
            "level": level,
            "message": message,
            "errors": list(errors or []),
        },
        event="{}手动{}".format(source, "开机" if action == "start" else "关机"),
    )


def control_instance(
    guard,
    index,
    action,
    source="网页控制台",
    notify=True,
    allow_threshold_override=False,
    pause_on_threshold_override=False,
):
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
        before = None
        after = None
        traffic = None
        performed = False
        poll_error = None
        threshold_overridden = False
        monitor_paused = False
        try:
            schedule_target = guard.schedule_target(user)
            automation_active = bool(user.get("actions_enabled", True)) and not bool(
                user.get("paused", False)
            )
            if action == "stop" and automation_active and schedule_target != "stopped":
                raise WebPanelError(
                    "自动保活当前有效，直接关机会被重新启动；请先暂停该实例监控",
                    409,
                )
            if action == "start" and automation_active and schedule_target == "stopped":
                raise WebPanelError(
                    "当前处于计划关机时段；请先暂停监控或修改定时计划", 409
                )
            before = guard.query_instance_status(user)
            if action == "start":
                traffic = guard.query_cdt_traffic_gb(user)
                limit = float(user.get("traffic_limit_gb", 0) or 0)
                if traffic >= limit:
                    if not allow_threshold_override:
                        raise WebPanelError(
                            "当前 CDT 流量 {:.2f} GB 已达到 {:.2f} GB 阈值，拒绝开机".format(
                                traffic, limit
                            ),
                            409,
                        )
                    threshold_overridden = True
                if before != "Running":
                    if threshold_overridden and pause_on_threshold_override:
                        user["paused"] = True
                        guard.validate_config(config)
                        guard.atomic_write_json(guard.CONFIG_FILE, config, mode=0o600)
                        monitor_paused = True
                    guard.start_instance(user)
                    performed = True
                    after, poll_error = guard.wait_for_status(
                        user,
                        "Running",
                        int(config.get("start_wait_seconds", 90)),
                        int(config.get("start_poll_seconds", 5)),
                    )
                else:
                    after = before
            elif before != "Stopped":
                guard.stop_instance(user)
                performed = True
                after, poll_error = guard.wait_for_status(
                    user,
                    "Stopped",
                    int(config.get("stop_wait_seconds", 45)),
                    int(config.get("start_poll_seconds", 5)),
                )
            else:
                after = before
        except WebPanelError as exc:
            message = "{}手动{}未执行: {}".format(
                source, "开机" if action == "start" else "关机", exc
            )
            _write_manual_instance_log(
                guard,
                user,
                action,
                before=before,
                after=after,
                traffic=traffic,
                performed=performed,
                message=message,
                errors=[str(exc)],
                source="网页" if source == "网页控制台" else source,
            )
            raise
        except Exception as exc:
            error = guard.compact_error(exc, secrets=secrets_to_hide)
            message = "实例{}失败: {}".format(
                "开机" if action == "start" else "关机", error
            )
            if monitor_paused:
                message += "；该实例监控已暂停，请处理后按需恢复"
            _write_manual_instance_log(
                guard,
                user,
                action,
                before=before,
                after=after,
                traffic=traffic,
                performed=performed,
                message=message,
                errors=[error],
                source="网页" if source == "网页控制台" else source,
            )
            raise WebPanelError(message, 502)

        message = "{}手动{}\n实例: {} ({})\n状态: {} -> {}".format(
            source,
            "开机" if action == "start" else "关机",
            name,
            user.get("instance_id"),
            before,
            after or "Unknown",
        )
        if poll_error:
            message += "\n状态复查: {}".format(poll_error)
        if monitor_paused:
            message += "\n监控: 已自动暂停（流量阈值强制开机）"
        notify_error = None
        if notify:
            try:
                guard.send_telegram_message(config.get("telegram", {}), message)
            except Exception as exc:
                notify_error = guard.compact_error(
                    exc, secrets=guard.telegram_secrets(config.get("telegram", {}))
                )
        log_errors = []
        if poll_error:
            log_errors.append("ECS 状态复查失败: {}".format(poll_error))
        if notify_error:
            log_errors.append("Telegram 通知失败: {}".format(notify_error))
        level = "warning" if log_errors else ("action" if performed else "ok")
        checked_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
        state = guard.load_state()
        instances = state.setdefault("instances", {})
        previous = instances.get(str(user.get("instance_id", "")), {})
        if not isinstance(previous, dict):
            previous = {}
        if traffic is None:
            traffic = previous.get("traffic_gb")
        _write_manual_instance_log(
            guard,
            user,
            action,
            before=before,
            after=after,
            traffic=traffic,
            performed=performed,
            message=message,
            errors=log_errors,
            level=level,
            source="网页" if source == "网页控制台" else source,
        )
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
            "threshold_overridden": threshold_overridden,
            "monitor_paused": monitor_paused,
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
        route = urllib.parse.urlsplit(self.path).path
        backup_upload = route in ("/api/backup/preview", "/api/backup/restore")
        maximum = MAX_BODY_BYTES if backup_upload else 1024 * 1024
        if length <= 0 or length > maximum:
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
            if parts == ["api", "update", "progress"]:
                self._json(web_actions.update_progress())
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
            if parts == ["api", "s3-backup", "list"]:
                self._json(
                    {"ok": True, "backups": web_actions.list_s3_backups(self.server.guard)}
                )
                return
            if parts == ["api", "logs"]:
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                limit = query.get("limit", ["200"])[0]
                instance_index = query.get("instance", [None])[0]
                self._json(
                    logs_payload(
                        self.server.guard,
                        limit=limit,
                        instance_index=instance_index,
                    )
                )
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
            if parts == ["api", "backup", "create"]:
                self._authenticated(require_csrf=True)
                result = web_actions.create_encrypted_backup(self._read_json())
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "s3-backup", "settings"]:
                result = web_actions.save_s3_backup_settings(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "s3_backup": result})
                return
            if parts == ["api", "s3-backup", "test"]:
                result = web_actions.test_s3_backup_settings(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "s3-backup", "run"]:
                self._read_json()
                result = web_actions.run_s3_backup_now(self.server.guard)
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "s3-backup", "preview"]:
                data = self._read_json()
                result = web_actions.preview_s3_backup(
                    self.server.guard, data.get("key")
                )
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "s3-backup", "restore"]:
                data = self._read_json()
                result = web_actions.restore_s3_backup(
                    self.server.guard,
                    data.get("key"),
                    include_logs=web_actions._boolean(data, "include_logs", True),
                )
                self.server.delayed_restart()
                self._json({"ok": True, "result": result}, 202)
                return
            if parts == ["api", "backup", "preview"]:
                self._authenticated(require_csrf=True)
                result = web_actions.preview_encrypted_backup(self._read_json())
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "backup", "restore"]:
                self._authenticated(require_csrf=True)
                result = web_actions.restore_encrypted_backup(self._read_json())
                self.server.delayed_restart()
                self._json({"ok": True, "result": result}, 202)
                return
            if parts == ["api", "rollback"]:
                self._authenticated(require_csrf=True)
                data = self._read_json()
                result = web_actions.rollback_program(data.get("snapshot"))
                self.server.delayed_restart()
                self._json({"ok": True, "result": result}, 202)
                return
            if parts == ["api", "discovery", "scan"]:
                self._authenticated(require_csrf=True)
                result = web_actions.discover_instances(
                    self.server.guard, self._read_json()
                )
                self._json({"ok": True, "result": result})
                return
            if parts == ["api", "discovery", "import"]:
                self._authenticated(require_csrf=True)
                result = web_actions.import_discovered_instances(
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
                data = self._read_json()
                pid = web_actions.install_update(data.get("target_version"))
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
                if parts[3] == "logging":
                    result = web_actions.update_instance_logging(
                        self.server.guard, index, data.get("enabled")
                    )
                    self._json({"ok": True, "result": result})
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
__AG_WEB_PY_EOF__
    cat > "$APP_DIR/web_panel.html" <<'__AG_WEB_HTML_EOF__'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="color-scheme" content="light">
  <title>Aliyun Guard</title>
  <style>
    :root {
      --bg: #f4f6f3;
      --surface: #ffffff;
      --surface-alt: #eef4f1;
      --ink: #17201d;
      --muted: #65716c;
      --line: #d9e1dc;
      --brand: #08775a;
      --brand-dark: #075e49;
      --cyan: #167c94;
      --amber: #b96808;
      --red: #b63d36;
      --shadow: 0 8px 24px rgba(23, 32, 29, .07);
      --radius: 6px;
    }
    * { box-sizing: border-box; }
    html { min-width: 320px; background: var(--bg); }
    body {
      margin: 0;
      min-height: 100vh;
      color: var(--ink);
      background: var(--bg);
      font-family: Inter, "Segoe UI", "Microsoft YaHei UI", "Microsoft YaHei", sans-serif;
      font-size: 14px;
      line-height: 1.5;
      letter-spacing: 0;
    }
    button, input, select, textarea { font: inherit; letter-spacing: 0; }
    button { cursor: pointer; }
    [hidden] { display: none !important; }
    .icon { width: 18px; height: 18px; flex: 0 0 18px; stroke-width: 2; }
    .auth-shell {
      min-height: 100vh;
      display: grid;
      grid-template-columns: minmax(280px, 420px) minmax(0, 1fr);
      background: var(--surface);
    }
    .auth-panel {
      padding: 52px 42px;
      display: flex;
      flex-direction: column;
      justify-content: center;
      border-right: 1px solid var(--line);
    }
    .auth-scene {
      position: relative;
      overflow: hidden;
      background: #14352d;
      color: #fff;
      display: grid;
      align-content: center;
      padding: 8vw;
    }
    .auth-scene::before {
      content: "";
      position: absolute;
      inset: 0;
      opacity: .18;
      background-image:
        linear-gradient(#b8fff0 1px, transparent 1px),
        linear-gradient(90deg, #b8fff0 1px, transparent 1px);
      background-size: 48px 48px;
    }
    .scene-chart { position: relative; width: min(660px, 100%); }
    .scene-chart svg { display: block; width: 100%; height: auto; }
    .scene-title { position: relative; margin: 26px 0 0; font-size: 18px; font-weight: 600; }
    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
      min-width: 0;
    }
    .brand-mark {
      width: 38px;
      height: 38px;
      display: grid;
      place-items: center;
      background: var(--brand);
      color: #fff;
      border-radius: var(--radius);
      flex: 0 0 38px;
    }
    .brand-name { font-size: 20px; font-weight: 750; line-height: 1.1; overflow-wrap: anywhere; }
    .brand-sub { color: var(--muted); font-size: 12px; margin-top: 3px; }
    .auth-title { margin: 50px 0 4px; font-size: 27px; line-height: 1.25; }
    .auth-meta { margin: 0 0 28px; color: var(--muted); }
    .field { display: grid; gap: 7px; margin-bottom: 17px; }
    .field label { font-size: 13px; font-weight: 650; color: #3d4944; }
    .input-wrap { position: relative; }
    input, select, textarea {
      width: 100%;
      min-height: 42px;
      border: 1px solid #cbd5cf;
      border-radius: 5px;
      background: #fff;
      color: var(--ink);
      padding: 9px 11px;
      outline: none;
    }
    textarea { min-height: 82px; resize: vertical; }
    input:focus, select:focus, textarea:focus { border-color: var(--brand); box-shadow: 0 0 0 3px rgba(8, 119, 90, .12); }
    .input-wrap input { padding-right: 44px; }
    .input-icon {
      position: absolute;
      right: 3px;
      top: 3px;
      width: 36px;
      height: 36px;
      border: 0;
      background: transparent;
      color: var(--muted);
      display: grid;
      place-items: center;
    }
    .button {
      min-height: 38px;
      border: 1px solid transparent;
      border-radius: 5px;
      padding: 8px 13px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      font-weight: 650;
      white-space: nowrap;
    }
    .button.primary { background: var(--brand); color: #fff; }
    .button.primary:hover { background: var(--brand-dark); }
    .button.secondary { background: #fff; border-color: var(--line); color: var(--ink); }
    .button.secondary:hover { background: var(--surface-alt); }
    .button.danger { background: #fff; border-color: #e1b5b1; color: var(--red); }
    .button.warning { background: #fff8ed; border-color: #e8c897; color: #8b4e07; }
    .button:disabled { cursor: not-allowed; opacity: .55; }
    .auth-submit { width: 100%; margin-top: 6px; min-height: 44px; }
    .form-error { min-height: 22px; color: var(--red); margin: 5px 0 0; }
    .app { min-height: 100vh; }
    .app-header {
      height: 66px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 20px;
      padding: 0 28px;
      background: var(--surface);
      border-bottom: 1px solid var(--line);
      position: sticky;
      top: 0;
      z-index: 30;
    }
    .header-actions { display: flex; align-items: center; gap: 8px; }
    .icon-button {
      width: 38px;
      height: 38px;
      border: 1px solid var(--line);
      border-radius: 5px;
      background: #fff;
      color: #46534e;
      display: grid;
      place-items: center;
      padding: 0;
    }
    .icon-button:hover { background: var(--surface-alt); color: var(--brand); }
    .service-chip {
      height: 30px;
      display: inline-flex;
      align-items: center;
      gap: 7px;
      padding: 0 10px;
      border: 1px solid var(--line);
      border-radius: 15px;
      color: #355047;
      background: #f8faf8;
      font-size: 12px;
      white-space: nowrap;
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--brand); }
    .dot.bad { background: var(--red); }
    .app-nav {
      height: 48px;
      padding: 0 28px;
      display: flex;
      align-items: end;
      gap: 24px;
      background: var(--surface);
      border-bottom: 1px solid var(--line);
      overflow-x: auto;
    }
    .tab-button {
      height: 48px;
      border: 0;
      border-bottom: 2px solid transparent;
      background: transparent;
      color: var(--muted);
      padding: 0 2px;
      display: inline-flex;
      align-items: center;
      gap: 7px;
      font-weight: 650;
      white-space: nowrap;
    }
    .tab-button.active { color: var(--brand); border-bottom-color: var(--brand); }
    .main { width: min(1440px, 100%); margin: 0 auto; padding: 24px 28px 44px; }
    .section-heading {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 17px;
    }
    .section-heading h1 { font-size: 20px; margin: 0; }
    .section-heading p { margin: 2px 0 0; color: var(--muted); font-size: 12px; }
    .section-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
    .summary-band {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: var(--radius);
      margin-bottom: 18px;
      overflow: hidden;
    }
    .summary-item { min-width: 0; padding: 17px 18px; border-right: 1px solid var(--line); }
    .summary-item:last-child { border-right: 0; }
    .summary-label { color: var(--muted); font-size: 12px; display: flex; align-items: center; gap: 6px; }
    .summary-value { margin-top: 5px; font-size: 20px; font-weight: 750; overflow-wrap: anywhere; }
    .notice {
      display: flex;
      align-items: flex-start;
      gap: 10px;
      border: 1px solid #e6c38d;
      border-left: 4px solid var(--amber);
      background: #fff9ef;
      padding: 11px 13px;
      margin-bottom: 18px;
      border-radius: 4px;
      color: #6c450f;
    }
    .instances {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 16px;
    }
    .instance-card {
      min-width: 0;
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: var(--radius);
      box-shadow: var(--shadow);
      overflow: hidden;
    }
    .instance-card:only-child { grid-column: 1 / -1; }
    .card-head {
      min-height: 66px;
      padding: 14px 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
      border-bottom: 1px solid var(--line);
    }
    .instance-name { margin: 0; font-size: 16px; overflow-wrap: anywhere; }
    .instance-meta { margin-top: 2px; color: var(--muted); font-size: 12px; overflow-wrap: anywhere; }
    .card-head-tools { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }
    .status-badge {
      flex: 0 0 auto;
      min-width: 82px;
      height: 28px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 6px;
      border-radius: 14px;
      padding: 0 10px;
      font-size: 12px;
      font-weight: 700;
      border: 1px solid #b7d8cb;
      color: #086146;
      background: #eff9f5;
    }
    .status-badge.stopped, .status-badge.error { color: #96352f; border-color: #e3bab7; background: #fff3f2; }
    .status-badge.transition { color: #865006; border-color: #ead09f; background: #fff9ed; }
    .status-badge.unknown { color: #58645f; border-color: #d0d8d3; background: #f4f6f5; }
    .instance-tools { position: relative; }
    .instance-tools summary { list-style: none; }
    .instance-tools summary::-webkit-details-marker { display: none; }
    .instance-tools[open] summary { color: var(--brand); background: var(--surface-alt); }
    .instance-menu {
      position: absolute;
      z-index: 24;
      top: 44px;
      right: 0;
      width: 196px;
      padding: 6px;
      background: #fff;
      border: 1px solid var(--line);
      border-radius: 6px;
      box-shadow: 0 14px 34px rgba(17, 36, 30, .18);
    }
    .instance-menu .menu-button {
      width: 100%;
      min-height: 38px;
      padding: 8px 9px;
      display: flex;
      align-items: center;
      gap: 9px;
      border: 0;
      border-radius: 4px;
      background: transparent;
      color: var(--ink);
      text-align: left;
      font-weight: 600;
      font-size: 12px;
    }
    .instance-menu .menu-button:hover, .instance-menu .menu-button:focus-visible { background: var(--surface-alt); outline: none; }
    .instance-menu .menu-button.warning { color: #8b4e07; }
    .instance-menu .menu-button.danger { color: var(--red); border-top: 1px solid var(--line); border-radius: 0 0 4px 4px; margin-top: 4px; padding-top: 10px; }
    .instance-menu .menu-button:disabled { opacity: .5; cursor: not-allowed; }
    .card-body { padding: 15px 16px 12px; }
    .metric-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
    .metric { min-width: 0; }
    .metric-label { color: var(--muted); font-size: 11px; }
    .metric-value { margin-top: 3px; font-weight: 700; overflow-wrap: anywhere; }
    .traffic-row { display: flex; justify-content: space-between; gap: 12px; margin-top: 15px; font-size: 12px; }
    .progress { height: 7px; margin-top: 7px; background: #e7ede9; border-radius: 3px; overflow: hidden; }
    .progress > span { display: block; height: 100%; background: var(--brand); border-radius: 3px; }
    .progress > span.warn { background: var(--amber); }
    .progress > span.danger { background: var(--red); }
    .sparkline { position: relative; height: 70px; margin-top: 12px; border-top: 1px solid #edf1ee; padding-top: 9px; }
    .sparkline svg { width: 100%; height: 58px; display: block; overflow: visible; }
    .chart-hit { fill: transparent; stroke: transparent; cursor: crosshair; outline: none; }
    .chart-focus, .chart-point { fill: none; stroke: var(--cyan); stroke-width: 6px; stroke-linecap: round; vector-effect: non-scaling-stroke; pointer-events: none; }
    .chart-focus { opacity: 0; }
    .chart-hit:hover + .chart-focus, .chart-hit:focus + .chart-focus { opacity: 1; }
    .chart-tooltip {
      position: absolute;
      z-index: 12;
      bottom: 64px;
      width: min(286px, calc(100% - 8px));
      padding: 10px 11px;
      color: #effaf6;
      background: #17372e;
      border: 1px solid #31564a;
      border-radius: 5px;
      box-shadow: 0 10px 28px rgba(17, 36, 30, .22);
      pointer-events: none;
      font-size: 11px;
      line-height: 1.45;
    }
    .chart-tooltip::after { content: ""; position: absolute; bottom: -6px; left: var(--tip-arrow, 50%); width: 10px; height: 10px; background: #17372e; border-right: 1px solid #31564a; border-bottom: 1px solid #31564a; transform: translateX(-50%) rotate(45deg); }
    .tooltip-title { font-size: 12px; font-weight: 750; margin-bottom: 5px; }
    .tooltip-row { display: grid; grid-template-columns: 58px minmax(0, 1fr); gap: 7px; }
    .tooltip-row span:first-child { color: #9fc2b6; }
    .tooltip-row strong { font-weight: 600; overflow-wrap: anywhere; }
    .result-line { min-height: 40px; padding: 10px 16px; color: #53605b; background: #fafbfa; border-top: 1px solid var(--line); overflow-wrap: anywhere; }
    .empty {
      grid-column: 1 / -1;
      min-height: 260px;
      display: grid;
      place-items: center;
      text-align: center;
      color: var(--muted);
      background: var(--surface);
      border: 1px dashed #cbd5cf;
      border-radius: var(--radius);
    }
    .log-toolbar { display: flex; justify-content: space-between; align-items: center; gap: 10px; margin-bottom: 12px; }
    .log-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
    .log-source { width: min(300px, 46vw); min-height: 38px; padding-block: 7px; }
    .log-view {
      min-height: 520px;
      max-height: calc(100vh - 235px);
      overflow: auto;
      margin: 0;
      padding: 16px;
      color: #dff7ed;
      background: #13251f;
      border-radius: var(--radius);
      font: 12px/1.65 "Cascadia Mono", Consolas, monospace;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }
    .settings-panel { max-width: 720px; background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 20px; }
    .settings-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 17px; }
    .settings-actions { margin-top: 4px; display: flex; justify-content: flex-end; }
    .panel-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; align-items: start; }
    .panel { min-width: 0; background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); }
    .panel.full { grid-column: 1 / -1; }
    .panel-head { min-height: 58px; padding: 13px 16px; border-bottom: 1px solid var(--line); display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .panel-head h2 { margin: 0; font-size: 15px; }
    .panel-head p { margin: 2px 0 0; color: var(--muted); font-size: 11px; }
    .panel-body { padding: 16px; }
    .panel-actions { padding: 12px 16px; border-top: 1px solid var(--line); display: flex; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
    .form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 16px; }
    .form-grid .wide { grid-column: 1 / -1; }
    .check-row { min-height: 42px; display: flex; align-items: center; gap: 9px; }
    .check-row input { width: 18px; min-height: 18px; margin: 0; accent-color: var(--brand); }
    .muted { color: var(--muted); }
    .small { font-size: 12px; }
    .mode-grid { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 7px; }
    .mode-option { position: relative; min-width: 0; }
    .mode-option input { position: absolute; opacity: 0; width: 1px; height: 1px; }
    .mode-option span { min-height: 54px; display: grid; place-items: center; text-align: center; padding: 7px; border: 1px solid var(--line); border-radius: 5px; color: #45534d; background: #fff; font-size: 11px; cursor: pointer; overflow-wrap: anywhere; }
    .mode-option input:checked + span { color: var(--brand-dark); border-color: var(--brand); background: #edf8f4; box-shadow: inset 0 0 0 1px var(--brand); }
    .connection-fields { margin-top: 16px; }
    .node-list { display: grid; border-top: 1px solid var(--line); }
    .node-row { min-width: 0; padding: 11px 16px; display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 12px; border-bottom: 1px solid var(--line); }
    .node-row:last-child { border-bottom: 0; }
    .node-name { font-weight: 650; overflow-wrap: anywhere; }
    .node-actions { display: flex; gap: 6px; }
    .node-actions .button { min-height: 32px; padding: 5px 8px; font-size: 11px; }
    .active-mark { color: var(--brand); font-size: 11px; font-weight: 700; }
    .inline-result { min-height: 40px; margin-top: 12px; padding: 10px 11px; border-left: 3px solid var(--cyan); background: #eef7f8; color: #30545c; border-radius: 3px; overflow-wrap: anywhere; }
    .inline-result.error { border-left-color: var(--red); background: #fff3f2; color: #7f302c; }
    .update-progress { margin-top: 12px; display: grid; gap: 7px; }
    .update-progress-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; color: var(--muted); font-size: 12px; }
    .update-progress-head span { min-width: 0; overflow-wrap: anywhere; }
    .update-progress-head strong { color: var(--ink); flex: 0 0 auto; }
    .update-progress progress { width: 100%; height: 10px; display: block; border: 0; border-radius: 3px; overflow: hidden; background: #e2e8e4; accent-color: var(--brand); }
    .update-progress progress::-webkit-progress-bar { background: #e2e8e4; }
    .update-progress progress::-webkit-progress-value { background: var(--brand); transition: width .25s ease; }
    .update-progress progress::-moz-progress-bar { background: var(--brand); }
    .update-progress.error progress { accent-color: var(--red); }
    .update-progress.error progress::-webkit-progress-value { background: var(--red); }
    .update-progress.error progress::-moz-progress-bar { background: var(--red); }
    .system-list { display: grid; gap: 10px; }
    .system-row { display: flex; justify-content: space-between; gap: 16px; padding-bottom: 10px; border-bottom: 1px solid #edf1ee; }
    .system-row:last-child { padding-bottom: 0; border-bottom: 0; }
    .system-row strong { text-align: right; overflow-wrap: anywhere; }
    .warning-text { color: #8b4e07; }
    .danger-text { color: var(--red); }
    dialog {
      width: min(460px, calc(100vw - 28px));
      border: 1px solid var(--line);
      border-radius: 7px;
      padding: 0;
      color: var(--ink);
      box-shadow: 0 24px 70px rgba(17, 28, 24, .24);
    }
    dialog.wide-dialog { width: min(760px, calc(100vw - 28px)); }
    dialog::backdrop { background: rgba(17, 28, 24, .48); }
    .dialog-head { min-height: 58px; padding: 13px 16px; border-bottom: 1px solid var(--line); display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .dialog-head h2 { margin: 0; font-size: 16px; }
    .dialog-body { padding: 18px 16px; }
    .dialog-actions { padding: 12px 16px; border-top: 1px solid var(--line); display: flex; justify-content: flex-end; gap: 8px; }
    .toggle-row { min-height: 42px; display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 16px; }
    .switch { position: relative; width: 42px; height: 24px; flex: 0 0 42px; }
    .switch input { position: absolute; opacity: 0; width: 1px; height: 1px; }
    .switch span { position: absolute; inset: 0; background: #bfc9c3; border-radius: 12px; transition: .18s; }
    .switch span::after { content: ""; position: absolute; width: 18px; height: 18px; left: 3px; top: 3px; border-radius: 50%; background: #fff; transition: .18s; box-shadow: 0 1px 4px rgba(0,0,0,.2); }
    .switch input:checked + span { background: var(--brand); }
    .switch input:checked + span::after { transform: translateX(18px); }
    .toast {
      position: fixed;
      right: 20px;
      bottom: 20px;
      z-index: 80;
      max-width: min(420px, calc(100vw - 40px));
      min-height: 46px;
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 11px 14px;
      color: #fff;
      background: #20352e;
      border-radius: 6px;
      box-shadow: var(--shadow);
    }
    .toast.error { background: #8f312d; }
    .spin { animation: spin .8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (max-width: 980px) {
      .auth-shell { grid-template-columns: minmax(280px, 390px) 1fr; }
      .auth-scene { padding: 5vw; }
      .summary-band { grid-template-columns: 1fr 1fr; }
      .summary-item:nth-child(2) { border-right: 0; }
      .summary-item:nth-child(-n+2) { border-bottom: 1px solid var(--line); }
      .metric-grid { grid-template-columns: 1fr 1fr; }
      .mode-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    }
    @media (max-width: 760px) {
      .auth-shell { display: block; background: var(--bg); padding: 0; }
      .auth-panel { min-height: 100vh; padding: 36px 22px; border: 0; background: var(--surface); }
      .auth-scene { display: none; }
      .auth-title { margin-top: 44px; font-size: 24px; }
      .app-header { height: 60px; padding: 0 14px; }
      .brand-mark { width: 34px; height: 34px; flex-basis: 34px; }
      .brand-name { font-size: 17px; }
      .brand-sub, .service-chip { display: none; }
      .app-nav { padding: 0 14px; gap: 12px; }
      .tab-button { font-size: 12px; }
      .main { padding: 18px 14px 34px; }
      .section-heading { align-items: flex-start; }
      .instances { grid-template-columns: 1fr; }
      .settings-grid { grid-template-columns: 1fr; }
      .form-grid, .panel-grid { grid-template-columns: 1fr; }
      .panel.full { grid-column: auto; }
      .section-heading { flex-wrap: wrap; }
      .section-actions { width: 100%; justify-content: flex-start; }
      .log-actions { width: 100%; justify-content: flex-start; }
      .log-source { width: auto; flex: 1 1 220px; }
      .card-head { align-items: flex-start; }
      .card-head-tools { gap: 6px; }
      .status-badge { min-width: 74px; padding: 0 8px; }
      .log-view { min-height: 440px; max-height: calc(100vh - 215px); }
    }
    @media (max-width: 430px) {
      .summary-band { grid-template-columns: 1fr 1fr; }
      .summary-item { padding: 13px 12px; }
      .summary-value { font-size: 17px; }
      .metric-grid { gap: 12px 8px; }
      .button .optional-label { display: none; }
      .section-heading h1 { font-size: 18px; }
      .mode-grid { grid-template-columns: 1fr 1fr; }
      .node-row { grid-template-columns: 1fr; }
      .node-actions { overflow-x: auto; }
      .log-source { flex-basis: 100%; }
    }
  </style>
</head>
<body>
  <section id="loginView" class="auth-shell">
    <div class="auth-panel">
      <div class="brand">
        <div class="brand-mark" data-icon="activity"></div>
        <div><div class="brand-name">Aliyun Guard</div><div class="brand-sub">ECS CONTROL CONSOLE</div></div>
      </div>
      <h1 class="auth-title">登录控制台</h1>
      <p class="auth-meta" id="loginVersion">受保护的运维入口</p>
      <form id="loginForm" autocomplete="on">
        <div class="field">
          <label for="username">用户名</label>
          <input id="username" name="username" autocomplete="username" required>
        </div>
        <div class="field">
          <label for="password">密码</label>
          <div class="input-wrap">
            <input id="password" name="password" type="password" autocomplete="current-password" required>
            <button class="input-icon" id="togglePassword" type="button" title="显示或隐藏密码" aria-label="显示或隐藏密码" data-icon="eye"></button>
          </div>
        </div>
        <button class="button primary auth-submit" type="submit"><span data-icon="log-in"></span>登录</button>
        <p id="loginError" class="form-error" role="alert"></p>
      </form>
    </div>
    <div class="auth-scene" aria-hidden="true">
      <div class="scene-chart">
        <svg viewBox="0 0 760 300" role="img">
          <path d="M20 238 C90 225 124 246 176 191 S270 158 322 176 S407 92 461 121 S547 72 598 88 S684 43 740 55" fill="none" stroke="#5cf0c8" stroke-width="6" stroke-linecap="round"/>
          <path d="M20 238 C90 225 124 246 176 191 S270 158 322 176 S407 92 461 121 S547 72 598 88 S684 43 740 55 L740 280 L20 280 Z" fill="#5cf0c8" opacity=".1"/>
          <circle cx="740" cy="55" r="9" fill="#fff" stroke="#5cf0c8" stroke-width="5"/>
        </svg>
      </div>
      <p class="scene-title">Alibaba Cloud · Operations</p>
    </div>
  </section>

  <div id="appView" class="app" hidden>
    <header class="app-header">
      <div class="brand">
        <div class="brand-mark" data-icon="activity"></div>
        <div><div class="brand-name">Aliyun Guard</div><div class="brand-sub" id="appVersion">Web Console</div></div>
      </div>
      <div class="header-actions">
        <div class="service-chip"><span id="serviceDot" class="dot"></span><span id="serviceText">读取中</span></div>
        <button id="refreshButton" class="icon-button" type="button" title="刷新" aria-label="刷新" data-icon="refresh-cw"></button>
        <button id="logoutButton" class="icon-button" type="button" title="退出登录" aria-label="退出登录" data-icon="log-out"></button>
      </div>
    </header>
    <nav class="app-nav" aria-label="控制台视图">
      <button class="tab-button active" data-tab="dashboard"><span data-icon="layout-dashboard"></span>实例</button>
      <button class="tab-button" data-tab="telegram"><span data-icon="send"></span>Telegram</button>
      <button class="tab-button" data-tab="logs"><span data-icon="terminal"></span>日志</button>
      <button class="tab-button" data-tab="settings"><span data-icon="settings"></span>设置</button>
      <button class="tab-button" data-tab="system"><span data-icon="wrench"></span>系统</button>
    </nav>
    <main class="main">
      <section id="dashboardTab" class="tab-panel">
        <div class="section-heading">
          <div><h1>实例总览</h1><p id="lastUpdated">尚未刷新</p></div>
          <div class="section-actions">
            <button id="dryRunButton" class="button secondary" type="button"><span data-icon="flask-conical"></span>演练检测</button>
            <button id="runButton" class="button primary" type="button"><span data-icon="play"></span>立即检测</button>
            <button id="addInstanceButton" class="button secondary" type="button"><span data-icon="plus"></span>添加实例</button>
            <button id="discoverInstanceButton" class="button secondary" type="button"><span data-icon="search"></span>自动发现</button>
          </div>
        </div>
        <div class="summary-band">
          <div class="summary-item"><div class="summary-label"><span data-icon="server"></span>实例</div><div class="summary-value" id="summaryInstances">0</div></div>
          <div class="summary-item"><div class="summary-label"><span data-icon="activity"></span>运行中</div><div class="summary-value" id="summaryRunning">0</div></div>
          <div class="summary-item"><div class="summary-label"><span data-icon="triangle-alert"></span>异常</div><div class="summary-value" id="summaryErrors">0</div></div>
          <div class="summary-item"><div class="summary-label"><span data-icon="clock"></span>累计检测</div><div class="summary-value" id="summaryCycles">0</div></div>
        </div>
        <div id="notice" class="notice" hidden><span data-icon="triangle-alert"></span><span id="noticeText"></span></div>
        <div id="instances" class="instances"></div>
      </section>

      <section id="telegramTab" class="tab-panel" hidden>
        <div class="section-heading">
          <div><h1>Telegram</h1><p id="telegramCurrent">正在读取当前连接方式</p></div>
          <button id="telegramTestButton" class="button primary" type="button"><span data-icon="send"></span>发送测试消息</button>
        </div>
        <div class="panel-grid">
          <form id="telegramIdentityForm" class="panel">
            <div class="panel-head"><div><h2>机器人身份</h2><p>密钥留空时保留原配置</p></div></div>
            <div class="panel-body form-grid">
              <div class="field wide"><label for="tgToken">Bot Token</label><input id="tgToken" type="password" autocomplete="off" placeholder="已保存，留空不修改"></div>
              <div class="field"><label for="tgChatId">Chat ID</label><input id="tgChatId" autocomplete="off" required></div>
              <div class="field"><label for="tgTimeout">请求超时（秒）</label><input id="tgTimeout" type="number" min="3" max="60" required></div>
              <div class="field"><label for="tgRetries">重试次数</label><input id="tgRetries" type="number" min="1" max="5" required></div>
              <div class="field wide"><div class="toggle-row"><div><strong>Bot 控制</strong><div class="brand-sub">仅授权管理员私聊可用</div></div><label class="switch"><input id="tgControlEnabled" type="checkbox"><span></span></label></div></div>
              <div id="tgControlAdminsField" class="field wide"><label for="tgControlAdmins">管理员 Telegram 用户 ID</label><input id="tgControlAdmins" autocomplete="off" placeholder="留空使用正数私聊 Chat ID"><div id="tgControlHint" class="muted small"></div></div>
            </div>
            <div class="panel-actions"><button class="button primary" type="submit"><span data-icon="save"></span>保存机器人配置</button></div>
          </form>

          <form id="connectionForm" class="panel">
            <div class="panel-head"><div><h2>连接方式</h2><p id="connectionDescription">直连</p></div></div>
            <div class="panel-body">
              <div class="mode-grid" role="radiogroup" aria-label="Telegram 连接方式">
                <label class="mode-option"><input type="radio" name="connectionMode" value="direct"><span>直连</span></label>
                <label class="mode-option"><input type="radio" name="connectionMode" value="socks5"><span>SOCKS5</span></label>
                <label class="mode-option"><input type="radio" name="connectionMode" value="http"><span>HTTP/HTTPS</span></label>
                <label class="mode-option"><input type="radio" name="connectionMode" value="node"><span>节点链接</span></label>
                <label class="mode-option"><input type="radio" name="connectionMode" value="api_proxy"><span>API 反代</span></label>
              </div>
              <div class="connection-fields">
                <div id="proxyField" class="field" hidden><label for="proxyUrl">代理地址</label><input id="proxyUrl" type="password" autocomplete="off" placeholder="已保存，留空不修改"></div>
                <div id="nodeField" class="field" hidden><label for="nodeSelect">已保存节点</label><select id="nodeSelect"></select></div>
                <div id="apiProxyField" class="field" hidden><label for="apiBaseUrl">Telegram API 基础地址</label><input id="apiBaseUrl" autocomplete="off" placeholder="https://example.com"></div>
              </div>
              <div id="connectionResult" class="inline-result" hidden></div>
            </div>
            <div class="panel-actions">
              <button id="connectionTestButton" class="button secondary" type="button"><span data-icon="gauge"></span>单独检测</button>
              <button class="button primary" type="submit"><span data-icon="save"></span>测试并保存</button>
            </div>
          </form>

          <div class="panel full">
            <div class="panel-head"><div><h2>节点管理</h2><p>VLESS、VMess、Shadowsocks；测试可达后才会保存</p></div><strong id="nodeCount">0 个节点</strong></div>
            <form id="nodeAddForm" class="panel-body">
              <div class="field"><label for="nodeUrl">节点链接</label><textarea id="nodeUrl" autocomplete="off" placeholder="vless://、vmess:// 或 ss://" required></textarea></div>
              <div class="settings-actions"><button class="button primary" type="submit"><span data-icon="plus"></span>测试并保存节点</button></div>
              <div id="nodeResult" class="inline-result" hidden></div>
            </form>
            <div id="nodeList" class="node-list"></div>
          </div>
        </div>
      </section>

      <section id="logsTab" class="tab-panel" hidden>
        <div class="section-heading">
          <div><h1>运行日志</h1><p id="logsDescription">系统总日志 · 最近 200 行</p></div>
          <div class="section-actions log-actions">
            <select id="logSource" class="log-source" aria-label="日志来源"><option value="system">系统总日志</option></select>
            <button id="instanceLogToggle" class="button secondary" type="button" hidden><span data-icon="terminal"></span><span id="instanceLogToggleText">启用独立日志</span></button>
            <button id="logsRefresh" class="button secondary" type="button"><span data-icon="refresh-cw"></span>刷新</button>
          </div>
        </div>
        <pre id="logView" class="log-view">正在读取...</pre>
      </section>

      <section id="settingsTab" class="tab-panel" hidden>
        <div class="section-heading"><div><h1>设置</h1><p>后台检测与网页入口</p></div></div>
        <div class="panel-grid">
          <form id="settingsForm" class="panel">
            <div class="panel-head"><div><h2>全局检测设置</h2><p>下一轮自动读取新配置</p></div></div>
            <div class="panel-body form-grid">
              <div class="field"><label for="intervalSeconds">检测间隔（秒）</label><input id="intervalSeconds" type="number" min="60" max="86400" required></div>
              <div class="field"><label for="notificationMode">Telegram 通知模式</label><select id="notificationMode"><option value="always">每轮通知</option><option value="events">仅事件与变化</option><option value="errors">仅错误</option></select></div>
              <label class="check-row"><input id="forceIpv4" type="checkbox">网络请求优先使用 IPv4</label>
              <label class="check-row"><input id="notifyOnStart" type="checkbox">服务启动时发送通知</label>
              <div class="field"><label for="startWait">开机确认等待（秒）</label><input id="startWait" type="number" min="0" max="600" required></div>
              <div class="field"><label for="stopWait">关机确认等待（秒）</label><input id="stopWait" type="number" min="0" max="600" required></div>
              <div class="field"><label for="pollSeconds">状态轮询间隔（秒）</label><input id="pollSeconds" type="number" min="1" max="60" required></div>
              <label class="check-row wide"><input id="watchdogEnabled" type="checkbox">启用监控失联看门狗</label>
              <div class="field"><label for="watchdogTimeout">心跳超时（秒）</label><input id="watchdogTimeout" type="number" min="120" max="86400" required></div>
              <div class="field"><label for="watchdogFailures">连续失败次数</label><input id="watchdogFailures" type="number" min="1" max="10" required></div>
            </div>
            <div class="panel-actions"><button class="button primary" type="submit"><span data-icon="save"></span>保存全局设置</button></div>
          </form>

          <form id="webSettingsForm" class="panel">
            <div class="panel-head"><div><h2>网页控制面板</h2><p>支持 HTTP 与 HTTPS 反向代理访问</p></div></div>
            <div class="panel-body form-grid">
              <label class="check-row wide"><input id="webEnabled" type="checkbox">启用网页控制面板</label>
              <div class="field"><label for="webHost">监听方式</label><select id="webHost"><option value="127.0.0.1">仅本机 127.0.0.1</option><option value="0.0.0.0">所有 IPv4 网卡</option></select></div>
              <div class="field"><label for="webPort">端口</label><input id="webPort" type="number" min="1024" max="65535" required></div>
              <div class="field wide"><label for="webUsername">登录用户名</label><input id="webUsername" autocomplete="username" required></div>
              <div class="field"><label for="webPassword">新密码</label><input id="webPassword" type="password" autocomplete="new-password" placeholder="已保存，留空不修改"></div>
              <div class="field"><label for="webPasswordConfirm">确认新密码</label><input id="webPasswordConfirm" type="password" autocomplete="new-password" placeholder="再次输入新密码"></div>
              <p id="webWarning" class="wide muted small"></p>
            </div>
            <div class="panel-actions"><button class="button primary" type="submit"><span data-icon="save"></span>保存并应用</button></div>
          </form>
        </div>
      </section>

      <section id="systemTab" class="tab-panel" hidden>
        <div class="section-heading"><div><h1>系统</h1><p>服务状态与 GitHub 版本</p></div></div>
        <div class="panel-grid">
          <div class="panel">
            <div class="panel-head"><div><h2>运行环境</h2><p>当前安装实例</p></div></div>
            <div class="panel-body system-list">
              <div class="system-row"><span>调度后端</span><strong id="systemBackend">--</strong></div>
              <div class="system-row"><span>访问 IPv4</span><strong id="systemLocalIp">--</strong></div>
              <div class="system-row"><span>浏览器地址</span><strong id="systemBrowserUrl">--</strong></div>
              <div class="system-row"><span>当前版本</span><strong id="systemCurrentVersion">--</strong></div>
            </div>
            <div class="panel-actions"><button id="restartServiceButton" class="button warning" type="button"><span data-icon="refresh-cw"></span>重启后台服务</button></div>
          </div>
          <div class="panel">
            <div class="panel-head"><div><h2>GitHub 更新</h2><p>从正式发布版本更新</p></div></div>
            <div class="panel-body system-list">
              <div class="system-row"><span>本机版本</span><strong id="updateCurrentVersion">--</strong></div>
              <div class="system-row"><span>GitHub 版本</span><strong id="updateLatestVersion">尚未检查</strong></div>
              <div id="updateResult" class="inline-result" hidden></div>
              <div id="updateProgress" class="update-progress" hidden>
                <div class="update-progress-head"><span id="updateProgressText">准备更新</span><strong id="updateProgressPercent">0%</strong></div>
                <progress id="updateProgressBar" max="100" value="0" aria-label="更新进度"></progress>
              </div>
            </div>
            <div class="panel-actions"><button id="checkUpdateButton" class="button secondary" type="button"><span data-icon="search"></span>检查更新</button><button id="installUpdateButton" class="button primary" type="button" disabled><span data-icon="download"></span>安装更新</button></div>
          </div>
          <form id="backupCreateForm" class="panel">
            <div class="panel-head"><div><h2>加密备份</h2><p>AES-256-GCM，本机和下载文件各保留一份</p></div></div>
            <div class="panel-body form-grid">
              <div class="field wide"><label for="backupPassword">备份密码</label><input id="backupPassword" type="password" minlength="8" autocomplete="new-password" required></div>
              <label class="check-row"><input id="backupState" type="checkbox" checked>包含状态</label>
              <label class="check-row"><input id="backupLogs" type="checkbox" checked>包含日志</label>
            </div>
            <div class="panel-actions"><button class="button primary" type="submit"><span data-icon="download"></span>创建并下载</button></div>
          </form>
          <form id="backupRestoreForm" class="panel">
            <div class="panel-head"><div><h2>恢复备份</h2><p>必须先预览差异，再允许恢复</p></div></div>
            <div class="panel-body form-grid">
              <div class="field wide"><label for="restoreFile">备份文件</label><input id="restoreFile" type="file" accept=".agbackup,application/json" required></div>
              <div class="field wide"><label for="restorePassword">备份密码</label><input id="restorePassword" type="password" minlength="8" autocomplete="current-password" required></div>
              <label class="check-row wide"><input id="restoreLogs" type="checkbox" checked>恢复备份中的日志</label>
              <div id="restorePreview" class="inline-result wide" hidden></div>
            </div>
            <div class="panel-actions"><button id="previewRestoreButton" class="button secondary" type="button"><span data-icon="search"></span>预览差异</button><button id="restoreBackupButton" class="button warning" type="submit" disabled><span data-icon="refresh-cw"></span>确认恢复</button></div>
          </form>
          <form id="s3BackupForm" class="panel full">
            <div class="panel-head"><div><h2>AWS S3 自动备份</h2><p>AES-256-GCM 加密后上传，兼容 R2 与 MinIO</p></div><span id="s3BackupStatus" class="muted small">未配置</span></div>
            <div class="panel-body form-grid">
              <label class="check-row wide"><input id="s3Enabled" type="checkbox">启用自动备份</label>
              <div class="field"><label for="s3Bucket">Bucket</label><input id="s3Bucket" autocomplete="off"></div>
              <div class="field"><label for="s3Region">Region</label><input id="s3Region" placeholder="us-east-1"></div>
              <div class="field wide"><label for="s3Endpoint">自定义 Endpoint</label><input id="s3Endpoint" type="url" placeholder="AWS S3 留空；R2/MinIO 填写 HTTPS 地址"></div>
              <div class="field"><label for="s3Prefix">对象目录前缀</label><input id="s3Prefix" placeholder="aliyun-guard"></div>
              <div class="field"><label for="s3AddressingStyle">寻址方式</label><select id="s3AddressingStyle"><option value="auto">自动</option><option value="path">路径寻址</option><option value="virtual">虚拟主机寻址</option></select></div>
              <label class="check-row wide"><input id="s3IamRole" type="checkbox">使用 EC2 IAM Role 或环境凭据</label>
              <div id="s3CredentialFields" class="wide form-grid">
                <div class="field"><label for="s3AccessKey">Access Key ID</label><input id="s3AccessKey" type="password" autocomplete="off"></div>
                <div class="field"><label for="s3SecretKey">Secret Access Key</label><input id="s3SecretKey" type="password" autocomplete="off"></div>
                <div class="field wide"><label for="s3SessionToken">Session Token</label><input id="s3SessionToken" type="password" autocomplete="off" placeholder="长期密钥留空"></div>
                <label class="check-row wide"><input id="s3ClearSessionToken" type="checkbox">清除已保存的 Session Token</label>
              </div>
              <div class="field wide"><label for="s3BackupPassword">加密备份密码</label><input id="s3BackupPassword" type="password" minlength="8" autocomplete="new-password"></div>
              <div class="field"><label for="s3Schedule">周期</label><select id="s3Schedule"><option value="hourly">每小时</option><option value="daily">每天</option><option value="weekly">每周</option></select></div>
              <div class="field"><label for="s3Time">执行时间</label><input id="s3Time" type="time"></div>
              <div id="s3WeekdayField" class="field"><label for="s3Weekday">星期</label><select id="s3Weekday"><option value="0">周一</option><option value="1">周二</option><option value="2">周三</option><option value="3">周四</option><option value="4">周五</option><option value="5">周六</option><option value="6">周日</option></select></div>
              <div class="field"><label for="s3Retention">保留份数</label><input id="s3Retention" type="number" min="1" max="365"></div>
              <label class="check-row"><input id="s3IncludeState" type="checkbox">包含运行状态</label>
              <label class="check-row"><input id="s3IncludeLogs" type="checkbox">包含日志</label>
              <div class="field"><label for="s3Notification">Telegram 通知</label><select id="s3Notification"><option value="errors">仅失败</option><option value="always">成功和失败</option><option value="none">不通知</option></select></div>
              <div class="field"><label for="s3Encryption">服务端加密</label><select id="s3Encryption"><option value="AES256">SSE-S3</option><option value="aws:kms">SSE-KMS</option><option value="">关闭</option></select></div>
              <div id="s3KmsField" class="field wide"><label for="s3KmsKey">KMS Key ID / ARN</label><input id="s3KmsKey" type="password" autocomplete="off"></div>
              <div id="s3Result" class="inline-result wide" hidden></div>
            </div>
            <div class="panel-actions"><button id="s3TestButton" class="button secondary" type="button"><span data-icon="gauge"></span>测试连接</button><button id="s3RunButton" class="button secondary" type="button"><span data-icon="upload"></span>立即备份</button><button id="s3ListButton" class="button secondary" type="button"><span data-icon="search"></span>云端备份</button><button class="button primary" type="submit"><span data-icon="save"></span>保存设置</button></div>
            <div id="s3BackupList" class="node-list"></div>
          </form>
          <div class="panel full">
            <div class="panel-head"><div><h2>程序版本回滚</h2><p>恢复更新前程序文件，不覆盖配置、状态和日志</p></div></div>
            <div class="panel-body form-grid"><div class="field wide"><label for="rollbackSnapshot">程序快照</label><select id="rollbackSnapshot"></select></div></div>
            <div class="panel-actions"><button id="rollbackButton" class="button warning" type="button" disabled><span data-icon="refresh-cw"></span>回滚并重启</button></div>
          </div>
        </div>
      </section>
    </main>
  </div>

  <dialog id="instanceDialog" class="wide-dialog">
    <form id="instanceForm">
      <div class="dialog-head"><h2 id="instanceDialogTitle">添加监控实例</h2><button class="icon-button" type="button" data-close-dialog title="关闭" aria-label="关闭" data-icon="x"></button></div>
      <div class="dialog-body">
        <div class="form-grid">
          <div class="field"><label for="instanceName">备注名称</label><input id="instanceName" required></div>
          <div class="field"><label for="instanceRegion">Region ID</label><input id="instanceRegion" placeholder="cn-hongkong" required></div>
          <div class="field wide"><label for="instanceId">ECS 实例 ID</label><input id="instanceId" placeholder="i-xxxxxxxx" required></div>
          <div class="field"><label for="instanceAk">AccessKey ID</label><input id="instanceAk" type="password" autocomplete="off" placeholder="已保存，留空不修改"></div>
          <div class="field"><label for="instanceSk">AccessKey Secret</label><input id="instanceSk" type="password" autocomplete="off" placeholder="已保存，留空不修改"></div>
          <div class="field"><label for="trafficLimit">CDT 关机阈值（GB）</label><input id="trafficLimit" type="number" min="0.01" step="0.01" required></div>
          <label class="check-row"><input id="actionsEnabled" type="checkbox">允许自动开机与关机</label>
          <label class="check-row"><input id="instanceLogEnabled" type="checkbox">记录该实例独立日志</label>
          <label class="check-row"><input id="billingEnabled" type="checkbox">查询本月实例账单</label>
          <div id="billingSiteField" class="field"><label for="billingSite">账单站点</label><select id="billingSite"><option value="china">阿里云中国站</option><option value="international">阿里云国际站</option><option value="custom">自定义</option></select></div>
          <div id="billingCustomFields" class="wide form-grid" hidden>
            <div class="field"><label for="billingEndpoint">BSS Endpoint</label><input id="billingEndpoint"></div>
            <div class="field"><label for="billingRegion">BSS 签名 Region</label><input id="billingRegion"></div>
            <div class="field"><label for="billingCurrencyCode">币种代码</label><input id="billingCurrencyCode" maxlength="8"></div>
            <div class="field"><label for="billingCurrencySymbol">币种符号</label><input id="billingCurrencySymbol" maxlength="8"></div>
          </div>
          <label class="check-row wide"><input id="instanceScheduleEnabled" type="checkbox">启用每日定时开关机</label>
          <div class="field"><label for="instanceStartTime">每日开机时间</label><input id="instanceStartTime" type="time" required></div>
          <div class="field"><label for="instanceStopTime">每日关机时间</label><input id="instanceStopTime" type="time" required></div>
        </div>
        <div id="instanceValidation" class="inline-result" hidden></div>
      </div>
      <div class="dialog-actions"><button class="button secondary" type="button" data-close-dialog>取消</button><button class="button primary" type="submit"><span data-icon="save"></span>校验并保存</button></div>
    </form>
  </dialog>

  <dialog id="scheduleDialog">
    <form id="scheduleForm">
      <div class="dialog-head"><h2 id="scheduleTitle">定时开关机</h2><button class="icon-button" type="button" data-close-dialog title="关闭" aria-label="关闭" data-icon="x"></button></div>
      <div class="dialog-body">
        <div class="toggle-row"><div><strong>每日计划</strong><div class="brand-sub">按服务器本地时间</div></div><label class="switch"><input id="scheduleEnabled" type="checkbox"><span></span></label></div>
        <div class="settings-grid">
          <div class="field"><label for="startTime">开机时间</label><input id="startTime" type="time" required></div>
          <div class="field"><label for="stopTime">关机时间</label><input id="stopTime" type="time" required></div>
        </div>
      </div>
      <div class="dialog-actions"><button class="button secondary" type="button" data-close-dialog>取消</button><button class="button primary" type="submit"><span data-icon="save"></span>保存计划</button></div>
    </form>
  </dialog>

  <dialog id="discoveryDialog" class="wide-dialog">
    <form id="discoveryForm">
      <div class="dialog-head"><h2>自动发现阿里云 ECS</h2><button class="icon-button" type="button" data-close-dialog title="关闭" aria-label="关闭" data-icon="x"></button></div>
      <div class="dialog-body">
        <div class="form-grid">
          <div class="field"><label for="discoverAk">AccessKey ID</label><input id="discoverAk" type="password" autocomplete="off" required></div>
          <div class="field"><label for="discoverSk">AccessKey Secret</label><input id="discoverSk" type="password" autocomplete="off" required></div>
          <div class="field wide"><label for="discoverRegions">Region ID（逗号分隔）</label><input id="discoverRegions" placeholder="留空扫描内置 Region"></div>
          <div class="field"><label for="discoverTagKey">标签键</label><input id="discoverTagKey" placeholder="可留空"></div>
          <div class="field"><label for="discoverTagValue">标签值</label><input id="discoverTagValue" placeholder="可留空"></div>
          <div class="field"><label for="discoverLimit">统一关机阈值（GB）</label><input id="discoverLimit" type="number" min="0.01" step="0.01" value="180" required></div>
          <div class="field"><label for="discoverBillingSite">账单站点</label><select id="discoverBillingSite"><option value="china">阿里云中国站</option><option value="international">阿里云国际站</option></select></div>
          <label class="check-row wide"><input id="discoverActions" type="checkbox" checked>允许导入的实例自动开关机</label>
        </div>
        <div id="discoveryResult" class="inline-result" hidden></div>
        <div id="discoveryList" class="node-list"></div>
      </div>
      <div class="dialog-actions"><button class="button secondary" type="button" data-close-dialog>取消</button><button id="scanInstancesButton" class="button secondary" type="button"><span data-icon="search"></span>扫描实例</button><button id="importInstancesButton" class="button primary" type="submit" disabled><span data-icon="plus"></span>导入所选</button></div>
    </form>
  </dialog>

  <div id="toast" class="toast" hidden role="status"><span id="toastIcon" data-icon="circle-check"></span><span id="toastText"></span></div>

  <script>
    // Paths are from the Lucide icon set (ISC License).
    const ICONS = {
      "activity": '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
      "eye": '<path d="M2.06 12.35a1 1 0 0 1 0-.7C3.74 7.6 7.69 5 12 5c4.31 0 8.26 2.6 9.94 6.65a1 1 0 0 1 0 .7C20.26 16.4 16.31 19 12 19c-4.31 0-8.26-2.6-9.94-6.65"/><circle cx="12" cy="12" r="3"/>',
      "eye-off": '<path d="m2 2 20 20"/><path d="M6.71 6.71C4.93 7.9 3.52 9.6 2.66 11.6a1 1 0 0 0 0 .8C4.27 16.1 7.8 18.5 12 18.5c1.1 0 2.16-.17 3.15-.48"/><path d="M10.73 5.58A10.8 10.8 0 0 1 12 5.5c4.2 0 7.73 2.4 9.34 6.1a1 1 0 0 1 0 .8 10.5 10.5 0 0 1-1.38 2.22"/><path d="M14.12 14.12A3 3 0 0 1 9.88 9.88"/>',
      "log-in": '<path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/><polyline points="10 17 15 12 10 7"/><line x1="15" x2="3" y1="12" y2="12"/>',
      "log-out": '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" x2="9" y1="12" y2="12"/>',
      "refresh-cw": '<path d="M21 12a9 9 0 0 0-15.22-6.22L3 8"/><path d="M3 3v5h5"/><path d="M3 12a9 9 0 0 0 15.22 6.22L21 16"/><path d="M16 16h5v5"/>',
      "layout-dashboard": '<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>',
      "terminal": '<polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/>',
      "settings": '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.38a2 2 0 0 0-.73-2.73l-.15-.09a2 2 0 0 1-1-1.74v-.51a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
      "play": '<polygon points="6 3 20 12 6 21 6 3"/>',
      "server": '<rect width="20" height="8" x="2" y="2" rx="2"/><rect width="20" height="8" x="2" y="14" rx="2"/><line x1="6" x2="6.01" y1="6" y2="6"/><line x1="6" x2="6.01" y1="18" y2="18"/>',
      "triangle-alert": '<path d="m21.73 18-8-14a2 2 0 0 0-3.46 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
      "clock": '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
      "power": '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>',
      "pause": '<rect width="4" height="16" x="6" y="4" rx="1"/><rect width="4" height="16" x="14" y="4" rx="1"/>',
      "calendar-clock": '<path d="M21 7.5V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h6.5"/><path d="M16 2v4"/><path d="M8 2v4"/><path d="M3 10h5"/><path d="M17.5 17.5 16 16.3V14"/><circle cx="16" cy="16" r="6"/>',
      "send": '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
      "wrench": '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94z"/>',
      "flask-conical": '<path d="M10 2v7.31"/><path d="M14 9.3V2"/><path d="M8.5 2h7"/><path d="M14 9.3 19.6 19a2 2 0 0 1-1.73 3H6.13a2 2 0 0 1-1.73-3L10 9.3"/><path d="M6.5 16h11"/>',
      "plus": '<path d="M5 12h14"/><path d="M12 5v14"/>',
      "gauge": '<path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>',
      "search": '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
      "download": '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>',
      "upload": '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" x2="12" y1="3" y2="15"/>',
      "pencil": '<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
      "trash-2": '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><line x1="10" x2="10" y1="11" y2="17"/><line x1="14" x2="14" y1="11" y2="17"/>',
      "shield-check": '<path d="M20 13c0 5-3.5 7.5-8 9-4.5-1.5-8-4-8-9V5l8-3 8 3z"/><path d="m9 12 2 2 4-4"/>',
      "save": '<path d="M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/><path d="M17 21v-8H7v8"/><path d="M7 3v5h8"/>',
      "x": '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
      "circle-check": '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>'
    };
    const icon = (name, className = "") => `<svg class="icon ${className}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ICONS.activity}</svg>`;
    document.querySelectorAll("[data-icon]").forEach(el => { el.innerHTML = icon(el.dataset.icon); });

    const state = { csrf: null, dashboard: null, management: null, logs: null, scheduleIndex: null, instanceIndex: null, timer: null, update: null, updatePolling: false, restoreBackupBase64: null, restorePreviewReady: false, s3RestoreKey: null, s3RestorePreviewReady: false, discoveredInstances: [], discoveryCredentials: null };
    const $ = id => document.getElementById(id);
    const esc = value => String(value ?? "").replace(/[&<>'"]/g, char => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[char]));
    const fmtDate = value => value ? new Date(value).toLocaleString("zh-CN", { hour12: false }) : "尚未运行";
    const fmtNum = (value, digits = 2) => value === null || value === undefined ? "--" : Number(value).toFixed(digits);

    async function api(path, options = {}) {
      const headers = { "Accept": "application/json", ...(options.headers || {}) };
      if (options.body && typeof options.body !== "string") {
        headers["Content-Type"] = "application/json";
        options.body = JSON.stringify(options.body);
      }
      if (state.csrf && options.method && options.method !== "GET") headers["X-CSRF-Token"] = state.csrf;
      const response = await fetch(path, { ...options, headers, credentials: "same-origin" });
      let data;
      try { data = await response.json(); } catch (_) { data = { error: `HTTP ${response.status}` }; }
      if (response.status === 401 && path !== "/api/login") showLogin();
      if (!response.ok) {
        const error = new Error(data.error || `请求失败 (${response.status})`);
        error.status = response.status;
        error.details = data.details;
        throw error;
      }
      return data;
    }

    function toast(message, isError = false) {
      $("toastText").textContent = message;
      $("toast").classList.toggle("error", isError);
      $("toastIcon").innerHTML = icon(isError ? "triangle-alert" : "circle-check");
      $("toast").hidden = false;
      clearTimeout(toast.timer);
      toast.timer = setTimeout(() => { $("toast").hidden = true; }, 4200);
    }

    function showLogin() {
      clearInterval(state.timer);
      state.timer = null;
      state.csrf = null;
      $("appView").hidden = true;
      $("loginView").hidden = false;
      setTimeout(() => $("username").focus(), 30);
    }

    function showApp() {
      $("loginView").hidden = true;
      $("appView").hidden = false;
      loadDashboard();
      loadManagement();
      resumeUpdateProgress().then(running => { if (!running) checkForUpdate(false); });
      clearInterval(state.timer);
      state.timer = setInterval(() => { if (!document.hidden) loadDashboard(false); }, 15000);
    }

    function statusInfo(status, paused) {
      if (paused) return { label: "已暂停", cls: "unknown" };
      if (status === "Running") return { label: "运行中", cls: "" };
      if (status === "Stopped") return { label: "已停止", cls: "stopped" };
      if (["Starting", "Stopping", "Pending"].includes(status)) return { label: status, cls: "transition" };
      return { label: status || "Unknown", cls: "unknown" };
    }

    function sparkline(points) {
      if (!points || !points.length) return `<div class="sparkline"><svg viewBox="0 0 320 58"><path d="M0 42 H320" stroke="#d9e1dc" stroke-width="1" stroke-dasharray="4 5"/><text x="8" y="26" fill="#89938e" font-size="11">等待流量样本</text></svg></div>`;
      const values = points.map(p => Number(p.value));
      const min = Math.min(...values), max = Math.max(...values), span = Math.max(max - min, .01);
      const chartLeft = 4, chartRight = 316, chartTop = 10, chartBottom = 48;
      const coords = values.map((value, i) => {
        const x = values.length === 1 ? 160 : i / (values.length - 1) * (chartRight - chartLeft) + chartLeft;
        const y = chartBottom - ((value - min) / span) * (chartBottom - chartTop);
        return { x: Number(x.toFixed(1)), y: Number(y.toFixed(1)) };
      });
      const polyline = coords.map(point => `${point.x},${point.y}`).join(" ");
      const hits = coords.map((point, index) => `<circle class="chart-hit" cx="${point.x}" cy="${point.y}" r="9" tabindex="0" data-point="${index}" data-x="${point.x}" aria-label="查看第 ${index + 1} 个检测样本"></circle><path class="chart-focus" d="M ${point.x} ${point.y} h .01"></path>`).join("");
      const latest = coords[coords.length - 1];
      return `<div class="sparkline"><svg viewBox="0 0 320 58" preserveAspectRatio="none"><path d="M4 53 H316" stroke="#e1e7e3" stroke-width="1"/>${coords.length > 1 ? `<polyline points="${polyline}" fill="none" stroke="#167c94" stroke-width="2.5" vector-effect="non-scaling-stroke" stroke-linejoin="round" stroke-linecap="round"/>` : ""}<path class="chart-point" d="M ${latest.x} ${latest.y} h .01"></path>${hits}</svg><div class="chart-tooltip" role="tooltip" hidden></div></div>`;
    }

    function instanceCard(item) {
      const status = statusInfo(item.status, item.paused);
      const percent = item.traffic_percent === null ? 0 : Math.max(0, Math.min(100, item.traffic_percent));
      const barClass = percent >= 100 ? "danger" : percent >= 85 ? "warn" : "";
      const bill = !item.billing_enabled ? "已关闭" : item.bill_error ? "查询失败" : item.bill_amount === null ? "--" : `${esc(item.bill_symbol)}${fmtNum(item.bill_amount)} ${esc(item.bill_currency || "")}`;
      const sched = item.schedule.enabled ? `${esc(item.schedule.start_time)} - ${esc(item.schedule.stop_time)}` : "已关闭";
      const next = item.schedule.next_at ? `${item.schedule.next_action === "start" ? "开机" : "关机"} ${fmtDate(item.schedule.next_at)}` : "无计划";
      const powerAction = item.status === "Running" ? "stop" : "start";
      const powerLabel = powerAction === "start" ? "开机" : "关机";
      return `<article class="instance-card" data-index="${item.index}">
        <div class="card-head">
          <div><h2 class="instance-name">${esc(item.name)}</h2><div class="instance-meta">${esc(item.region)} · ${esc(item.instance_id)}</div></div>
          <div class="card-head-tools">
            <div class="status-badge ${status.cls}"><span class="dot ${status.cls === "stopped" || status.cls === "error" ? "bad" : ""}"></span>${esc(status.label)}</div>
            <details class="instance-tools">
              <summary class="icon-button" title="单机设置" aria-label="${esc(item.name)} 单机设置">${icon("settings")}</summary>
              <div class="instance-menu" role="menu" aria-label="${esc(item.name)} 单机操作">
                <button class="menu-button" type="button" role="menuitem" data-action="power" data-power="${powerAction}" ${["Starting","Stopping","Pending"].includes(item.status) ? "disabled" : ""}>${icon("power")}<span>${powerLabel}</span></button>
                <button class="menu-button" type="button" role="menuitem" data-action="schedule">${icon("calendar-clock")}<span>定时计划</span></button>
                <button class="menu-button ${item.paused ? "" : "warning"}" type="button" role="menuitem" data-action="pause">${icon(item.paused ? "play" : "pause")}<span>${item.paused ? "恢复监控" : "暂停监控"}</span></button>
                <button class="menu-button" type="button" role="menuitem" data-action="edit">${icon("pencil")}<span>编辑配置</span></button>
                <button class="menu-button" type="button" role="menuitem" data-action="validate">${icon("shield-check")}<span>只读校验</span></button>
                <button class="menu-button" type="button" role="menuitem" data-action="logs">${icon("terminal")}<span>查看独立日志${item.instance_log_enabled ? "（已启用）" : ""}</span></button>
                <button class="menu-button danger" type="button" role="menuitem" data-action="delete">${icon("trash-2")}<span>删除监控实例</span></button>
              </div>
            </details>
          </div>
        </div>
        <div class="card-body">
          <div class="metric-grid">
            <div class="metric"><div class="metric-label">CDT 流量</div><div class="metric-value">${fmtNum(item.traffic_gb)} GB</div></div>
            <div class="metric"><div class="metric-label">关机阈值</div><div class="metric-value">${fmtNum(item.traffic_limit_gb)} GB</div></div>
            <div class="metric"><div class="metric-label">本月账单</div><div class="metric-value">${bill}</div></div>
            <div class="metric"><div class="metric-label">每日计划</div><div class="metric-value">${sched}</div></div>
          </div>
          <div class="traffic-row"><span>使用率</span><strong>${item.traffic_percent === null ? "--" : fmtNum(item.traffic_percent, 1) + "%"}</strong></div>
          <div class="progress"><span class="${barClass}" style="width:${percent}%"></span></div>
          ${sparkline(item.history)}
          <div class="instance-meta">下一动作：${esc(next)}</div>
        </div>
        <div class="result-line">${esc(item.message)}</div>
      </article>`;
    }

    function renderDashboard(data) {
      state.dashboard = data;
      $("appVersion").textContent = `Web Console v${data.version}`;
      $("lastUpdated").textContent = `服务器时间 ${fmtDate(data.now)} · 最后检测 ${fmtDate(data.service.last_finished_at)}`;
      $("summaryInstances").textContent = data.users.length;
      $("summaryRunning").textContent = data.users.filter(x => x.status === "Running" && !x.paused).length;
      $("summaryErrors").textContent = data.users.filter(x => x.level === "error").length;
      $("summaryCycles").textContent = data.service.cycle_count;
      const bad = data.service.stale || data.service.last_error_count > 0;
      $("serviceDot").classList.toggle("bad", bad);
      $("serviceText").textContent = data.service.stale ? "检测超时" : data.service.last_ok ? "服务正常" : "存在异常";
      const notices = [];
      if (data.service.stale) notices.push("后台检测超过预期间隔，请检查服务状态");
      if (data.service.telegram_error) notices.push(`Telegram：${data.service.telegram_error}`);
      if (data.job && data.job.error) notices.push(`手动检测：${data.job.error}`);
      $("notice").hidden = !notices.length;
      $("noticeText").textContent = notices.join("；");
      $("runButton").disabled = Boolean(data.job && data.job.running);
      $("dryRunButton").disabled = Boolean(data.job && data.job.running);
      $("runButton").innerHTML = data.job && data.job.running ? `${icon("refresh-cw", "spin")}检测中` : `${icon("play")}立即检测`;
      $("instances").innerHTML = data.users.length ? data.users.map(instanceCard).join("") : `<div class="empty"><div>${icon("server")}<p>暂无监控实例</p></div></div>`;
    }

    function setInlineResult(element, message, isError = false) {
      element.textContent = message;
      element.classList.toggle("error", isError);
      element.hidden = !message;
    }

    function renderManagement(data) {
      state.management = data;
      const selectedLogSource = $("logSource").value || "system";
      $("logSource").innerHTML = '<option value="system">系统总日志</option>' + data.instances.map(item => `<option value="${item.index}">${esc(item.name)} (${esc(item.instance_id)}) · ${item.instance_log_enabled ? "已启用" : "已关闭"}</option>`).join("");
      $("logSource").value = Array.from($("logSource").options).some(option => option.value === selectedLogSource) ? selectedLogSource : "system";
      const telegram = data.telegram;
      $("telegramCurrent").textContent = `当前：${telegram.connection_description} · Bot 控制${telegram.control_enabled ? "已开启" : "已关闭"}`;
      $("connectionDescription").textContent = telegram.connection_description;
      $("tgToken").value = "";
      $("tgToken").placeholder = telegram.bot_token_configured ? "已保存，留空不修改" : "尚未保存，请输入 Bot Token";
      $("tgChatId").value = telegram.chat_id;
      $("tgTimeout").value = telegram.timeout_seconds;
      $("tgRetries").value = telegram.retries;
      $("tgControlEnabled").checked = telegram.control_enabled;
      $("tgControlAdmins").value = telegram.control_admin_ids.join(",");
      $("tgControlHint").textContent = telegram.control_effective_admin_ids.length
        ? `当前授权：${telegram.control_effective_admin_ids.join(", ")}${telegram.control_uses_chat_id ? "（使用 Chat ID）" : ""}`
        : "当前没有有效管理员，Bot 不会接受控制命令";
      updateTelegramControlFields();
      const mode = document.querySelector(`input[name="connectionMode"][value="${telegram.connection_mode}"]`) || document.querySelector('input[name="connectionMode"][value="direct"]');
      mode.checked = true;
      $("proxyUrl").value = "";
      $("proxyUrl").placeholder = telegram.proxy_configured ? "已保存，留空不修改" : "请输入代理地址";
      $("apiBaseUrl").value = "";
      $("apiBaseUrl").placeholder = telegram.api_base_configured ? "已保存，留空不修改" : "https://example.com";
      $("nodeSelect").innerHTML = telegram.nodes.length ? telegram.nodes.map(node => `<option value="${node.index}" ${node.active ? "selected" : ""}>${esc(node.description)}${node.active ? "（当前）" : ""}</option>`).join("") : '<option value="">尚未保存节点</option>';
      $("nodeCount").textContent = `${telegram.nodes.length} 个节点`;
      $("nodeList").innerHTML = telegram.nodes.length ? telegram.nodes.map(node => `<div class="node-row" data-node-index="${node.index}"><div><div class="node-name">${esc(node.description)}</div><div class="muted small">节点 #${node.index + 1} ${node.active ? '<span class="active-mark">· 当前使用</span>' : ""}</div></div><div class="node-actions"><button class="button secondary" type="button" data-node-action="test">${icon("gauge")}测试</button><button class="button primary" type="button" data-node-action="select">${icon("shield-check")}选用</button><button class="button danger" type="button" data-node-action="delete">${icon("trash-2")}删除</button></div></div>`).join("") : '<div class="node-row muted">尚未保存节点</div>';
      updateConnectionFields();

      const settings = data.settings;
      $("intervalSeconds").value = settings.interval_seconds;
      $("notificationMode").value = settings.notification_mode;
      $("forceIpv4").checked = settings.force_ipv4;
      $("notifyOnStart").checked = settings.notify_on_daemon_start;
      $("startWait").value = settings.start_wait_seconds;
      $("stopWait").value = settings.stop_wait_seconds;
      $("pollSeconds").value = settings.start_poll_seconds;
      $("watchdogEnabled").checked = settings.watchdog.enabled;
      $("watchdogTimeout").value = settings.watchdog.timeout_seconds;
      $("watchdogFailures").value = settings.watchdog.failure_threshold;

      const web = data.web;
      $("webEnabled").checked = web.enabled;
      $("webHost").value = web.host;
      $("webPort").value = web.port;
      $("webUsername").value = web.username;
      $("webPassword").value = "";
      $("webPasswordConfirm").value = "";
      $("webPassword").placeholder = web.password_configured ? "已保存，留空不修改" : "至少 8 个字符";
      updateWebWarning();
      $("systemBackend").textContent = data.backend;
      $("systemLocalIp").textContent = web.local_ip || "未检测到";
      $("systemBrowserUrl").textContent = web.browser_url;
      $("systemCurrentVersion").textContent = `v${data.version}`;
      $("updateCurrentVersion").textContent = `v${data.version}`;
      $("rollbackSnapshot").innerHTML = data.rollback_snapshots.length ? data.rollback_snapshots.map(item => `<option value="${esc(item.name)}">${esc(item.name)} · ${Math.ceil(item.size / 1024)} KiB</option>`).join("") : '<option value="">没有可用快照</option>';
      $("rollbackButton").disabled = !data.rollback_snapshots.length;
      const s3 = data.s3_backup;
      $("s3Enabled").checked = s3.enabled;
      $("s3Bucket").value = s3.bucket;
      $("s3Region").value = s3.region;
      $("s3Endpoint").value = s3.endpoint_url;
      $("s3Prefix").value = s3.prefix;
      $("s3AddressingStyle").value = s3.addressing_style;
      $("s3IamRole").checked = s3.uses_iam_role;
      $("s3AccessKey").value = "";
      $("s3SecretKey").value = "";
      $("s3SessionToken").value = "";
      $("s3ClearSessionToken").checked = false;
      $("s3BackupPassword").value = "";
      $("s3KmsKey").value = "";
      $("s3AccessKey").placeholder = s3.access_key_configured ? "已保存，留空不修改" : "请输入 Access Key ID";
      $("s3SecretKey").placeholder = s3.access_key_configured ? "已保存，留空不修改" : "请输入 Secret Access Key";
      $("s3SessionToken").placeholder = s3.session_token_configured ? "已保存，留空不修改" : "长期密钥留空";
      $("s3BackupPassword").placeholder = s3.backup_password_configured ? "已保存，留空不修改" : "至少 8 个字符";
      $("s3Schedule").value = s3.schedule;
      $("s3Time").value = s3.time;
      $("s3Weekday").value = String(s3.weekday);
      $("s3Retention").value = s3.retention;
      $("s3IncludeState").checked = s3.include_state;
      $("s3IncludeLogs").checked = s3.include_logs;
      $("s3Notification").value = s3.notification_mode;
      $("s3Encryption").value = s3.server_side_encryption;
      $("s3KmsKey").placeholder = s3.kms_key_configured ? "已保存，留空不修改" : "请输入 KMS Key ID 或 ARN";
      $("s3BackupStatus").textContent = s3.enabled ? `已启用 · 最近成功 ${fmtDate(s3.status.last_success_at)}` : "已关闭";
      setInlineResult($("s3Result"), s3.status.last_error ? `最近失败：${s3.status.last_error}` : "", Boolean(s3.status.last_error));
      updateS3Fields();
    }

    function downloadBase64(filename, encoded) {
      const bytes = Uint8Array.from(atob(encoded), char => char.charCodeAt(0));
      const url = URL.createObjectURL(new Blob([bytes], { type: "application/json" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = filename;
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    }

    function fileAsBase64(file) {
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onerror = () => reject(new Error("无法读取备份文件"));
        reader.onload = () => resolve(String(reader.result).split(",", 2)[1] || "");
        reader.readAsDataURL(file);
      });
    }

    function discoveryPayload() {
      return {
        ak: $("discoverAk").value.trim(),
        sk: $("discoverSk").value.trim(),
        regions: $("discoverRegions").value.trim(),
        tag_key: $("discoverTagKey").value.trim(),
        tag_value: $("discoverTagValue").value.trim(),
      };
    }

    function renderDiscoveredInstances(items) {
      $("discoveryList").innerHTML = items.length ? items.map((item, index) => `<label class="node-row"><input type="checkbox" data-discovery-index="${index}" ${item.already_configured ? "disabled" : "checked"}><div><div class="node-name">${esc(item.name)} · ${esc(item.status)}</div><div class="muted small">${esc(item.region)} · ${esc(item.instance_id)}${item.public_ip ? ` · ${esc(item.public_ip)}` : ""}${item.already_configured ? " · 已配置" : ""}</div></div></label>`).join("") : '<div class="node-row muted">没有发现符合条件的 ECS</div>';
      $("importInstancesButton").disabled = !items.some(item => !item.already_configured);
    }

    async function loadDashboard(showErrors = true) {
      try { renderDashboard(await api("/api/dashboard")); }
      catch (error) { if (showErrors) toast(error.message, true); }
    }

    async function loadManagement(showErrors = true) {
      try { renderManagement(await api("/api/management")); }
      catch (error) { if (showErrors) toast(error.message, true); }
    }

    async function loadLogs() {
      $("logView").textContent = "正在读取...";
      try {
        const selected = $("logSource").value || "system";
        const suffix = selected === "system" ? "" : `&instance=${encodeURIComponent(selected)}`;
        const data = await api(`/api/logs?limit=200${suffix}`);
        state.logs = data;
        $("logsDescription").textContent = `${data.name}${data.instance_id ? ` (${data.instance_id})` : ""} · 最近 200 行`;
        $("instanceLogToggle").hidden = !data.toggle_available;
        $("instanceLogToggle").classList.toggle("warning", data.enabled);
        $("instanceLogToggleText").textContent = data.enabled ? "停用独立日志" : "启用独立日志";
        const emptyText = data.source === "instance" && !data.enabled ? "独立日志已关闭，且尚无历史记录。" : "日志尚未生成。";
        $("logView").textContent = data.lines.length ? data.lines.join("\n") : emptyText;
        $("logView").scrollTop = $("logView").scrollHeight;
      }
      catch (error) { $("logView").textContent = error.message; }
    }

    function currentConnectionMode() {
      return document.querySelector('input[name="connectionMode"]:checked')?.value || "direct";
    }

    function updateConnectionFields() {
      const mode = currentConnectionMode();
      $("proxyField").hidden = !["socks5", "http"].includes(mode);
      $("nodeField").hidden = mode !== "node";
      $("apiProxyField").hidden = mode !== "api_proxy";
    }

    function updateTelegramControlFields() {
      $("tgControlAdminsField").hidden = !$("tgControlEnabled").checked;
    }

    function connectionPayload(save) {
      const mode = currentConnectionMode();
      const body = { connection_mode: mode, save };
      if (["socks5", "http"].includes(mode)) body.proxy_url = $("proxyUrl").value.trim();
      if (mode === "api_proxy") body.api_base_url = $("apiBaseUrl").value.trim();
      if (mode === "node") body.node_index = Number($("nodeSelect").value);
      return body;
    }

    function telegramTestText(result) {
      return `测试成功：@${result.username} · ${result.latency_ms} ms（${result.latency_attempts} 次平均）· ${result.connection}`;
    }

    function updateWebWarning() {
      const publicHttp = $("webHost").value === "0.0.0.0";
      $("webWarning").textContent = publicHttp ? "所有网卡监听允许直接 HTTP 访问，用户名和密码会以明文经过网络；建议配置防火墙或 HTTPS 反向代理。" : "仅本机监听适合 SSH 隧道或 HTTPS 反向代理。";
      $("webWarning").classList.toggle("warning-text", publicHttp);
    }

    function updateS3Fields() {
      $("s3CredentialFields").hidden = $("s3IamRole").checked;
      $("s3WeekdayField").hidden = $("s3Schedule").value !== "weekly";
      $("s3KmsField").hidden = $("s3Encryption").value !== "aws:kms";
    }

    function s3SettingsPayload() {
      return {
        enabled: $("s3Enabled").checked,
        bucket: $("s3Bucket").value.trim(),
        region: $("s3Region").value.trim(),
        endpoint_url: $("s3Endpoint").value.trim(),
        prefix: $("s3Prefix").value.trim(),
        addressing_style: $("s3AddressingStyle").value,
        use_iam_role: $("s3IamRole").checked,
        access_key_id: $("s3AccessKey").value.trim(),
        secret_access_key: $("s3SecretKey").value.trim(),
        session_token: $("s3SessionToken").value.trim(),
        clear_session_token: $("s3ClearSessionToken").checked,
        backup_password: $("s3BackupPassword").value,
        schedule: $("s3Schedule").value,
        time: $("s3Time").value,
        weekday: Number($("s3Weekday").value),
        retention: Number($("s3Retention").value),
        include_state: $("s3IncludeState").checked,
        include_logs: $("s3IncludeLogs").checked,
        notification_mode: $("s3Notification").value,
        server_side_encryption: $("s3Encryption").value,
        kms_key_id: $("s3KmsKey").value.trim(),
      };
    }

    async function loadS3Backups() {
      $("s3ListButton").disabled = true;
      setInlineResult($("s3Result"), "正在读取云端备份...");
      try {
        const data = await api("/api/s3-backup/list");
        $("s3BackupList").innerHTML = data.backups.length ? data.backups.map(item => `<div class="node-row" data-s3-key="${esc(item.key)}"><div><div class="node-name">${esc(item.name)}</div><div class="muted small">${(item.size / 1048576).toFixed(2)} MiB · ${esc(fmtDate(item.modified_at))}</div></div><div class="node-actions"><button class="button secondary" type="button" data-s3-action="preview">${icon("search")}预览</button><button class="button warning" type="button" data-s3-action="restore">${icon("refresh-cw")}恢复</button></div></div>`).join("") : '<div class="node-row muted">云端没有 Aliyun Guard 加密备份</div>';
        setInlineResult($("s3Result"), `已读取 ${data.backups.length} 份云端备份`);
      } catch (error) { setInlineResult($("s3Result"), error.message, true); }
      finally { $("s3ListButton").disabled = false; }
    }

    function billingFieldsVisibility() {
      const enabled = $("billingEnabled").checked;
      $("billingSiteField").hidden = !enabled;
      $("billingCustomFields").hidden = !enabled || $("billingSite").value !== "custom";
    }

    function openInstanceDialog(index = null) {
      state.instanceIndex = index;
      const existing = index === null ? null : state.management?.instances.find(item => item.index === index);
      $("instanceDialogTitle").textContent = existing ? `编辑 ${existing.name}` : "添加监控实例";
      $("instanceName").value = existing?.name || "";
      $("instanceRegion").value = existing?.region || "";
      $("instanceId").value = existing?.instance_id || "";
      $("instanceAk").value = "";
      $("instanceSk").value = "";
      $("instanceAk").placeholder = existing?.access_key_configured ? "已保存，留空不修改" : "请输入 AccessKey ID";
      $("instanceSk").placeholder = existing?.secret_key_configured ? "已保存，留空不修改" : "请输入 AccessKey Secret";
      $("trafficLimit").value = existing?.traffic_limit_gb ?? 180;
      $("actionsEnabled").checked = existing?.actions_enabled ?? true;
      $("instanceLogEnabled").checked = existing?.instance_log_enabled ?? false;
      $("billingEnabled").checked = existing?.billing.enabled ?? true;
      $("billingSite").value = existing?.billing.site || "china";
      $("billingEndpoint").value = existing?.billing.endpoint || "";
      $("billingRegion").value = existing?.billing.region || "";
      $("billingCurrencyCode").value = existing?.billing.currency_code || "";
      $("billingCurrencySymbol").value = existing?.billing.currency_symbol || "";
      $("instanceScheduleEnabled").checked = existing?.schedule.enabled ?? false;
      $("instanceStartTime").value = existing?.schedule.start_time || "08:00";
      $("instanceStopTime").value = existing?.schedule.stop_time || "23:00";
      setInlineResult($("instanceValidation"), "");
      billingFieldsVisibility();
      $("instanceDialog").showModal();
    }

    function instancePayload(forceSave = false) {
      return {
        name: $("instanceName").value.trim(),
        ak: $("instanceAk").value.trim(),
        sk: $("instanceSk").value.trim(),
        region: $("instanceRegion").value.trim(),
        instance_id: $("instanceId").value.trim(),
        traffic_limit_gb: Number($("trafficLimit").value),
        actions_enabled: $("actionsEnabled").checked,
        instance_log_enabled: $("instanceLogEnabled").checked,
        billing: {
          enabled: $("billingEnabled").checked,
          site: $("billingSite").value,
          endpoint: $("billingEndpoint").value.trim(),
          region: $("billingRegion").value.trim(),
          currency_code: $("billingCurrencyCode").value.trim(),
          currency_symbol: $("billingCurrencySymbol").value.trim(),
        },
        schedule: {
          enabled: $("instanceScheduleEnabled").checked,
          start_time: $("instanceStartTime").value,
          stop_time: $("instanceStopTime").value,
        },
        force_save: forceSave,
      };
    }

    function validationText(result) {
      if (!result) return "未返回校验结果";
      const details = [];
      if (result.traffic_gb !== null && result.traffic_gb !== undefined) details.push(`CDT ${fmtNum(result.traffic_gb)} GB`);
      if (result.status) details.push(`ECS ${result.status}`);
      if (result.billing_enabled && result.bill_amount !== null && result.bill_amount !== undefined) details.push(`账单 ${fmtNum(result.bill_amount)} ${result.bill_currency || ""}`);
      if (result.errors?.length) details.push(result.errors.join("；"));
      return `${result.ok ? "校验成功" : "校验失败"}${details.length ? "：" + details.join(" · ") : ""}`;
    }

    function actionText(point) {
      const labels = {
        start: "保活开机",
        stop: "流量阈值关机",
        schedule_start: "定时开机",
        schedule_stop: "定时关机",
        manual_start: "网页手动开机",
        manual_stop: "网页手动关机",
      };
      if (!point.action || point.action === "none") return "仅检测，无动作";
      const label = labels[point.action] || point.action;
      return point.action_performed ? `${label}（已执行）` : `${label}（未执行）`;
    }

    function showChartTooltip(target) {
      const card = target.closest("[data-index]");
      const item = state.dashboard?.users.find(value => value.index === Number(card?.dataset.index));
      const point = item?.history?.[Number(target.dataset.point)];
      const container = target.closest(".sparkline");
      const tooltip = container?.querySelector(".chart-tooltip");
      if (!point || !tooltip) return;
      const before = point.status_before;
      const after = point.status || "Unknown";
      const status = before && before !== after ? `${before} → ${after}` : after;
      tooltip.innerHTML = `<div class="tooltip-title">${esc(fmtDate(point.at))}</div><div class="tooltip-row"><span>当时流量</span><strong>${fmtNum(point.value)} GB</strong></div><div class="tooltip-row"><span>ECS 状态</span><strong>${esc(status)}</strong></div><div class="tooltip-row"><span>执行动作</span><strong>${esc(actionText(point))}</strong></div><div class="tooltip-row"><span>检测结果</span><strong>${esc(point.message || "历史样本无详细结果")}</strong></div>`;
      tooltip.hidden = false;
      requestAnimationFrame(() => {
        const width = container.clientWidth;
        const desired = Number(target.dataset.x) / 320 * width;
        const left = Math.max(4, Math.min(width - tooltip.offsetWidth - 4, desired - tooltip.offsetWidth / 2));
        tooltip.style.left = `${left}px`;
        tooltip.style.setProperty("--tip-arrow", `${Math.max(12, Math.min(tooltip.offsetWidth - 12, desired - left))}px`);
      });
    }

    function hideChartTooltip(target) {
      const tooltip = target.closest(".sparkline")?.querySelector(".chart-tooltip");
      if (tooltip) tooltip.hidden = true;
    }

    document.querySelectorAll(".tab-button").forEach(button => button.addEventListener("click", () => {
      document.querySelectorAll(".tab-button").forEach(x => x.classList.toggle("active", x === button));
      document.querySelectorAll(".tab-panel").forEach(x => x.hidden = x.id !== `${button.dataset.tab}Tab`);
      if (button.dataset.tab === "logs") loadLogs();
      if (["telegram", "settings", "system"].includes(button.dataset.tab)) loadManagement(false);
    }));

    $("loginForm").addEventListener("submit", async event => {
      event.preventDefault();
      $("loginError").textContent = "";
      const submit = event.currentTarget.querySelector("button[type=submit]");
      submit.disabled = true;
      try { const data = await api("/api/login", { method: "POST", body: { username: $("username").value, password: $("password").value } }); state.csrf = data.csrf; $("password").value = ""; showApp(); }
      catch (error) { $("loginError").textContent = error.message; }
      finally { submit.disabled = false; }
    });

    $("togglePassword").addEventListener("click", () => { const input = $("password"); input.type = input.type === "password" ? "text" : "password"; $("togglePassword").innerHTML = icon(input.type === "password" ? "eye" : "eye-off"); });
    $("refreshButton").addEventListener("click", async () => { $("refreshButton").querySelector("svg").classList.add("spin"); await Promise.all([loadDashboard(), loadManagement()]); $("refreshButton").querySelector("svg").classList.remove("spin"); });
    $("logsRefresh").addEventListener("click", loadLogs);
    $("logSource").addEventListener("change", loadLogs);
    $("instanceLogToggle").addEventListener("click", async () => {
      if (!state.logs?.toggle_available) return;
      const enabled = !state.logs.enabled;
      $("instanceLogToggle").disabled = true;
      try {
        await api(`/api/instances/${state.logs.index}/logging`, { method: "POST", body: { enabled } });
        toast(enabled ? "该实例独立日志已启用" : "该实例独立日志已停用，历史日志已保留");
        await Promise.all([loadDashboard(false), loadManagement(false)]);
        await loadLogs();
      } catch (error) { toast(error.message, true); }
      finally { $("instanceLogToggle").disabled = false; }
    });
    $("logoutButton").addEventListener("click", async () => { try { await api("/api/logout", { method: "POST", body: {} }); } catch (_) {} showLogin(); });
    $("runButton").addEventListener("click", async () => { try { await api("/api/run", { method: "POST", body: { dry_run: false } }); toast("检测任务已启动"); loadDashboard(false); } catch (error) { toast(error.message, true); } });
    $("dryRunButton").addEventListener("click", async () => { try { await api("/api/run", { method: "POST", body: { dry_run: true } }); toast("演练检测已启动，不会执行开关机"); loadDashboard(false); } catch (error) { toast(error.message, true); } });
    $("addInstanceButton").addEventListener("click", async () => { if (!state.management) await loadManagement(); openInstanceDialog(); });

    $("instances").addEventListener("click", async event => {
      const button = event.target.closest("button[data-action]");
      if (!button) return;
      button.closest(".instance-tools")?.removeAttribute("open");
      const card = button.closest("[data-index]");
      const index = Number(card.dataset.index);
      const item = state.dashboard.users.find(x => x.index === index);
      if (!item) return;
      if (button.dataset.action === "edit") {
        if (!state.management) await loadManagement();
        openInstanceDialog(index);
        return;
      }
      if (button.dataset.action === "logs") {
        if (!state.management) await loadManagement();
        $("logSource").value = String(index);
        document.querySelector('.tab-button[data-tab="logs"]').click();
        return;
      }
      if (button.dataset.action === "validate") {
        button.disabled = true;
        try {
          const data = await api(`/api/instances/${index}/validate`, { method: "POST", body: {} });
          toast(validationText(data.result), !data.result.ok);
        } catch (error) { toast(error.message, true); }
        finally { button.disabled = false; }
        return;
      }
      if (button.dataset.action === "delete") {
        if (!confirm(`确认删除 ${item.name} (${item.instance_id})？此操作不会删除阿里云 ECS。`)) return;
        button.disabled = true;
        try {
          await api(`/api/instances/${index}/delete`, { method: "POST", body: { instance_id: item.instance_id } });
          toast("监控实例已删除");
          await Promise.all([loadDashboard(), loadManagement()]);
        } catch (error) { toast(error.message, true); }
        finally { button.disabled = false; }
        return;
      }
      if (button.dataset.action === "schedule") {
        state.scheduleIndex = index;
        $("scheduleTitle").textContent = `${item.name} · 定时开关机`;
        $("scheduleEnabled").checked = item.schedule.enabled;
        $("startTime").value = item.schedule.start_time;
        $("stopTime").value = item.schedule.stop_time;
        $("scheduleDialog").showModal();
        return;
      }
      if (button.dataset.action === "pause") {
        const paused = !item.paused;
        if (!confirm(`确认${paused ? "暂停" : "恢复"} ${item.name}？`)) return;
        button.disabled = true;
        try { await api(`/api/instances/${index}/pause`, { method: "POST", body: { paused } }); toast(paused ? "实例监控已暂停" : "实例监控已恢复"); await loadDashboard(); } catch (error) { toast(error.message, true); } finally { button.disabled = false; }
        return;
      }
      if (button.dataset.action === "power") {
        const action = button.dataset.power;
        if (!confirm(`确认${action === "start" ? "开机" : "关机"} ${item.name}？`)) return;
        button.disabled = true;
        try { const data = await api(`/api/instances/${index}/power`, { method: "POST", body: { action } }); toast(data.result.notification_error ? `操作成功，Telegram 通知失败：${data.result.notification_error}` : "实例操作已完成", Boolean(data.result.notification_error)); await loadDashboard(); } catch (error) { toast(error.message, true); } finally { button.disabled = false; }
      }
    });

    $("instances").addEventListener("pointerover", event => { const target = event.target.closest(".chart-hit"); if (target) showChartTooltip(target); });
    $("instances").addEventListener("pointerout", event => { const target = event.target.closest(".chart-hit"); if (target && !target.contains(event.relatedTarget)) hideChartTooltip(target); });
    $("instances").addEventListener("focusin", event => { const target = event.target.closest(".chart-hit"); if (target) showChartTooltip(target); });
    $("instances").addEventListener("focusout", event => { const target = event.target.closest(".chart-hit"); if (target) hideChartTooltip(target); });
    $("instances").addEventListener("pointerdown", event => { const target = event.target.closest(".chart-hit"); if (target) { event.stopPropagation(); showChartTooltip(target); } });
    document.addEventListener("pointerdown", event => { if (!event.target.closest(".sparkline")) document.querySelectorAll(".chart-tooltip").forEach(element => { element.hidden = true; }); });
    document.addEventListener("click", event => { document.querySelectorAll(".instance-tools[open]").forEach(element => { if (!element.contains(event.target)) element.removeAttribute("open"); }); });

    document.querySelectorAll("[data-close-dialog]").forEach(button => button.addEventListener("click", () => button.closest("dialog").close()));
    $("scheduleForm").addEventListener("submit", async event => {
      event.preventDefault();
      const enabled = $("scheduleEnabled").checked, start_time = $("startTime").value, stop_time = $("stopTime").value;
      if (enabled && start_time === stop_time) { toast("开机时间和关机时间不能相同", true); return; }
      try { await api(`/api/instances/${state.scheduleIndex}/schedule`, { method: "POST", body: { enabled, start_time, stop_time } }); $("scheduleDialog").close(); toast("定时计划已保存"); await Promise.all([loadDashboard(), loadManagement()]); } catch (error) { toast(error.message, true); }
    });

    $("billingEnabled").addEventListener("change", billingFieldsVisibility);
    $("billingSite").addEventListener("change", billingFieldsVisibility);
    $("instanceForm").addEventListener("submit", async event => {
      event.preventDefault();
      const submit = event.currentTarget.querySelector('button[type="submit"]');
      const save = async forceSave => {
        const path = state.instanceIndex === null ? "/api/instances" : `/api/instances/${state.instanceIndex}`;
        const data = await api(path, { method: "POST", body: instancePayload(forceSave) });
        setInlineResult($("instanceValidation"), validationText(data.result.validation), !data.result.validation.ok);
        $("instanceDialog").close();
        toast("实例配置已保存");
        await Promise.all([loadDashboard(), loadManagement()]);
      };
      submit.disabled = true;
      try { await save(false); }
      catch (error) {
        setInlineResult($("instanceValidation"), error.details ? validationText(error.details) : error.message, true);
        if (error.status === 422 && error.details && confirm("实例校验失败。仍然保存并让定时检测继续报告错误？")) {
          try { await save(true); } catch (forceError) { setInlineResult($("instanceValidation"), forceError.message, true); }
        }
      } finally { submit.disabled = false; }
    });

    $("settingsForm").addEventListener("submit", async event => {
      event.preventDefault();
      try {
        await api("/api/settings", { method: "POST", body: {
          interval_seconds: Number($("intervalSeconds").value),
          notification_mode: $("notificationMode").value,
          force_ipv4: $("forceIpv4").checked,
          notify_on_daemon_start: $("notifyOnStart").checked,
          start_wait_seconds: Number($("startWait").value),
          stop_wait_seconds: Number($("stopWait").value),
          start_poll_seconds: Number($("pollSeconds").value),
          watchdog: { enabled: $("watchdogEnabled").checked, timeout_seconds: Number($("watchdogTimeout").value), failure_threshold: Number($("watchdogFailures").value) },
        } });
        toast("全局设置已保存");
        await Promise.all([loadDashboard(), loadManagement()]);
      } catch (error) { toast(error.message, true); }
    });

    $("backupCreateForm").addEventListener("submit", async event => {
      event.preventDefault();
      const button = event.currentTarget.querySelector('button[type="submit"]');
      button.disabled = true;
      try {
        const data = await api("/api/backup/create", { method: "POST", body: { password: $("backupPassword").value, include_state: $("backupState").checked, include_logs: $("backupLogs").checked } });
        downloadBase64(data.result.filename, data.result.backup_base64);
        $("backupPassword").value = "";
        toast(`加密备份已创建：${data.result.filename}`);
      } catch (error) { toast(error.message, true); }
      finally { button.disabled = false; }
    });

    $("restoreFile").addEventListener("change", () => { state.restorePreviewReady = false; state.restoreBackupBase64 = null; $("restoreBackupButton").disabled = true; setInlineResult($("restorePreview"), ""); });
    $("restorePassword").addEventListener("input", () => { state.restorePreviewReady = false; $("restoreBackupButton").disabled = true; });
    $("previewRestoreButton").addEventListener("click", async () => {
      const file = $("restoreFile").files[0];
      if (!file) return toast("请选择备份文件", true);
      $("previewRestoreButton").disabled = true;
      try {
        state.restoreBackupBase64 = await fileAsBase64(file);
        const data = await api("/api/backup/preview", { method: "POST", body: { backup_base64: state.restoreBackupBase64, password: $("restorePassword").value } });
        const changed = data.result.files.filter(item => item.action !== "unchanged");
        setInlineResult($("restorePreview"), `备份包含 ${data.result.summary.instances || 0} 个实例、${data.result.summary.nodes || 0} 个节点；${changed.length} 个文件将新增或替换：${changed.map(item => item.path).join("、") || "无变化"}`);
        state.restorePreviewReady = true;
        $("restoreBackupButton").disabled = false;
      } catch (error) { state.restorePreviewReady = false; $("restoreBackupButton").disabled = true; setInlineResult($("restorePreview"), error.message, true); }
      finally { $("previewRestoreButton").disabled = false; }
    });
    $("backupRestoreForm").addEventListener("submit", async event => {
      event.preventDefault();
      if (!state.restorePreviewReady || !state.restoreBackupBase64) return;
      if (!confirm("确认按预览结果恢复？当前配置会先自动创建安全备份。")) return;
      try {
        await api("/api/backup/restore", { method: "POST", body: { backup_base64: state.restoreBackupBase64, password: $("restorePassword").value, include_logs: $("restoreLogs").checked } });
        toast("备份已恢复，后台服务即将重启");
        state.restorePreviewReady = false;
        $("restoreBackupButton").disabled = true;
      } catch (error) { toast(error.message, true); }
    });
    $("s3IamRole").addEventListener("change", updateS3Fields);
    $("s3Schedule").addEventListener("change", updateS3Fields);
    $("s3Encryption").addEventListener("change", updateS3Fields);
    $("s3BackupForm").addEventListener("submit", async event => {
      event.preventDefault();
      const button = event.currentTarget.querySelector('button[type="submit"]');
      button.disabled = true;
      try {
        await api("/api/s3-backup/settings", { method: "POST", body: s3SettingsPayload() });
        toast("S3 自动备份设置已保存");
        await loadManagement(false);
      } catch (error) { setInlineResult($("s3Result"), error.message, true); }
      finally { button.disabled = false; }
    });
    $("s3TestButton").addEventListener("click", async () => {
      $("s3TestButton").disabled = true;
      setInlineResult($("s3Result"), "正在测试 S3 连接...");
      try {
        const data = await api("/api/s3-backup/test", { method: "POST", body: s3SettingsPayload() });
        setInlineResult($("s3Result"), `连接成功：${data.result.bucket} · ${data.result.endpoint} · ${data.result.latency_ms} ms`);
      } catch (error) { setInlineResult($("s3Result"), error.message, true); }
      finally { $("s3TestButton").disabled = false; }
    });
    $("s3RunButton").addEventListener("click", async () => {
      if (!confirm("立即使用已保存的 S3 设置创建并上传一份加密备份？")) return;
      $("s3RunButton").disabled = true;
      setInlineResult($("s3Result"), "正在创建加密备份并上传...");
      try {
        const data = await api("/api/s3-backup/run", { method: "POST", body: {} });
        setInlineResult($("s3Result"), `上传成功：s3://${data.result.bucket}/${data.result.key}；清理 ${data.result.deleted.length} 份旧备份`);
        await loadS3Backups();
      } catch (error) { setInlineResult($("s3Result"), error.message, true); }
      finally { $("s3RunButton").disabled = false; }
    });
    $("s3ListButton").addEventListener("click", loadS3Backups);
    $("s3BackupList").addEventListener("click", async event => {
      const button = event.target.closest("[data-s3-action]");
      const row = button?.closest("[data-s3-key]");
      if (!button || !row) return;
      const key = row.dataset.s3Key;
      if (button.dataset.s3Action === "preview") {
        button.disabled = true;
        setInlineResult($("s3Result"), "正在下载并验证云端备份...");
        try {
          const data = await api("/api/s3-backup/preview", { method: "POST", body: { key } });
          const changed = data.result.files.filter(item => item.action !== "unchanged");
          state.s3RestoreKey = key;
          state.s3RestorePreviewReady = true;
          setInlineResult($("s3Result"), `已预览 ${row.querySelector(".node-name").textContent}：${data.result.summary.instances || 0} 个实例，${changed.length} 个文件将新增或替换：${changed.map(item => item.path).join("、") || "无变化"}`);
        } catch (error) { state.s3RestoreKey = null; state.s3RestorePreviewReady = false; setInlineResult($("s3Result"), error.message, true); }
        finally { button.disabled = false; }
        return;
      }
      if (!state.s3RestorePreviewReady || state.s3RestoreKey !== key) {
        setInlineResult($("s3Result"), "请先预览这份云端备份，再执行恢复。", true);
        return;
      }
      if (!confirm("确认按刚才的差异预览恢复这份云端备份？当前配置会先自动创建安全备份。")) return;
      button.disabled = true;
      try {
        await api("/api/s3-backup/restore", { method: "POST", body: { key, include_logs: true } });
        state.s3RestorePreviewReady = false;
        state.s3RestoreKey = null;
        toast("云端备份已恢复，后台服务即将重启");
      } catch (error) { setInlineResult($("s3Result"), error.message, true); button.disabled = false; }
    });
    $("rollbackButton").addEventListener("click", async () => {
      const snapshot = $("rollbackSnapshot").value;
      if (!snapshot || !confirm(`确认回滚到 ${snapshot}？配置、状态和日志不会改变。`)) return;
      $("rollbackButton").disabled = true;
      try { await api("/api/rollback", { method: "POST", body: { snapshot } }); toast("程序已回滚，后台服务即将重启"); }
      catch (error) { toast(error.message, true); $("rollbackButton").disabled = false; }
    });

    $("discoverInstanceButton").addEventListener("click", () => {
      state.discoveredInstances = [];
      state.discoveryCredentials = null;
      $("discoverAk").value = ""; $("discoverSk").value = "";
      renderDiscoveredInstances([]);
      setInlineResult($("discoveryResult"), "");
      $("discoveryDialog").showModal();
    });
    $("scanInstancesButton").addEventListener("click", async () => {
      const credentials = discoveryPayload();
      $("scanInstancesButton").disabled = true;
      setInlineResult($("discoveryResult"), "正在跨 Region 扫描 ECS...");
      try {
        const data = await api("/api/discovery/scan", { method: "POST", body: credentials });
        state.discoveredInstances = data.result.instances;
        state.discoveryCredentials = { ak: credentials.ak, sk: credentials.sk };
        renderDiscoveredInstances(state.discoveredInstances);
        setInlineResult($("discoveryResult"), `发现 ${data.result.instances.length} 台 ECS；${data.result.errors.length} 个 Region 扫描失败`, Boolean(data.result.errors.length));
      } catch (error) { setInlineResult($("discoveryResult"), error.message, true); }
      finally { $("scanInstancesButton").disabled = false; }
    });
    $("discoveryForm").addEventListener("submit", async event => {
      event.preventDefault();
      if (!state.discoveryCredentials) return;
      const selected = Array.from(document.querySelectorAll("[data-discovery-index]:checked")).map(input => state.discoveredInstances[Number(input.dataset.discoveryIndex)]);
      if (!selected.length) return toast("请选择至少一个实例", true);
      $("importInstancesButton").disabled = true;
      try {
        const data = await api("/api/discovery/import", { method: "POST", body: { ...state.discoveryCredentials, instances: selected, traffic_limit_gb: Number($("discoverLimit").value), actions_enabled: $("discoverActions").checked, billing_site: $("discoverBillingSite").value } });
        $("discoveryDialog").close();
        toast(`已导入 ${data.result.count} 台 ECS`);
        await Promise.all([loadDashboard(), loadManagement()]);
      } catch (error) { toast(error.message, true); $("importInstancesButton").disabled = false; }
    });

    $("telegramIdentityForm").addEventListener("submit", async event => {
      event.preventDefault();
      try {
        await api("/api/telegram/identity", { method: "POST", body: { bot_token: $("tgToken").value.trim(), chat_id: $("tgChatId").value.trim(), timeout_seconds: Number($("tgTimeout").value), retries: Number($("tgRetries").value), control_enabled: $("tgControlEnabled").checked, control_admin_ids: $("tgControlAdmins").value.trim() } });
        $("tgToken").value = "";
        toast("Telegram 机器人配置已保存");
        await loadManagement();
      } catch (error) { toast(error.message, true); }
    });

    $("telegramTestButton").addEventListener("click", async () => {
      $("telegramTestButton").disabled = true;
      try { const data = await api("/api/telegram/test", { method: "POST", body: {} }); toast(telegramTestText(data.result)); }
      catch (error) { toast(error.message, true); }
      finally { $("telegramTestButton").disabled = false; }
    });

    document.querySelectorAll('input[name="connectionMode"]').forEach(input => input.addEventListener("change", updateConnectionFields));
    $("tgControlEnabled").addEventListener("change", updateTelegramControlFields);
    async function submitConnection(save) {
      const target = $("connectionResult");
      setInlineResult(target, "正在连接 Telegram Bot API...");
      try {
        const data = await api("/api/telegram/connection", { method: "POST", body: connectionPayload(save) });
        setInlineResult(target, `${telegramTestText(data.result)}${save ? " · 已保存" : " · 未修改当前配置"}`);
        $("proxyUrl").value = "";
        $("apiBaseUrl").value = "";
        if (save) await loadManagement();
      } catch (error) { setInlineResult(target, error.message, true); }
    }
    $("connectionTestButton").addEventListener("click", () => submitConnection(false));
    $("connectionForm").addEventListener("submit", event => { event.preventDefault(); submitConnection(true); });

    $("nodeAddForm").addEventListener("submit", async event => {
      event.preventDefault();
      const submit = event.currentTarget.querySelector('button[type="submit"]');
      submit.disabled = true;
      setInlineResult($("nodeResult"), "正在测试节点到 Telegram Bot API 的往返延迟...");
      try {
        const data = await api("/api/telegram/nodes", { method: "POST", body: { node_url: $("nodeUrl").value.trim() } });
        $("nodeUrl").value = "";
        setInlineResult($("nodeResult"), `${telegramTestText(data.result)} · 节点已保存，当前连接方式未切换`);
        await loadManagement();
      } catch (error) { setInlineResult($("nodeResult"), error.message, true); }
      finally { submit.disabled = false; }
    });

    $("nodeList").addEventListener("click", async event => {
      const button = event.target.closest("button[data-node-action]");
      if (!button) return;
      const row = button.closest("[data-node-index]");
      const index = Number(row.dataset.nodeIndex), action = button.dataset.nodeAction;
      if (action === "delete" && !confirm(`确认删除节点 #${index + 1}？`)) return;
      button.disabled = true;
      setInlineResult($("nodeResult"), action === "delete" ? "正在删除节点..." : "正在测试节点到 Telegram Bot API 的往返延迟...");
      try {
        const data = await api(`/api/telegram/nodes/${index}/${action}`, { method: "POST", body: {} });
        const message = action === "delete" ? "节点已删除" : `${telegramTestText(data.result)}${action === "select" ? " · 已切换并保存" : " · 仅测试，未切换"}`;
        setInlineResult($("nodeResult"), message);
        await loadManagement();
      } catch (error) { setInlineResult($("nodeResult"), error.message, true); }
      finally { button.disabled = false; }
    });

    $("webHost").addEventListener("change", updateWebWarning);
    $("webSettingsForm").addEventListener("submit", async event => {
      event.preventDefault();
      const publicHost = $("webHost").value === "0.0.0.0";
      const changedToPublic = publicHost && state.management?.web.host !== "0.0.0.0";
      const confirmed = !changedToPublic || confirm("所有网卡监听下，直接 HTTP 访问会明文传输登录密码。确认继续？");
      if (!confirmed) return;
      try {
        const data = await api("/api/web-settings", { method: "POST", body: { enabled: $("webEnabled").checked, host: $("webHost").value, port: Number($("webPort").value), username: $("webUsername").value.trim(), password: $("webPassword").value, password_confirm: $("webPasswordConfirm").value, confirm_public: confirmed } });
        toast(data.web.restart_required ? "网页配置已保存，后台服务即将重启" : "网页配置已保存");
        $("webPassword").value = "";
        $("webPasswordConfirm").value = "";
      } catch (error) { toast(error.message, true); }
    });

    async function checkForUpdate(showErrors = true) {
      $("checkUpdateButton").disabled = true;
      try {
        const data = await api("/api/update");
        state.update = data;
        const docker = data.deployment === "docker";
        $("updateCurrentVersion").textContent = `v${data.current_version}`;
        $("updateLatestVersion").textContent = data.latest_version ? `v${data.latest_version}` : "暂时无法获取";
        $("installUpdateButton").disabled = !data.available || docker;
        setInlineResult($("updateResult"), data.available ? `发现新版本 v${data.latest_version}${docker ? "；Docker 请在宿主机拉取源码并重建镜像" : ""}` : data.latest_version ? `当前 v${data.current_version} 已经是最新版本` : "GitHub 版本检查暂时不可用", !data.latest_version);
      } catch (error) {
        setInlineResult($("updateResult"), error.message, true);
        if (showErrors) toast(error.message, true);
      } finally { $("checkUpdateButton").disabled = state.updatePolling; }
    }

    function renderUpdateProgress(progress, message, isError = false) {
      const value = Math.max(0, Math.min(100, Number(progress) || 0));
      $("updateProgress").hidden = false;
      $("updateProgress").classList.toggle("error", isError);
      $("updateProgressBar").value = value;
      $("updateProgressBar").setAttribute("aria-valuenow", String(value));
      $("updateProgressText").textContent = message || "正在更新";
      $("updateProgressPercent").textContent = `${Math.round(value)}%`;
    }

    async function readUpdateProgress() {
      const response = await fetch("/api/update/progress", { headers: { "Accept": "application/json" }, cache: "no-store" });
      if (!response.ok) throw new Error(`进度接口暂不可用 (${response.status})`);
      return response.json();
    }

    async function pollUpdateProgress() {
      if (state.updatePolling) return;
      state.updatePolling = true;
      $("checkUpdateButton").disabled = true;
      $("installUpdateButton").disabled = true;
      let lastProgress = Number($("updateProgressBar").value) || 3;
      while (state.updatePolling) {
        try {
          const data = await readUpdateProgress();
          lastProgress = Math.max(lastProgress, Number(data.progress) || 0);
          renderUpdateProgress(lastProgress, data.message, data.status === "error");
          if (data.status === "success") {
            state.updatePolling = false;
            setInlineResult($("updateResult"), `已更新到 v${data.target_version || state.update?.latest_version || "最新版本"}`);
            toast("更新完成，正在重新加载网页");
            setTimeout(() => window.location.reload(), 1600);
            return;
          }
          if (data.status === "error") {
            state.updatePolling = false;
            setInlineResult($("updateResult"), `${data.message}；请查看 /opt/aliyun-guard/logs/web-update.log`, true);
            toast("更新失败，已保留当前版本", true);
            $("checkUpdateButton").disabled = false;
            loadDashboard(false);
            state.timer = setInterval(() => { if (!document.hidden) loadDashboard(false); }, 15000);
            return;
          }
        } catch (_) {
          lastProgress = Math.max(lastProgress, 86);
          renderUpdateProgress(lastProgress, "后台服务重启中，正在重新连接...");
        }
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    }

    async function resumeUpdateProgress() {
      try {
        const data = await readUpdateProgress();
        if (data.status === "running") {
          renderUpdateProgress(data.progress, data.message);
          pollUpdateProgress();
          return true;
        }
      } catch (_) {}
      return false;
    }

    $("checkUpdateButton").addEventListener("click", () => checkForUpdate(true));
    $("installUpdateButton").addEventListener("click", async () => {
      if (!state.update?.available || !confirm(`确认更新到 v${state.update.latest_version}？本机配置和节点会保留。`)) return;
      renderUpdateProgress(2, "正在提交更新任务");
      $("checkUpdateButton").disabled = true;
      $("installUpdateButton").disabled = true;
      clearInterval(state.timer);
      state.timer = null;
      try {
        await api("/api/update/install", { method: "POST", body: { target_version: state.update.latest_version } });
        toast("更新程序已启动");
        pollUpdateProgress();
      } catch (error) {
        renderUpdateProgress(0, error.message, true);
        setInlineResult($("updateResult"), error.message, true);
        $("checkUpdateButton").disabled = false;
        $("installUpdateButton").disabled = false;
        state.timer = setInterval(() => { if (!document.hidden) loadDashboard(false); }, 15000);
        toast(error.message, true);
      }
    });
    $("restartServiceButton").addEventListener("click", async () => {
      if (!confirm("确认重启后台服务？网页可能短暂断开。")) return;
      try { await api("/api/service/restart", { method: "POST", body: {} }); toast("后台服务重启已安排"); }
      catch (error) { toast(error.message, true); }
    });

    (async function init() {
      try { const data = await api("/api/session"); $("loginVersion").textContent = `受保护的运维入口 · v${data.version}`; if (data.authenticated) { state.csrf = data.csrf; showApp(); } else showLogin(); }
      catch (error) { $("loginError").textContent = error.message; showLogin(); }
    })();
  </script>
</body>
</html>
__AG_WEB_HTML_EOF__
    cat > "$APP_DIR/aliyun_guard.py" <<'__AG_APP_PY_EOF__'
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
import s3_backup

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
HEARTBEAT_FILE = Path(
    os.environ.get("ALIYUN_GUARD_HEARTBEAT", APP_DIR / "heartbeat.json")
)
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
        "control_enabled": True,
        "control_admin_ids": [],
    },
    "start_wait_seconds": 90,
    "stop_wait_seconds": 45,
    "start_poll_seconds": 5,
    "watchdog": {
        "enabled": True,
        "timeout_seconds": 600,
        "failure_threshold": 2,
    },
    "s3_backup": dict(s3_backup.DEFAULT_CONFIG),
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


def normalize_telegram_control_admin_ids(value):
    if value in (None, ""):
        return []
    if isinstance(value, str):
        values = [item for item in re.split(r"[\s,;]+", value.strip()) if item]
    elif isinstance(value, (list, tuple)):
        values = list(value)
    else:
        raise GuardError("Telegram Bot 管理员用户 ID 必须是数组或分隔文本")
    if len(values) > 20:
        raise GuardError("Telegram Bot 管理员用户 ID 最多配置 20 个")
    result = []
    for raw in values:
        if isinstance(raw, bool):
            raise GuardError("Telegram Bot 管理员用户 ID 必须是正整数")
        try:
            user_id = int(str(raw).strip())
        except (TypeError, ValueError):
            raise GuardError("Telegram Bot 管理员用户 ID 必须是正整数")
        if user_id <= 0:
            raise GuardError("Telegram Bot 管理员用户 ID 必须是正整数")
        if user_id not in result:
            result.append(user_id)
    return result


def telegram_control_admin_ids(telegram):
    configured = normalize_telegram_control_admin_ids(
        telegram.get("control_admin_ids", []) if isinstance(telegram, dict) else []
    )
    if configured:
        return configured
    try:
        chat_id = int(str(telegram.get("chat_id", "") or "").strip())
    except (TypeError, ValueError):
        return []
    return [chat_id] if chat_id > 0 else []


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


def write_heartbeat(status="running", detail=None, now=None):
    now = now or dt.datetime.now().astimezone()
    value = {
        "at": now.isoformat(timespec="seconds"),
        "epoch": now.timestamp(),
        "status": str(status or "running"),
        "pid": os.getpid(),
    }
    if detail:
        value["detail"] = str(detail)[:500]
    atomic_write_json(HEARTBEAT_FILE, value)
    return value


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
    watchdog = config.get("watchdog", {})
    if not isinstance(watchdog, dict):
        raise GuardError("watchdog 必须是对象")
    if "enabled" in watchdog and not isinstance(watchdog.get("enabled"), bool):
        raise GuardError("watchdog.enabled 必须是布尔值")
    try:
        watchdog_timeout = int(watchdog.get("timeout_seconds", 600))
        watchdog_failures = int(watchdog.get("failure_threshold", 2))
    except (TypeError, ValueError):
        raise GuardError("看门狗超时和连续失败次数必须是整数")
    if watchdog_timeout < 120 or watchdog_timeout > 86400:
        raise GuardError("看门狗超时必须在 120 到 86400 秒之间")
    if watchdog_failures < 1 or watchdog_failures > 10:
        raise GuardError("看门狗连续失败次数必须在 1 到 10 之间")
    try:
        config["s3_backup"] = s3_backup.validate_config(
            config.get("s3_backup", {}), require_ready=None
        )
    except s3_backup.S3BackupError as exc:
        raise GuardError(str(exc))
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
    if "control_enabled" in telegram and not isinstance(
        telegram.get("control_enabled"), bool
    ):
        raise GuardError("Telegram Bot 控制开关必须是布尔值")
    normalize_telegram_control_admin_ids(telegram.get("control_admin_ids", []))
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


def cdt_account_cache_key(user):
    """Return an in-memory fingerprint for one configured credential pair."""
    credentials = "{}\0{}".format(
        str(user.get("ak", "") or "").strip(),
        str(user.get("sk", "") or "").strip(),
    )
    return hashlib.sha256(credentials.encode("utf-8")).digest()


def query_cdt_traffic_gb_for_cycle(user, cycle_cache=None):
    """Reuse one account-level CDT result within a single monitoring cycle."""
    if cycle_cache is None:
        return query_cdt_traffic_gb(user)

    cache_key = cdt_account_cache_key(user)
    if cache_key not in cycle_cache:
        try:
            cycle_cache[cache_key] = (query_cdt_traffic_gb(user), None)
        except Exception as exc:
            cycle_cache[cache_key] = (None, exc)

    traffic_gb, error = cycle_cache[cache_key]
    if error is not None:
        raise error
    return traffic_gb


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


def _instance_tags(instance):
    raw = instance.get("Tags", {}).get("Tag", []) if isinstance(instance, dict) else []
    if isinstance(raw, dict):
        raw = [raw]
    if not isinstance(raw, list):
        raw = []
    return {
        str(item.get("TagKey", "")): str(item.get("TagValue", ""))
        for item in raw
        if isinstance(item, dict) and str(item.get("TagKey", ""))
    }


def discover_ecs_regions(ak, sk):
    require_sdk()
    access_key = str(ak or "").strip()
    secret_key = str(sk or "").strip()
    if not access_key or not secret_key:
        raise GuardError("AccessKey ID 和 AccessKey Secret 不能为空")
    request = CommonRequest()
    request.set_protocol_type("https")
    request.set_accept_format("json")
    request.set_method("POST")
    request.set_domain("ecs.aliyuncs.com")
    request.set_version("2014-05-26")
    request.set_action_name("DescribeRegions")
    request.set_connect_timeout(5000)
    request.set_read_timeout(15000)
    credentials = {"ak": access_key, "sk": secret_key}
    response = make_client(credentials, "cn-hangzhou").do_action_with_exception(request)
    data = json.loads(response.decode("utf-8"))
    regions = data.get("Regions", {}).get("Region", [])
    if isinstance(regions, dict):
        regions = [regions]
    if not isinstance(regions, list):
        raise GuardError("ECS 返回 Region 列表格式无法识别")
    result = []
    for item in regions:
        region = str(item.get("RegionId", "") if isinstance(item, dict) else "").strip()
        if region and region not in result:
            result.append(region)
    return result


def discover_ecs_instances(ak, sk, regions, tag_key="", tag_value=""):
    require_sdk()
    access_key = str(ak or "").strip()
    secret_key = str(sk or "").strip()
    if not access_key or not secret_key:
        raise GuardError("AccessKey ID 和 AccessKey Secret 不能为空")
    region_values = []
    for value in regions if isinstance(regions, (list, tuple)) else [regions]:
        region = str(value or "").strip()
        if region and region not in region_values:
            region_values.append(region)
    if not region_values:
        raise GuardError("至少需要一个 Region ID")
    if len(region_values) > 50:
        raise GuardError("一次最多扫描 50 个 Region")
    tag_key = str(tag_key or "").strip()
    tag_value = str(tag_value or "").strip()
    results = []
    errors = []
    credentials = {"ak": access_key, "sk": secret_key}
    for region in region_values:
        try:
            page = 1
            while page <= 100:
                request = DescribeInstancesRequest()
                request.set_protocol_type("https")
                request.set_accept_format("json")
                request.set_PageNumber(page)
                request.set_PageSize(100)
                request.set_connect_timeout(5000)
                request.set_read_timeout(20000)
                response = make_client(credentials, region).do_action_with_exception(request)
                data = json.loads(response.decode("utf-8"))
                instances = data.get("Instances", {}).get("Instance", [])
                if isinstance(instances, dict):
                    instances = [instances]
                if not isinstance(instances, list):
                    raise GuardError("ECS 返回实例列表格式无法识别")
                for instance in instances:
                    if not isinstance(instance, dict):
                        continue
                    tags = _instance_tags(instance)
                    if tag_key and tag_key not in tags:
                        continue
                    if tag_key and tag_value and tags.get(tag_key) != tag_value:
                        continue
                    instance_id = str(instance.get("InstanceId", "")).strip()
                    if not instance_id:
                        continue
                    results.append(
                        {
                            "region": region,
                            "instance_id": instance_id,
                            "name": str(instance.get("InstanceName", "") or instance_id),
                            "status": str(instance.get("Status", "Unknown")),
                            "zone_id": str(instance.get("ZoneId", "")),
                            "instance_type": str(instance.get("InstanceType", "")),
                            "public_ip": str(
                                (instance.get("PublicIpAddress", {}).get("IpAddress", []) or [""])[0]
                            ),
                            "tags": tags,
                        }
                    )
                total = int(data.get("TotalCount", len(instances)) or 0)
                if page * 100 >= total or not instances:
                    break
                page += 1
        except Exception as exc:
            errors.append(
                {
                    "region": region,
                    "error": compact_error(exc, secrets=(access_key, secret_key)),
                }
            )
    return {"instances": results, "errors": errors, "regions": region_values}


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


def telegram_api(config, method, data=None, request_timeout=None):
    token = str(config.get("bot_token", "")).strip()
    if not token:
        raise GuardError("Telegram Bot Token 未配置")
    timeout = max(
        3,
        int(
            request_timeout
            if request_timeout is not None
            else config.get("timeout_seconds", 12)
        ),
    )
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


def check_one(
    user,
    config,
    dry_run=False,
    now=None,
    scheduled_action=None,
    cdt_cycle_cache=None,
):
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
        result["traffic_gb"] = query_cdt_traffic_gb_for_cycle(user, cdt_cycle_cache)
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
    cdt_cycle_cache = {}
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
            cdt_cycle_cache=cdt_cycle_cache,
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
    if not dry_run:
        write_heartbeat(
            "cycle_error" if error_count else "cycle_ok",
            "{} 个错误".format(error_count) if error_count else "检测完成",
        )
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
    config = load_config()
    now = dt.datetime.now().astimezone()
    result = 0
    with cycle_lock() as locked:
        if not locked:
            LOGGER.info("已有检测正在运行，本次计划任务跳过")
        else:
            write_heartbeat("scheduled", "计划任务已唤醒")
            state = load_state()
            if is_due(config, state, now.timestamp()) or has_due_schedule(
                config, state, now
            ):
                result = run_cycle(started_at=now)
    run_s3_backup_if_due(config, now)
    return result


def scheduler_wait_seconds(config, state, now=None):
    now = time.time() if now is None else float(now)
    last = state.get("last_cycle_epoch")
    if last is None:
        regular_wait = 60.0
    else:
        regular_wait = max(1.0, int(config["interval_seconds"]) - (now - float(last)))
    minute_wait = 60.05 - (now % 60.0)
    return max(1.0, min(regular_wait, minute_wait))


def s3_backup_secrets(config):
    backup = config.get("s3_backup", {}) if isinstance(config, dict) else {}
    return tuple(
        str(backup.get(field, "") or "")
        for field in (
            "access_key_id",
            "secret_access_key",
            "session_token",
            "backup_password",
        )
        if str(backup.get(field, "") or "")
    )


def run_s3_backup_if_due(config, now=None):
    backup = config.get("s3_backup", {})
    if not isinstance(backup, dict) or not backup.get("enabled", False):
        return None
    now = now or dt.datetime.now().astimezone()
    secrets = s3_backup_secrets(config)
    heartbeat_stop = threading.Event()

    def refresh_backup_heartbeat():
        while not heartbeat_stop.wait(30):
            try:
                write_heartbeat("s3_backup", "S3 加密备份正在上传")
            except Exception:
                pass

    write_heartbeat("s3_backup", "检查 S3 自动备份计划")
    heartbeat_thread = threading.Thread(
        target=refresh_backup_heartbeat,
        name="aliyun-guard-s3-heartbeat",
        daemon=True,
    )
    heartbeat_thread.start()
    try:
        try:
            result = s3_backup.run_if_due(backup, CONFIG_FILE.parent, now=now)
        except Exception as exc:
            result = {"ok": False, "error": compact_error(exc, secrets=secrets)}
    finally:
        heartbeat_stop.set()
        heartbeat_thread.join(timeout=2)
        write_heartbeat("daemon_running", "S3 自动备份检查完成")
    if result is None or result.get("skipped"):
        return result
    mode = str(backup.get("notification_mode", "errors"))
    if result.get("ok"):
        LOGGER.info(
            "S3 自动备份成功: %s，清理 %s 份旧备份",
            result.get("key"),
            len(result.get("deleted", [])),
        )
        should_send = mode == "always"
        text = (
            "Aliyun Guard S3 自动备份成功\n"
            "时间: {}\n"
            "Bucket: {}\n"
            "对象: {}\n"
            "大小: {:.2f} MiB\n"
            "清理旧备份: {} 份"
        ).format(
            now.strftime("%Y-%m-%d %H:%M:%S"),
            result.get("bucket", ""),
            result.get("key", ""),
            float(result.get("size", 0)) / 1048576,
            len(result.get("deleted", [])),
        )
    else:
        LOGGER.error("S3 自动备份失败: %s", result.get("error", "未知错误"))
        should_send = mode in ("always", "errors")
        text = (
            "Aliyun Guard S3 自动备份失败\n"
            "时间: {}\n"
            "错误: {}"
        ).format(
            now.strftime("%Y-%m-%d %H:%M:%S"),
            compact_error(result.get("error", "未知错误"), secrets=secrets),
        )
    if should_send:
        try:
            send_telegram_message(config.get("telegram", {}), text)
        except Exception as exc:
            LOGGER.error(
                "S3 备份结果 Telegram 通知失败: %s",
                compact_error(
                    exc,
                    secrets=telegram_secrets(config.get("telegram", {})) + secrets,
                ),
            )
    return result


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
    telegram_control_service = None
    try:
        import telegram_control

        telegram_control_service = telegram_control.start_background(sys.modules[__name__])
    except Exception as exc:
        LOGGER.error("Telegram Bot 控制启动失败，保活服务继续运行: %s", compact_error(exc))
    LOGGER.info("保活服务已启动")
    write_heartbeat("daemon_started", "后台服务已启动")
    first_cycle = True
    while not _STOP_EVENT.is_set():
        write_heartbeat("daemon_running", "调度循环正常")
        now = dt.datetime.now().astimezone()
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
        try:
            run_s3_backup_if_due(config, now)
        except Exception as exc:
            LOGGER.error("S3 自动备份调度失败: %s", compact_error(exc))
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
    if telegram_control_service is not None:
        telegram_control_service.shutdown()
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
    telegram = config.get("telegram", {})
    control_enabled = bool(telegram.get("control_enabled", True))
    control_admins = telegram_control_admin_ids(telegram) if control_enabled else []
    print(
        "Bot 控制: {}{}".format(
            "已启用" if control_enabled else "已关闭",
            "（{} 个管理员）".format(len(control_admins)) if control_enabled else "",
        )
    )
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
__AG_APP_PY_EOF__
    cat > "$APP_DIR/manager.py" <<'__AG_MANAGER_PY_EOF__'
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
import backup_manager
import s3_backup
import telegram_proxy
import web_panel


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
CONFIG_FILE = Path(os.environ.get("ALIYUN_GUARD_CONFIG", APP_DIR / "config.json"))
CONTROL_FILE = APP_DIR / "control.sh"
UPDATE_REPOSITORY = "Felix666-ship-It/aliyun-guard"
UPDATE_CUSTOM_BASE_URL = os.environ.get("ALIYUN_GUARD_UPDATE_BASE", "").rstrip("/")
UPDATE_RELEASES_URL = "https://github.com/{}/releases".format(UPDATE_REPOSITORY)
UPDATE_BASE_URL = UPDATE_CUSTOM_BASE_URL or UPDATE_RELEASES_URL + "/latest/download"
APP_VERSION = "1.5.9"
LOCAL_RELEASE_ID = "1ecb7ead2150b382e69df44e6590e2b4a891cfb42aca6810ff5299ed03ca1898"
UPDATE_MANIFEST_NAME = "version.json"
UPDATE_CHECK_TIMEOUT_SECONDS = 5
ANSI_YELLOW = "\033[33m"
ANSI_RESET = "\033[0m"


def update_asset_base_url(version=None):
    if UPDATE_CUSTOM_BASE_URL:
        return UPDATE_CUSTOM_BASE_URL
    if version:
        normalized = str(version).strip().lstrip("v")
        return UPDATE_RELEASES_URL + "/download/v" + normalized
    return UPDATE_BASE_URL

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


def telegram_control_status(telegram):
    if not telegram.get("control_enabled", True):
        return "已关闭"
    admins = guard.telegram_control_admin_ids(telegram)
    explicit = guard.normalize_telegram_control_admin_ids(
        telegram.get("control_admin_ids", [])
    )
    if not admins:
        return "已启用，但未配置有效管理员"
    source = "独立名单" if explicit else "使用私聊 Chat ID"
    return "已启用，{} 个管理员（{}）".format(len(admins), source)


def configure_telegram_control(telegram):
    title("Telegram Bot 控制")
    print("当前状态: {}".format(telegram_control_status(telegram)))
    enabled = yes_no(
        "启用 Telegram Bot 控制", bool(telegram.get("control_enabled", True))
    )
    telegram["control_enabled"] = enabled
    if not enabled:
        print("Bot 控制已关闭，Telegram 通知不受影响。")
        return telegram
    explicit = guard.normalize_telegram_control_admin_ids(
        telegram.get("control_admin_ids", [])
    )
    default = ",".join(str(value) for value in explicit) if explicit else "auto"
    raw = prompt(
        "管理员 Telegram 用户 ID（逗号分隔；auto 使用私聊 Chat ID）",
        default,
        required=True,
    )
    if raw.strip().lower() == "auto":
        telegram["control_admin_ids"] = []
    else:
        telegram["control_admin_ids"] = guard.normalize_telegram_control_admin_ids(raw)
    admins = guard.telegram_control_admin_ids(telegram)
    if admins:
        print("Bot 控制管理员: {}".format(", ".join(str(value) for value in admins)))
    else:
        print("警告: 当前没有有效管理员，Bot 控制不会接受任何命令。")
    return telegram


def configure_telegram_connection(candidate, force_ipv4=True, initial=False, active=None):
    while True:
        title("Telegram 连接与 Bot 控制")
        status_source = active if active is not None else candidate
        for line in telegram_connection_status_lines(status_source):
            print(line)
        if active is not None and _telegram_connection_signature(candidate) != _telegram_connection_signature(active):
            for line in telegram_connection_status_lines(candidate, prefix="待保存"):
                print(line)
        print("Bot 控制: {}".format(telegram_control_status(candidate)))
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
        print("10) Bot 控制设置")
        choice = prompt_int("请选择", 10, 1, 10)
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
        elif choice == 10:
            configure_telegram_control(candidate)
            return candidate, True


def configure_telegram(config, initial=False):
    title("Telegram 通知配置")
    current = config.setdefault("telegram", {})
    candidate = json.loads(json.dumps(current, ensure_ascii=False))
    print("Token、代理密码和节点链接只保存在本机 root 可读的配置文件中。")
    _set_telegram_identity(candidate)
    candidate.setdefault("control_enabled", True)
    candidate.setdefault("control_admin_ids", [])
    if initial:
        print("Telegram Bot 控制默认开启，未单独设置时使用正数私聊 Chat ID 授权。")
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
    current_watchdog = config.get("watchdog", {})
    if not isinstance(current_watchdog, dict):
        current_watchdog = {}
    config["watchdog"] = {
        "enabled": yes_no(
            "启用监控失联告警与自动重启",
            bool(current_watchdog.get("enabled", True)),
        ),
        "timeout_seconds": prompt_int(
            "心跳失联超时（秒）",
            current_watchdog.get("timeout_seconds", 600),
            120,
            86400,
        ),
        "failure_threshold": prompt_int(
            "连续失败多少次后告警",
            current_watchdog.get("failure_threshold", 2),
            1,
            10,
        ),
    }
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
    asset_base_url = update_asset_base_url(target_version)
    print("更新来源: {}".format(asset_base_url))
    print("现有 config.json、state.json 和日志会保留。")
    confirm_text = "下载并安装 GitHub main 分支最新版本"
    if target_version:
        confirm_text = "下载并安装 GitHub v{}".format(target_version)
    if confirm_update and not yes_no(confirm_text, True):
        print("已取消更新。")
        return None

    installer_url = asset_base_url + "/install.sh"
    checksum_url = asset_base_url + "/install.sh.sha256"
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
        snapshot = backup_manager.create_program_snapshot(APP_DIR, APP_VERSION)
        print("更新前程序快照: {}".format(snapshot))
        with tempfile.NamedTemporaryFile(prefix="aliyun-guard-update-", suffix=".sh", delete=False) as handle:
            handle.write(installer)
            temporary_path = handle.name
        os.chmod(temporary_path, 0o700)
        print("SHA-256 校验通过: {}".format(actual))
        result = subprocess.call(
            ["/bin/sh", temporary_path, "--update"],
            stdin=subprocess.DEVNULL,
        )
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


def backup_restore_menu():
    while True:
        title("备份、恢复与版本回滚")
        snapshots = backup_manager.list_program_snapshots(app_dir=APP_DIR)
        print("程序回滚快照: {} 个".format(len(snapshots)))
        print(" 1) 创建加密备份")
        print(" 2) 预览备份差异")
        print(" 3) 恢复加密备份")
        print(" 4) 回滚到更新前程序版本")
        print(" 5) 返回")
        choice = prompt_int("请输入序号", 1, 1, 5)
        if choice == 5:
            return
        try:
            if choice == 1:
                password = prompt_secret("备份密码（至少 8 个字符）")
                confirmation = prompt_secret("再次输入备份密码")
                if password != confirmation:
                    print("两次输入的密码不一致。")
                    continue
                path = backup_manager.create_backup(
                    password,
                    guard.CONFIG_FILE.parent,
                    include_state=yes_no("包含状态文件", True),
                    include_logs=yes_no("包含日志", True),
                )
                print("加密备份已创建: {}".format(path))
            elif choice in (2, 3):
                path = Path(prompt("备份文件完整路径", required=True)).expanduser()
                password = prompt_secret("备份密码")
                preview = backup_manager.preview_restore(
                    path, password, guard.CONFIG_FILE.parent
                )
                summary = preview.get("summary", {})
                print(
                    "备份配置: {} 个实例，{} 个节点".format(
                        summary.get("instances", 0), summary.get("nodes", 0)
                    )
                )
                for item in preview.get("files", []):
                    print(" - {:<9} {}".format(item["action"], item["path"]))
                if choice == 3 and yes_no("确认按以上差异恢复", False):
                    result = backup_manager.restore_backup(
                        path, password, guard.CONFIG_FILE.parent
                    )
                    print("已恢复 {} 个文件。".format(len(result["restored"])))
                    print("恢复前安全备份: {}".format(result["safety_backup"]))
                    run_control("restart")
            elif choice == 4:
                if not snapshots:
                    print("当前没有程序回滚快照。")
                    continue
                for index, path in enumerate(snapshots, 1):
                    print(" {:>2}) {}".format(index, path.name))
                index = prompt_int("选择快照", 1, 1, len(snapshots)) - 1
                if yes_no("确认恢复程序文件并重启服务", False):
                    result = backup_manager.restore_program_snapshot(
                        snapshots[index], APP_DIR
                    )
                    print("程序已回滚到快照版本: {}".format(result["version"]))
                    run_control("restart")
        except backup_manager.BackupError as exc:
            print("操作失败: {}".format(exc))


def collect_s3_backup_settings(config):
    current = s3_backup.normalized_config(config.get("s3_backup", {}))
    title("S3 自动备份设置")
    candidate = dict(current)
    candidate["enabled"] = yes_no("启用 S3 自动备份", current["enabled"])
    candidate["bucket"] = prompt(
        "Bucket 名称", current["bucket"], required=candidate["enabled"]
    )
    candidate["region"] = prompt("AWS/S3 Region", current["region"], required=True)
    candidate["endpoint_url"] = prompt(
        "自定义 Endpoint（AWS S3 留空）", current["endpoint_url"]
    ).rstrip("/")
    candidate["prefix"] = prompt("对象目录前缀", current["prefix"])
    styles = [("auto", "自动"), ("path", "路径寻址"), ("virtual", "虚拟主机寻址")]
    print("\nS3 寻址方式：")
    default_style = next(
        (index for index, item in enumerate(styles, 1) if item[0] == current["addressing_style"]),
        1,
    )
    for index, (_value, label) in enumerate(styles, 1):
        print(" {}) {}".format(index, label))
    candidate["addressing_style"] = styles[
        prompt_int("寻址方式", default_style, 1, len(styles)) - 1
    ][0]
    use_role = yes_no("使用 EC2 IAM Role/环境凭据", not bool(current["access_key_id"]))
    if use_role:
        candidate["access_key_id"] = ""
        candidate["secret_access_key"] = ""
        candidate["session_token"] = ""
    else:
        candidate["access_key_id"] = prompt_secret(
            "AWS Access Key ID",
            keep_existing=not candidate["enabled"] or bool(current["access_key_id"]),
        ) or current["access_key_id"]
        candidate["secret_access_key"] = prompt_secret(
            "AWS Secret Access Key",
            keep_existing=not candidate["enabled"] or bool(current["secret_access_key"]),
        ) or current["secret_access_key"]
        candidate["session_token"] = prompt_secret(
            "AWS Session Token（长期密钥留空）", keep_existing=True
        ) or current["session_token"]
    candidate["backup_password"] = prompt_secret(
        "自动备份加密密码（至少 8 位）",
        keep_existing=not candidate["enabled"] or bool(current["backup_password"]),
    ) or current["backup_password"]
    schedules = [("hourly", "每小时"), ("daily", "每天"), ("weekly", "每周")]
    print("\n自动备份周期：")
    default_schedule = next(
        (index for index, item in enumerate(schedules, 1) if item[0] == current["schedule"]),
        2,
    )
    for index, (_value, label) in enumerate(schedules, 1):
        print(" {}) {}".format(index, label))
    candidate["schedule"] = schedules[
        prompt_int("周期", default_schedule, 1, len(schedules)) - 1
    ][0]
    candidate["time"] = prompt(
        "执行时间 HH:MM（每小时仅使用分钟）", current["time"], required=True
    )
    if candidate["schedule"] == "weekly":
        candidate["weekday"] = prompt_int(
            "星期（0=周一，6=周日）", current["weekday"], 0, 6
        )
    candidate["retention"] = prompt_int(
        "云端和本地保留份数", current["retention"], 1, 365
    )
    candidate["include_state"] = yes_no("包含运行状态", current["include_state"])
    candidate["include_logs"] = yes_no("包含日志", current["include_logs"])
    notifications = [("errors", "仅失败通知"), ("always", "成功和失败都通知"), ("none", "不通知")]
    print("\nTelegram 通知：")
    default_notice = next(
        (index for index, item in enumerate(notifications, 1) if item[0] == current["notification_mode"]),
        1,
    )
    for index, (_value, label) in enumerate(notifications, 1):
        print(" {}) {}".format(index, label))
    candidate["notification_mode"] = notifications[
        prompt_int("通知方式", default_notice, 1, len(notifications)) - 1
    ][0]
    encryptions = [("AES256", "SSE-S3"), ("aws:kms", "SSE-KMS"), ("", "关闭服务端加密")]
    print("\nS3 服务端加密：")
    default_encryption = next(
        (index for index, item in enumerate(encryptions, 1) if item[0] == current["server_side_encryption"]),
        1,
    )
    for index, (_value, label) in enumerate(encryptions, 1):
        print(" {}) {}".format(index, label))
    candidate["server_side_encryption"] = encryptions[
        prompt_int("加密方式", default_encryption, 1, len(encryptions)) - 1
    ][0]
    if candidate["server_side_encryption"] == "aws:kms":
        candidate["kms_key_id"] = prompt_secret(
            "KMS Key ID/ARN", keep_existing=bool(current["kms_key_id"])
        ) or current["kms_key_id"]
    else:
        candidate["kms_key_id"] = ""
    return s3_backup.validate_config(candidate, require_ready=candidate["enabled"])


def print_s3_backups(items):
    if not items:
        print("云端没有 Aliyun Guard 加密备份。")
        return
    for index, item in enumerate(items, 1):
        print(
            " {:>3}) {:<42} {:>8.2f} MiB  {}".format(
                index,
                item["name"][:42],
                float(item["size"]) / 1048576,
                item.get("modified_at", ""),
            )
        )


def s3_backup_menu(config):
    while True:
        current = s3_backup.normalized_config(config.get("s3_backup", {}))
        status = s3_backup.read_status(CONFIG_FILE.parent)
        title("AWS S3 / S3 兼容存储自动备份")
        print("状态: {}".format("已启用" if current["enabled"] else "已关闭"))
        print("Bucket: {}".format(current["bucket"] or "未配置"))
        print("最近成功: {}".format(status.get("last_success_at") or "尚未运行"))
        if status.get("last_error"):
            print("最近错误: {}".format(status["last_error"]))
        print("\n 1) 配置自动备份")
        print(" 2) 测试当前 S3 连接")
        print(" 3) 立即创建并上传加密备份")
        print(" 4) 查看云端备份")
        print(" 5) 从云端预览并恢复")
        print(" 6) 返回")
        choice = prompt_int("请输入序号", 6, 1, 6)
        if choice == 6:
            return
        try:
            if choice == 1:
                candidate = collect_s3_backup_settings(config)
                if candidate["enabled"]:
                    print("正在测试 S3 连接...")
                    result = s3_backup.test_connection(candidate)
                    print("连接成功，延迟约 {} ms。".format(result["latency_ms"]))
                config["s3_backup"] = candidate
                save_config(config)
                print("S3 自动备份设置已保存。")
            elif choice == 2:
                result = s3_backup.test_connection(current)
                print("连接成功：{} / {}，延迟约 {} ms。".format(result["bucket"], result["endpoint"], result["latency_ms"]))
            elif choice == 3:
                result = s3_backup.create_and_upload(current, CONFIG_FILE.parent)
                print("上传成功: s3://{}/{}".format(result["bucket"], result["key"]))
                print("已清理云端旧备份 {} 份。".format(len(result["deleted"])))
            elif choice in (4, 5):
                items = s3_backup.list_backups(current, limit=100)
                print_s3_backups(items)
                if choice == 5 and items:
                    index = prompt_int("选择要恢复的备份", 1, 1, len(items)) - 1
                    path = s3_backup.download_backup(current, items[index]["key"], CONFIG_FILE.parent)
                    try:
                        preview = backup_manager.preview_restore(path, current["backup_password"], CONFIG_FILE.parent)
                        for item in preview.get("files", []):
                            print(" - {:<9} {}".format(item["action"], item["path"]))
                        if yes_no("确认按以上差异恢复并重启服务", False):
                            result = backup_manager.restore_backup(
                                path,
                                current["backup_password"],
                                CONFIG_FILE.parent,
                                include_logs=yes_no("恢复备份中的日志", True),
                            )
                            print("恢复完成，恢复前安全备份: {}".format(result["safety_backup"]))
                            run_control("restart")
                    finally:
                        path.unlink(missing_ok=True)
        except (s3_backup.S3BackupError, backup_manager.BackupError) as exc:
            print("S3 备份操作失败: {}".format(exc))


def discover_instances_menu(config):
    title("自动发现阿里云 ECS")
    ak = prompt_secret("AccessKey ID")
    sk = prompt_secret("AccessKey Secret")
    regions_text = prompt(
        "扫描 Region（逗号分隔，留空扫描内置 Region）", ""
    )
    regions = [
        item.strip()
        for item in regions_text.replace(";", ",").split(",")
        if item.strip()
    ]
    if not regions:
        print("正在从阿里云账号读取可用 Region...")
        regions = guard.discover_ecs_regions(ak, sk)
    tag_key = prompt("标签键筛选（可留空）", "")
    tag_value = prompt("标签值筛选（可留空）", "") if tag_key else ""
    if config.get("force_ipv4", True):
        guard.enable_ipv4_only()
    result = guard.discover_ecs_instances(ak, sk, regions, tag_key, tag_value)
    instances = result.get("instances", [])
    for error in result.get("errors", []):
        print("[{}] 扫描失败: {}".format(error["region"], error["error"]))
    if not instances:
        print("没有发现符合条件的 ECS 实例。")
        return
    title("发现 {} 台 ECS".format(len(instances)))
    for index, item in enumerate(instances, 1):
        print(
            "{:>3}) {:<20} {:<18} {:<22} {}".format(
                index,
                item["region"],
                item["status"],
                item["instance_id"],
                item["name"],
            )
        )
    selection = prompt("选择序号（逗号分隔，输入 all 全选）", "all")
    if selection.lower() == "all":
        indexes = list(range(len(instances)))
    else:
        try:
            indexes = sorted(
                {
                    int(value.strip()) - 1
                    for value in selection.replace(";", ",").split(",")
                    if value.strip()
                }
            )
        except ValueError:
            print("选择格式无效。")
            return
    selected = [instances[index] for index in indexes if 0 <= index < len(instances)]
    if not selected:
        print("没有选择有效实例。")
        return
    limit = prompt_float("统一 CDT 关机阈值（GB）", 180, 0.01)
    actions_enabled = yes_no("允许自动开关机", True)
    billing = configure_billing({})
    existing = {
        (str(item.get("ak")), str(item.get("region")), str(item.get("instance_id")))
        for item in config.get("users", [])
    }
    imported = 0
    for item in selected:
        identity = (ak, item["region"], item["instance_id"])
        if identity in existing:
            continue
        config.setdefault("users", []).append(
            {
                "name": item["name"] or item["instance_id"],
                "ak": ak,
                "sk": sk,
                "region": item["region"],
                "instance_id": item["instance_id"],
                "traffic_limit_gb": limit,
                "actions_enabled": actions_enabled,
                "instance_log_enabled": False,
                "paused": False,
                "billing": dict(billing),
                "schedule": dict(guard.DEFAULT_SCHEDULE),
            }
        )
        existing.add(identity)
        imported += 1
    if imported:
        save_config(config)
    print("已导入 {} 台实例，重复实例已跳过。".format(imported))


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
        print(" 5) Telegram 连接与 Bot 控制")
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
        print("17) 备份、恢复与版本回滚")
        print("18) 自动发现并批量导入 ECS")
        print("19) 退出")
        print("20) AWS S3 自动备份")
        choice = prompt_int("请输入序号", 19, 1, 20)
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
                backup_restore_menu()
            elif choice == 18:
                discover_instances_menu(config)
            elif choice == 19:
                return 0
            elif choice == 20:
                s3_backup_menu(config)
        except KeyboardInterrupt:
            print("\n操作已取消。")
        if choice != 19:
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
__AG_MANAGER_PY_EOF__
    cat > "$APP_DIR/control.sh" <<'__AG_CONTROL_SH_EOF__'
#!/bin/sh
set -u

APP_DIR=${ALIYUN_GUARD_HOME:-/opt/aliyun-guard}
PYTHON="$APP_DIR/venv/bin/python"
APP="$APP_DIR/aliyun_guard.py"
MANAGER="$APP_DIR/manager.py"
WEB="$APP_DIR/web_panel.py"
BACKEND_FILE="$APP_DIR/service_backend"
SERVICE_NAME="aliyun-guard"

mark_enabled() {
    rm -f "$APP_DIR/disabled"
}

mark_disabled() {
    : > "$APP_DIR/disabled"
    chmod 600 "$APP_DIR/disabled"
}

enable_watchdog_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    cron_old=$(mktemp)
    cron_new=$(mktemp)
    crontab -l > "$cron_old" 2>/dev/null || :
    grep -v '# aliyun-guard-watchdog' "$cron_old" > "$cron_new" || :
    printf '* * * * * %s %s/watchdog.py >> %s/logs/watchdog.log 2>&1 # aliyun-guard-watchdog\n' \
        "$PYTHON" "$APP_DIR" "$APP_DIR" >> "$cron_new"
    crontab "$cron_new"
    rm -f "$cron_old" "$cron_new"
}

disable_watchdog_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    cron_old=$(mktemp)
    cron_new=$(mktemp)
    crontab -l > "$cron_old" 2>/dev/null || :
    grep -v '# aliyun-guard-watchdog' "$cron_old" > "$cron_new" || :
    if [ -s "$cron_new" ]; then
        crontab "$cron_new"
    else
        crontab -r >/dev/null 2>&1 || true
    fi
    rm -f "$cron_old" "$cron_new"
}

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
            systemctl is-active "$SERVICE_NAME-watchdog.timer" 2>/dev/null || true
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
            mark_enabled
            systemctl enable --now "$SERVICE_NAME.service"
            systemctl enable --now "$SERVICE_NAME-watchdog.timer"
            ;;
        openrc)
            mark_enabled
            enable_watchdog_cron
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
            rc-service "$SERVICE_NAME" start
            ;;
        cron)
            mark_enabled
            enable_watchdog_cron
            "$PYTHON" "$WEB" ensure >/dev/null 2>&1 || true
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
            mark_disabled
            systemctl disable --now "$SERVICE_NAME-watchdog.timer" >/dev/null 2>&1 || true
            systemctl disable --now "$SERVICE_NAME.service"
            ;;
        openrc)
            mark_disabled
            disable_watchdog_cron
            rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
            rc-service "$SERVICE_NAME" stop
            ;;
        cron)
            mark_disabled
            disable_watchdog_cron
            "$PYTHON" "$WEB" stop >/dev/null 2>&1 || true
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
            mark_enabled
            systemctl restart "$SERVICE_NAME.service"
            systemctl enable --now "$SERVICE_NAME-watchdog.timer"
            systemctl is-active "$SERVICE_NAME.service"
            ;;
        openrc)
            mark_enabled
            enable_watchdog_cron
            rc-service "$SERVICE_NAME" restart
            ;;
        cron)
            mark_enabled
            enable_watchdog_cron
            "$PYTHON" "$APP" scheduled
            "$PYTHON" "$WEB" restart
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
web                    查看网页控制面板地址和状态
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
    web)
        exec "$PYTHON" "$MANAGER" web
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
__AG_UNINSTALL_SH_EOF__
    chmod 700 "$APP_DIR/control.sh" "$APP_DIR/uninstall.sh"
    chmod 700 "$APP_DIR/aliyun_guard.py" "$APP_DIR/manager.py" "$APP_DIR/backup_manager.py" "$APP_DIR/s3_backup.py" "$APP_DIR/watchdog.py" "$APP_DIR/telegram_proxy.py" "$APP_DIR/telegram_control.py" "$APP_DIR/web_actions.py" "$APP_DIR/web_panel.py"
    chmod 600 "$APP_DIR/web_panel.html"
    chmod 700 "$APP_DIR"
    chmod 700 "$APP_DIR/logs"
    [ ! -f "$APP_DIR/config.json" ] || chmod 600 "$APP_DIR/config.json"
    [ ! -f "$APP_DIR/state.json" ] || chmod 600 "$APP_DIR/state.json"
    "$VENV_DIR/bin/python" -m py_compile \
        "$APP_DIR/aliyun_guard.py" \
        "$APP_DIR/manager.py" \
        "$APP_DIR/backup_manager.py" \
        "$APP_DIR/s3_backup.py" \
        "$APP_DIR/watchdog.py" \
        "$APP_DIR/telegram_proxy.py" \
        "$APP_DIR/telegram_control.py" \
        "$APP_DIR/web_actions.py" \
        "$APP_DIR/web_panel.py"
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

setup_watchdog_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    cron_old=$(mktemp)
    cron_new=$(mktemp)
    crontab -l > "$cron_old" 2>/dev/null || :
    grep -v '# aliyun-guard-watchdog' "$cron_old" > "$cron_new" || :
    if [ "$START_BACKEND" = yes ]; then
        printf '* * * * * %s/bin/python %s/watchdog.py >> %s/logs/watchdog.log 2>&1 # aliyun-guard-watchdog\n' \
            "$VENV_DIR" "$APP_DIR" "$APP_DIR" >> "$cron_new"
    fi
    crontab "$cron_new"
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
    cat > "/etc/systemd/system/$SERVICE_NAME-watchdog.service" <<EOF
[Unit]
Description=Aliyun Guard heartbeat watchdog
After=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$VENV_DIR/bin/python $APP_DIR/watchdog.py
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
EOF
    cat > "/etc/systemd/system/$SERVICE_NAME-watchdog.timer" <<EOF
[Unit]
Description=Check Aliyun Guard heartbeat every minute

[Timer]
OnBootSec=3min
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "/etc/systemd/system/$SERVICE_NAME.service"
    chmod 644 "/etc/systemd/system/$SERVICE_NAME-watchdog.service" "/etc/systemd/system/$SERVICE_NAME-watchdog.timer"
    if [ -f "/etc/init.d/$SERVICE_NAME" ]; then
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$SERVICE_NAME"
    fi
    remove_cron_entry
    printf '%s\n' systemd > "$APP_DIR/service_backend"
    systemctl daemon-reload
    if [ "$START_BACKEND" = yes ]; then
        rm -f "$APP_DIR/disabled"
        systemctl enable --now "$SERVICE_NAME.service"
        systemctl enable --now "$SERVICE_NAME-watchdog.timer"
    else
        : > "$APP_DIR/disabled"
        chmod 600 "$APP_DIR/disabled"
        systemctl disable "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME-watchdog.timer" >/dev/null 2>&1 || true
        systemctl stop "$SERVICE_NAME-watchdog.timer" >/dev/null 2>&1 || true
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
    rm -f "/etc/systemd/system/$SERVICE_NAME-watchdog.service" "/etc/systemd/system/$SERVICE_NAME-watchdog.timer"
    remove_cron_entry
    printf '%s\n' openrc > "$APP_DIR/service_backend"
    if [ "$START_BACKEND" = yes ]; then
        rm -f "$APP_DIR/disabled"
        setup_watchdog_cron
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start
    else
        : > "$APP_DIR/disabled"
        chmod 600 "$APP_DIR/disabled"
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
    printf '* * * * * %s/bin/python %s/web_panel.py ensure >> %s/logs/web-supervisor.log 2>&1 # aliyun-guard-web\n' \
        "$VENV_DIR" "$APP_DIR" "$APP_DIR" >> "$cron_new"
    if [ "$START_BACKEND" = yes ]; then
        printf '* * * * * %s/bin/python %s/watchdog.py >> %s/logs/watchdog.log 2>&1 # aliyun-guard-watchdog\n' \
            "$VENV_DIR" "$APP_DIR" "$APP_DIR" >> "$cron_new"
    fi
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
    if [ "$START_BACKEND" = yes ]; then
        "$VENV_DIR/bin/python" "$APP_DIR/web_panel.py" ensure >/dev/null 2>&1 || \
            say "${YELLOW}网页面板暂未启动，cron 将在一分钟内自动重试。${RESET}"
    fi
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
    say "网页面板: ${CYAN}aliyun-guard web${RESET}"
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
preserve_local_data
write_payload
restore_local_data
prepare_configuration
setup_backend
finish
