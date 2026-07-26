#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Authenticated backups and local program rollback snapshots."""

import base64
import datetime as dt
import hashlib
import hmac
import importlib
import json
import os
from pathlib import Path
import secrets
import shutil
import tarfile
import tempfile

AESGCM = None
CRYPTOGRAPHY_IMPORT_ERROR = None


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
BACKUP_DIR = Path(os.environ.get("ALIYUN_GUARD_BACKUP_DIR", APP_DIR / "backups"))
BACKUP_FORMAT = "aliyun-guard-backup-v1"
SNAPSHOT_FORMAT = "aliyun-guard-program-v1"
PBKDF2_ITERATIONS = 240000
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_BACKUP_BYTES = 64 * 1024 * 1024
MAX_BACKUP_FILE_BYTES = 88 * 1024 * 1024
# Base64 and JSON metadata expand source files before encryption. Keep collection
# below the encrypted payload limit without building an oversized object in RAM.
MAX_BACKUP_SOURCE_BYTES = 45 * 1024 * 1024

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
    global AESGCM, CRYPTOGRAPHY_IMPORT_ERROR
    if AESGCM is not None:
        return
    if CRYPTOGRAPHY_IMPORT_ERROR is not None:
        raise BackupError(
            "缺少备份加密依赖 cryptography: {}".format(CRYPTOGRAPHY_IMPORT_ERROR)
        )
    try:
        AESGCM = importlib.import_module(
            "cryptography.hazmat.primitives.ciphers.aead"
        ).AESGCM
    except ImportError as exc:
        CRYPTOGRAPHY_IMPORT_ERROR = exc
        raise BackupError("缺少备份加密依赖 cryptography: {}".format(exc)) from exc


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


def _write_encrypted_payload(payload, passphrase, destination, iterations=PBKDF2_ITERATIONS):
    """Write the existing v1 envelope without materializing plaintext/ciphertext twice."""
    _require_cryptography()
    try:
        cipher_module = importlib.import_module(
            "cryptography.hazmat.primitives.ciphers"
        )
        algorithms = importlib.import_module(
            "cryptography.hazmat.primitives.ciphers.algorithms"
        )
        modes = importlib.import_module("cryptography.hazmat.primitives.ciphers.modes")
    except ImportError as exc:
        raise BackupError("缺少备份加密依赖 cryptography: {}".format(exc)) from exc

    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    salt = secrets.token_bytes(16)
    nonce = secrets.token_bytes(12)
    encryption_key = _derive_keys(passphrase, salt, iterations)
    associated_data = (
        BACKUP_FORMAT.encode("ascii") + b"\0" + str(int(iterations)).encode("ascii")
    )
    descriptor, ciphertext_name = tempfile.mkstemp(
        prefix=".{}-".format(destination.name), suffix=".cipher.tmp", dir=str(destination.parent)
    )
    ciphertext_path = Path(ciphertext_name)
    envelope_path = None
    try:
        encryptor = cipher_module.Cipher(
            algorithms.AES(encryption_key), modes.GCM(nonce)
        ).encryptor()
        encryptor.authenticate_additional_data(associated_data)
        plaintext_size = 0
        encoder = json.JSONEncoder(
            ensure_ascii=False, separators=(",", ":"), sort_keys=True
        )
        with os.fdopen(descriptor, "wb") as handle:
            for piece in encoder.iterencode(payload):
                data = piece.encode("utf-8")
                plaintext_size += len(data)
                if plaintext_size > MAX_BACKUP_BYTES:
                    raise BackupError(
                        "备份内容超过 {} MiB 限制".format(
                            MAX_BACKUP_BYTES // 1048576
                        )
                    )
                handle.write(encryptor.update(data))
            handle.write(encryptor.finalize())
            handle.write(encryptor.tag)
            handle.flush()
            os.fsync(handle.fileno())

        descriptor, envelope_name = tempfile.mkstemp(
            prefix=".{}-".format(destination.name), suffix=".envelope.tmp", dir=str(destination.parent)
        )
        envelope_path = Path(envelope_name)
        fields = (
            ("format", BACKUP_FORMAT),
            ("created_at", _now_text()),
            ("kdf", "pbkdf2-hmac-sha256"),
            ("cipher", "aes-256-gcm"),
            ("iterations", int(iterations)),
            ("salt", _b64encode(salt)),
            ("nonce", _b64encode(nonce)),
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write("{\n")
            for key, value in fields:
                handle.write(
                    "  {}: {},\n".format(
                        json.dumps(key), json.dumps(value, ensure_ascii=True)
                    )
                )
            handle.write('  "ciphertext": "')
            with ciphertext_path.open("rb") as ciphertext:
                while True:
                    chunk = ciphertext.read(768 * 1024)
                    if not chunk:
                        break
                    handle.write(_b64encode(chunk))
            handle.write("\"\n}\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(str(envelope_path), 0o600)
        os.replace(str(envelope_path), str(destination))
    finally:
        ciphertext_path.unlink(missing_ok=True)
        if envelope_path is not None:
            envelope_path.unlink(missing_ok=True)


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


class _StreamingBackupUnavailable(RuntimeError):
    pass


def _load_backup_streaming(path, passphrase):
    """Decode the v1 JSON envelope without holding its Base64 ciphertext in RAM."""
    backup_path = Path(path)
    markers = (b'"ciphertext": "', b'"ciphertext":"')
    with backup_path.open("rb") as source:
        header = b""
        marker_index = -1
        marker = None
        while len(header) <= 65536:
            chunk = source.read(8192)
            if not chunk:
                break
            header += chunk
            found = [(header.find(value), value) for value in markers]
            found = [item for item in found if item[0] >= 0]
            if found:
                marker_index, marker = min(found, key=lambda item: item[0])
                break
        if marker is None:
            raise _StreamingBackupUnavailable()
        try:
            prefix = header[:marker_index].decode("utf-8").rstrip()
            envelope = json.loads(prefix.rstrip(",") + "\n}")
        except (UnicodeDecodeError, ValueError) as exc:
            raise BackupError("备份文件头无效") from exc
        if not isinstance(envelope, dict) or envelope.get("format") != BACKUP_FORMAT:
            raise BackupError("不是受支持的 Aliyun Guard 备份")
        try:
            iterations = int(envelope.get("iterations"))
        except (TypeError, ValueError) as exc:
            raise BackupError("备份 KDF 参数无效") from exc
        if iterations < 100000 or iterations > 2000000:
            raise BackupError("备份 KDF 参数超出安全范围")
        if envelope.get("cipher") != "aes-256-gcm":
            raise BackupError("备份加密算法不受支持")
        salt = _b64decode(envelope.get("salt", ""), "salt")
        nonce = _b64decode(envelope.get("nonce", ""), "nonce")
        encryption_key = _derive_keys(passphrase, salt, iterations)
        associated_data = (
            BACKUP_FORMAT.encode("ascii") + b"\0" + str(iterations).encode("ascii")
        )
        try:
            cipher_module = importlib.import_module(
                "cryptography.hazmat.primitives.ciphers"
            )
            algorithms = importlib.import_module(
                "cryptography.hazmat.primitives.ciphers.algorithms"
            )
            modes = importlib.import_module(
                "cryptography.hazmat.primitives.ciphers.modes"
            )
        except ImportError as exc:
            raise BackupError("缺少备份加密依赖 cryptography: {}".format(exc)) from exc
        decryptor = cipher_module.Cipher(
            algorithms.AES(encryption_key), modes.GCM(nonce)
        ).decryptor()
        decryptor.authenticate_additional_data(associated_data)
        descriptor, plaintext_name = tempfile.mkstemp(
            prefix=".{}-".format(backup_path.name),
            suffix=".plaintext.tmp",
            dir=str(backup_path.parent),
        )
        plaintext_path = Path(plaintext_name)
        ciphertext_size = 0
        tail = b""
        remainder = b""

        def write_decoded(encoded, handle):
            nonlocal ciphertext_size, tail, remainder
            data = remainder + encoded
            usable = len(data) - (len(data) % 4)
            if usable:
                try:
                    decoded = base64.b64decode(data[:usable], validate=True)
                except Exception as exc:
                    raise BackupError("备份中的 ciphertext 格式无效") from exc
                ciphertext_size += len(decoded)
                if ciphertext_size > MAX_BACKUP_BYTES + 16:
                    raise BackupError("备份内容过大")
                tail += decoded
                if len(tail) > 16:
                    handle.write(decryptor.update(tail[:-16]))
                    tail = tail[-16:]
            remainder = data[usable:]

        try:
            encoded = header[marker_index + len(marker):]
            with os.fdopen(descriptor, "wb") as plaintext:
                while True:
                    closing_quote = encoded.find(b'"')
                    if closing_quote >= 0:
                        write_decoded(encoded[:closing_quote], plaintext)
                        break
                    write_decoded(encoded, plaintext)
                    encoded = source.read(64 * 1024)
                    if not encoded:
                        raise BackupError("备份中的 ciphertext 不完整")
                if remainder:
                    try:
                        decoded = base64.b64decode(remainder, validate=True)
                    except Exception as exc:
                        raise BackupError("备份中的 ciphertext 格式无效") from exc
                    ciphertext_size += len(decoded)
                    tail += decoded
                    remainder = b""
                if len(tail) != 16:
                    raise BackupError("备份中的 ciphertext 无效")
                try:
                    plaintext.write(decryptor.finalize_with_tag(tail))
                except Exception as exc:
                    raise BackupError("备份密码错误或文件已损坏") from exc
                plaintext.flush()
                os.fsync(plaintext.fileno())
            try:
                with plaintext_path.open("r", encoding="utf-8") as plaintext:
                    payload = json.load(plaintext)
            except (OSError, UnicodeDecodeError, ValueError) as exc:
                raise BackupError("备份解密后内容无效") from exc
            if not isinstance(payload, dict) or not isinstance(payload.get("files"), dict):
                raise BackupError("备份内容结构无效")
            return payload
        finally:
            plaintext_path.unlink(missing_ok=True)


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
    total_size = 0

    def add_file(name, path):
        nonlocal total_size
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            raise BackupError("文件过大，未加入备份: {}".format(path.name))
        total_size += size
        if total_size > MAX_BACKUP_SOURCE_BYTES:
            raise BackupError(
                "备份源文件超过 {} MiB 限制".format(
                    MAX_BACKUP_SOURCE_BYTES // 1048576
                )
            )
        data = path.read_bytes()
        files[name] = {
            "content": _b64encode(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "mode": int(path.stat().st_mode & 0o777),
        }

    selected = ["config.json", "service_backend"]
    if include_state:
        selected.extend(("state.json", "telegram-control-state.json"))
    for name in selected:
        path = root / name
        if path.is_file():
            add_file(name, path)
    if include_logs:
        log_dir = root / "logs"
        if log_dir.is_dir():
            for path in sorted(log_dir.rglob("*")):
                if not path.is_file():
                    continue
                relative = "logs/" + path.relative_to(log_dir).as_posix()
                add_file(relative, path)
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
    destination = Path(output_path) if output_path else root / "backups" / (
        "aliyun-guard-{}.agbackup".format(_stamp())
    )
    _write_encrypted_payload(payload, passphrase, destination)
    return destination


def load_backup(path, passphrase):
    backup_path = Path(path)
    try:
        return _load_backup_streaming(backup_path, passphrase)
    except _StreamingBackupUnavailable:
        pass
    try:
        with backup_path.open("r", encoding="utf-8") as handle:
            envelope = json.load(handle)
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


def _preview_payload(payload, app_dir=APP_DIR):
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


def preview_restore(path, passphrase, app_dir=APP_DIR):
    return _preview_payload(load_backup(path, passphrase), app_dir)


def restore_backup(path, passphrase, app_dir=APP_DIR, include_logs=True):
    payload = load_backup(path, passphrase)
    preview = _preview_payload(payload, app_dir)
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
