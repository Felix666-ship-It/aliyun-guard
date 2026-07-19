import copy
import datetime as dt
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import aliyun_guard as guard
import s3_backup
import web_actions


def ready_config():
    config = copy.deepcopy(s3_backup.DEFAULT_CONFIG)
    config.update(
        {
            "enabled": True,
            "bucket": "guard-backups",
            "region": "us-east-1",
            "prefix": "aliyun-guard",
            "backup_password": "correct-password",
            "retention": 2,
        }
    )
    return config


class FakeS3Client:
    def __init__(self):
        self.objects = {}
        self.uploads = []
        self.deleted = []

    def list_objects_v2(self, **kwargs):
        prefix = kwargs.get("Prefix", "")
        contents = []
        for key, content in self.objects.items():
            if key.startswith(prefix):
                day = 19 if "aliyun-guard-s3-" in key else 18
                contents.append(
                    {
                        "Key": key,
                        "Size": len(content),
                        "LastModified": dt.datetime(2026, 7, day, tzinfo=dt.timezone.utc),
                        "ETag": '"etag"',
                    }
                )
        return {"Contents": contents, "IsTruncated": False}

    def upload_file(self, path, bucket, key, ExtraArgs=None, Config=None):
        self.objects[key] = Path(path).read_bytes()
        self.uploads.append((bucket, key, ExtraArgs, Config))

    def delete_object(self, Bucket, Key):
        self.objects.pop(Key, None)
        self.deleted.append((Bucket, Key))

    def head_object(self, Bucket, Key):
        return {"ContentLength": len(self.objects[Key])}

    def download_file(self, bucket, key, path):
        Path(path).write_bytes(self.objects[key])


class S3BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        config = copy.deepcopy(guard.DEFAULT_CONFIG)
        config["users"] = [
            {
                "name": "HK",
                "ak": "private-aliyun-ak",
                "sk": "private-aliyun-sk",
                "region": "cn-hongkong",
                "instance_id": "i-s3-test",
                "traffic_limit_gb": 180,
                "billing": {"enabled": False},
            }
        ]
        config["s3_backup"] = ready_config()
        guard.atomic_write_json(self.root / "config.json", config)

    def tearDown(self):
        self.temp.cleanup()

    def test_validation_supports_iam_role_and_rejects_partial_credentials(self):
        config = ready_config()
        validated = s3_backup.validate_config(config)
        self.assertEqual(validated["bucket"], "guard-backups")
        config["access_key_id"] = "only-id"
        with self.assertRaises(s3_backup.S3BackupError):
            s3_backup.validate_config(config)
        config = ready_config()
        config["endpoint_url"] = "http://minio.example:9000"
        with self.assertRaises(s3_backup.S3BackupError):
            s3_backup.validate_config(config)
        config["endpoint_url"] = "http://127.0.0.1:9000"
        self.assertEqual(
            s3_backup.validate_config(config)["endpoint_url"],
            "http://127.0.0.1:9000",
        )

    def test_schedule_slots_and_duplicate_attempt_suppression(self):
        config = ready_config()
        config.update({"schedule": "daily", "time": "03:00"})
        before = dt.datetime(2026, 7, 19, 2, 59, tzinfo=dt.timezone.utc)
        after = dt.datetime(2026, 7, 19, 3, 1, tzinfo=dt.timezone.utc)
        self.assertIsNone(s3_backup.schedule_slot(config, before))
        self.assertEqual(s3_backup.schedule_slot(config, after), "daily:20260719")
        uploaded = {"ok": True, "key": "aliyun-guard/test.agbackup", "deleted": []}
        with mock.patch.object(s3_backup, "create_and_upload", return_value=uploaded) as run:
            first = s3_backup.run_if_due(config, self.root, now=after)
            second = s3_backup.run_if_due(config, self.root, now=after)
        self.assertTrue(first["ok"])
        self.assertIsNone(second)
        run.assert_called_once()

    def test_failure_state_redacts_credentials(self):
        config = ready_config()
        config.update(
            {
                "access_key_id": "s3-private-id",
                "secret_access_key": "s3-private-secret",
            }
        )
        now = dt.datetime(2026, 7, 19, 4, 0, tzinfo=dt.timezone.utc)
        with mock.patch.object(
            s3_backup,
            "create_and_upload",
            side_effect=RuntimeError("s3-private-id s3-private-secret correct-password"),
        ):
            result = s3_backup.run_if_due(config, self.root, now=now)
        self.assertFalse(result["ok"])
        state_text = (self.root / s3_backup.STATE_NAME).read_text(encoding="utf-8")
        self.assertNotIn("s3-private-id", state_text)
        self.assertNotIn("s3-private-secret", state_text)
        self.assertNotIn("correct-password", state_text)

    def test_upload_is_encrypted_and_prunes_old_remote_objects(self):
        client = FakeS3Client()
        client.objects.update(
            {
                "aliyun-guard/old-1.agbackup": b"old1",
                "aliyun-guard/old-2.agbackup": b"old2",
            }
        )
        config = ready_config()
        with mock.patch.object(s3_backup, "create_client", return_value=client), mock.patch.object(
            s3_backup, "TransferConfig", side_effect=lambda **kwargs: kwargs
        ):
            result = s3_backup.create_and_upload(
                config,
                self.root,
                now=dt.datetime(2026, 7, 19, 5, 0, tzinfo=dt.timezone.utc),
            )
        uploaded = client.objects[result["key"]]
        self.assertNotIn(b"private-aliyun-sk", uploaded)
        self.assertEqual(client.uploads[0][2]["ServerSideEncryption"], "AES256")
        self.assertGreater(
            client.uploads[0][3]["multipart_threshold"],
            s3_backup.backup_manager.MAX_BACKUP_FILE_BYTES,
        )
        self.assertEqual(len(result["deleted"]), 1)

    def test_failed_slot_retries_after_fifteen_minutes(self):
        config = ready_config()
        first_time = dt.datetime(2026, 7, 19, 4, 0, tzinfo=dt.timezone.utc)
        retry_time = first_time + dt.timedelta(minutes=16)
        with mock.patch.object(
            s3_backup, "create_and_upload", side_effect=RuntimeError("temporary")
        ) as run:
            first = s3_backup.run_if_due(config, self.root, now=first_time)
            early = s3_backup.run_if_due(
                config, self.root, now=first_time + dt.timedelta(minutes=5)
            )
            retry = s3_backup.run_if_due(config, self.root, now=retry_time)
        self.assertFalse(first["ok"])
        self.assertIsNone(early)
        self.assertFalse(retry["ok"])
        self.assertEqual(run.call_count, 2)

    def test_download_rejects_key_outside_prefix(self):
        with self.assertRaises(s3_backup.S3BackupError):
            s3_backup.download_backup(
                ready_config(), "another-prefix/backup.agbackup", self.root
            )


class S3WebActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.original_config = guard.CONFIG_FILE
        guard.CONFIG_FILE = self.root / "config.json"
        config = copy.deepcopy(guard.DEFAULT_CONFIG)
        config["users"] = [
            {
                "name": "HK",
                "ak": "ak",
                "sk": "sk",
                "region": "cn-hongkong",
                "instance_id": "i-web-s3",
                "traffic_limit_gb": 180,
                "billing": {"enabled": False},
            }
        ]
        config["s3_backup"] = ready_config()
        config["s3_backup"].update(
            {
                "access_key_id": "private-s3-id",
                "secret_access_key": "private-s3-secret",
                "session_token": "private-session-token",
                "kms_key_id": "private-kms-key",
            }
        )
        guard.atomic_write_json(guard.CONFIG_FILE, config)

    def tearDown(self):
        guard.CONFIG_FILE = self.original_config
        self.temp.cleanup()

    def test_management_payload_redacts_every_s3_secret(self):
        with mock.patch.object(web_actions, "DATA_DIR", self.root):
            payload = web_actions.management_payload(guard)
        serialized = json.dumps(payload, ensure_ascii=False)
        for secret in (
            "private-s3-id",
            "private-s3-secret",
            "private-session-token",
            "correct-password",
            "private-kms-key",
        ):
            self.assertNotIn(secret, serialized)
        self.assertTrue(payload["s3_backup"]["access_key_configured"])
        self.assertTrue(payload["s3_backup"]["backup_password_configured"])

    def test_blank_secrets_preserve_values_and_iam_role_clears_credentials(self):
        data = {
            "enabled": True,
            "bucket": "guard-backups",
            "region": "us-east-1",
            "endpoint_url": "",
            "prefix": "aliyun-guard",
            "addressing_style": "auto",
            "use_iam_role": False,
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
        with mock.patch.object(web_actions, "DATA_DIR", self.root):
            web_actions.save_s3_backup_settings(guard, data)
        saved = guard.load_config()["s3_backup"]
        self.assertEqual(saved["secret_access_key"], "private-s3-secret")
        self.assertEqual(saved["backup_password"], "correct-password")
        data["use_iam_role"] = True
        with mock.patch.object(web_actions, "DATA_DIR", self.root):
            web_actions.save_s3_backup_settings(guard, data)
        saved = guard.load_config()["s3_backup"]
        self.assertEqual(saved["access_key_id"], "")
        self.assertEqual(saved["secret_access_key"], "")


if __name__ == "__main__":
    unittest.main()
