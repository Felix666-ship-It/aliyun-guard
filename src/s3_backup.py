#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Encrypted backup storage for AWS S3 and S3-compatible services."""

import contextlib
import datetime as dt
import importlib
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.parse

boto3 = None
Config = None
TransferConfig = None
BotoCoreError = ClientError = RuntimeError
BOTO_IMPORT_ERROR = None
backup_manager = None

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


def _load_boto3():
    global boto3, Config, TransferConfig, BotoCoreError, ClientError, BOTO_IMPORT_ERROR
    if boto3 is not None:
        return
    if BOTO_IMPORT_ERROR is not None:
        raise S3BackupError("缺少 S3 依赖 boto3: {}".format(BOTO_IMPORT_ERROR))
    try:
        boto3 = importlib.import_module("boto3")
        Config = importlib.import_module("botocore.config").Config
        exceptions = importlib.import_module("botocore.exceptions")
        BotoCoreError = exceptions.BotoCoreError
        ClientError = exceptions.ClientError
        TransferConfig = importlib.import_module("boto3.s3.transfer").TransferConfig
    except ImportError as exc:  # pragma: no cover - installer supplies boto3
        BOTO_IMPORT_ERROR = exc
        raise S3BackupError("缺少 S3 依赖 boto3: {}".format(exc)) from exc


def _backup_manager():
    global backup_manager
    if backup_manager is None:
        backup_manager = importlib.import_module("backup_manager")
    return backup_manager


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
    _load_boto3()


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
    if ClientError is not RuntimeError and isinstance(exc, ClientError):
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
    backups = _backup_manager()
    result = {
        "ContentType": "application/json",
        "Metadata": {"format": backups.BACKUP_FORMAT},
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
    backups = _backup_manager()
    now = now or dt.datetime.now().astimezone()
    stamp = now.strftime("%Y%m%d-%H%M%S-%f")
    filename = "aliyun-guard-s3-{}.agbackup".format(stamp)
    local_path = Path(app_dir) / "backups" / filename
    backups.create_backup(
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
                    multipart_threshold=backups.MAX_BACKUP_FILE_BYTES + 1
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
    backups = _backup_manager()
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
        if int(metadata.get("ContentLength", 0)) > backups.MAX_BACKUP_FILE_BYTES:
            raise S3BackupError("S3 备份文件超过大小限制")
        _call(
            "下载 S3 加密备份",
            lambda: client.download_file(config["bucket"], key, str(temporary)),
            secrets=_config_secrets(config),
        )
        if temporary.stat().st_size > backups.MAX_BACKUP_FILE_BYTES:
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
