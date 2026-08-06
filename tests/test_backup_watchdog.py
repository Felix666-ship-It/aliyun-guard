import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import aliyun_guard as guard
import backup_manager
import watchdog


class BackupManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        config = copy.deepcopy(guard.DEFAULT_CONFIG)
        config["users"] = [
            {
                "name": "HK",
                "ak": "private-ak",
                "sk": "private-sk",
                "region": "cn-hongkong",
                "instance_id": "i-backup-test",
                "traffic_limit_gb": 180,
                "billing": {"enabled": False},
            }
        ]
        config["telegram"]["node_urls"] = ["ss://private-node"]
        guard.atomic_write_json(self.root / "config.json", config)
        guard.atomic_write_json(self.root / "state.json", {"cycle_count": 2})
        (self.root / "logs").mkdir()
        (self.root / "logs" / "guard.log").write_text("line\n", encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def test_encrypted_backup_round_trip_and_wrong_password(self):
        path = backup_manager.create_backup("correct-password", self.root)
        envelope = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(envelope["cipher"], "aes-256-gcm")
        self.assertNotIn("private-ak", path.read_text(encoding="utf-8"))
        preview = backup_manager.preview_restore(path, "correct-password", self.root)
        self.assertEqual(preview["summary"]["instances"], 1)
        self.assertEqual(preview["summary"]["nodes"], 1)
        with self.assertRaises(backup_manager.BackupError):
            backup_manager.preview_restore(path, "wrong-password", self.root)

    def test_restore_previews_diff_and_creates_safety_backup(self):
        path = backup_manager.create_backup("correct-password", self.root)
        config_path = self.root / "config.json"
        changed = json.loads(config_path.read_text(encoding="utf-8"))
        changed["users"] = []
        guard.atomic_write_json(config_path, changed)
        preview = backup_manager.preview_restore(path, "correct-password", self.root)
        config_change = next(item for item in preview["files"] if item["path"] == "config.json")
        self.assertEqual(config_change["action"], "replace")
        result = backup_manager.restore_backup(path, "correct-password", self.root)
        self.assertTrue(Path(result["safety_backup"]).is_file())
        restored = json.loads(config_path.read_text(encoding="utf-8"))
        self.assertEqual(restored["users"][0]["instance_id"], "i-backup-test")

    def test_program_snapshot_rolls_back_without_touching_config(self):
        (self.root / "manager.py").write_text("old\n", encoding="utf-8")
        (self.root / "version.json").write_text('{"version":"old"}\n', encoding="utf-8")
        snapshot = backup_manager.create_program_snapshot(self.root, "old")
        (self.root / "manager.py").write_text("new\n", encoding="utf-8")
        legacy_temporary = self.root / "manager.py.rollback.tmp"
        legacy_temporary.write_text("sentinel\n", encoding="utf-8")
        result = backup_manager.restore_program_snapshot(snapshot, self.root)
        self.assertEqual(result["version"], "old")
        self.assertEqual(Path(result["snapshot"]), snapshot)
        self.assertEqual((self.root / "manager.py").read_text(encoding="utf-8"), "old\n")
        self.assertEqual(
            legacy_temporary.read_text(encoding="utf-8"), "sentinel\n"
        )
        self.assertTrue((self.root / "config.json").is_file())

    def test_restore_rejects_invalid_config_before_writing(self):
        path = backup_manager.create_backup("correct-password", self.root)
        envelope = json.loads(path.read_text(encoding="utf-8"))
        payload = backup_manager.decrypt_payload(envelope, "correct-password")
        invalid = json.loads(
            backup_manager._b64decode(
                payload["files"]["config.json"]["content"], "config.json"
            ).decode("utf-8")
        )
        invalid["interval_seconds"] = 1
        content = json.dumps(invalid).encode("utf-8")
        payload["files"]["config.json"]["content"] = backup_manager._b64encode(content)
        payload["files"]["config.json"]["sha256"] = __import__("hashlib").sha256(content).hexdigest()
        path.write_text(
            json.dumps(backup_manager.encrypt_payload(payload, "correct-password")),
            encoding="utf-8",
        )
        before = (self.root / "config.json").read_bytes()
        with self.assertRaises(backup_manager.BackupError):
            backup_manager.restore_backup(path, "correct-password", self.root)
        self.assertEqual((self.root / "config.json").read_bytes(), before)

    def test_preview_rejects_oversized_backup_file(self):
        oversized = b"x" * (backup_manager.MAX_FILE_BYTES + 1)
        payload = {
            "files": {
                "config.json": {
                    "content": backup_manager._b64encode(oversized),
                    "sha256": "invalid",
                }
            }
        }
        with self.assertRaises(backup_manager.BackupError):
            backup_manager._preview_payload(payload, self.root)

    def test_preview_hashes_existing_files_without_reading_them_all_at_once(self):
        content = (self.root / "config.json").read_bytes()
        payload = {
            "files": {
                "config.json": {
                    "content": backup_manager._b64encode(content),
                    "sha256": __import__("hashlib").sha256(content).hexdigest(),
                }
            }
        }
        with mock.patch.object(
            Path, "read_bytes", side_effect=AssertionError("unexpected bulk read")
        ):
            preview = backup_manager._preview_payload(payload, self.root)
        self.assertEqual(preview["files"][0]["action"], "unchanged")

    def test_restore_ignores_unsafe_file_mode_from_backup(self):
        path = backup_manager.create_backup("correct-password", self.root)
        envelope = json.loads(path.read_text(encoding="utf-8"))
        payload = backup_manager.decrypt_payload(envelope, "correct-password")
        payload["files"]["config.json"]["mode"] = 0o777
        path.write_text(
            json.dumps(backup_manager.encrypt_payload(payload, "correct-password")),
            encoding="utf-8",
        )
        with mock.patch.object(
            backup_manager.os, "chmod", wraps=backup_manager.os.chmod
        ) as chmod:
            backup_manager.restore_backup(path, "correct-password", self.root)
        restore_modes = [
            call.args[1]
            for call in chmod.call_args_list
            if Path(call.args[0]).name.startswith(".config.json-")
            and str(call.args[0]).endswith(".restore.tmp")
        ]
        self.assertEqual(restore_modes, [0o600])

    def test_restore_does_not_reuse_predictable_temporary_path(self):
        path = backup_manager.create_backup("correct-password", self.root)
        legacy_temporary = self.root / "config.json.restore.tmp"
        legacy_temporary.write_text("sentinel", encoding="utf-8")
        backup_manager.restore_backup(path, "correct-password", self.root)
        self.assertEqual(
            legacy_temporary.read_text(encoding="utf-8"), "sentinel"
        )

    def test_streaming_loader_rejects_trailing_content(self):
        path = backup_manager.create_backup("correct-password", self.root)
        with path.open("ab") as handle:
            handle.write(b"trailing-content")
        with self.assertRaises(backup_manager.BackupError) as raised:
            backup_manager.preview_restore(path, "correct-password", self.root)
        self.assertIn("文件尾无效", str(raised.exception))


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.originals = {
            "HEARTBEAT_FILE": watchdog.HEARTBEAT_FILE,
            "WATCHDOG_STATE_FILE": watchdog.WATCHDOG_STATE_FILE,
            "BACKEND_FILE": watchdog.BACKEND_FILE,
            "DISABLED_FILE": watchdog.DISABLED_FILE,
        }
        watchdog.HEARTBEAT_FILE = self.root / "heartbeat.json"
        watchdog.WATCHDOG_STATE_FILE = self.root / "watchdog-state.json"
        watchdog.BACKEND_FILE = self.root / "service_backend"
        watchdog.DISABLED_FILE = self.root / "disabled"
        self.config = copy.deepcopy(guard.DEFAULT_CONFIG)
        self.config["watchdog"] = {
            "enabled": True,
            "timeout_seconds": 120,
            "failure_threshold": 2,
        }
        self.config["users"] = [
            {
                "ak": "ak",
                "sk": "sk",
                "region": "cn-hongkong",
                "instance_id": "i-watchdog-test",
            }
        ]

    def tearDown(self):
        for name, value in self.originals.items():
            setattr(watchdog, name, value)
        self.temp.cleanup()

    def test_outage_requires_consecutive_checks_and_notifies_once(self):
        with mock.patch.object(guard, "load_config", return_value=self.config), mock.patch.object(
            watchdog, "restart_backend", return_value=(True, "ok")
        ) as restart, mock.patch.object(watchdog, "_notify", return_value=None) as notify:
            first = watchdog.check_once(now=1000)
            second = watchdog.check_once(now=1060)
            third = watchdog.check_once(now=1120)
        self.assertEqual(first["status"], "stale")
        self.assertEqual(second["status"], "outage")
        self.assertEqual(third["status"], "outage")
        self.assertEqual(restart.call_count, 2)
        notify.assert_called_once()

    def test_recovery_sends_notification_and_clears_failure_state(self):
        watchdog._atomic_write(
            watchdog.WATCHDOG_STATE_FILE,
            {"failed_checks": 3, "outage_notified": True},
        )
        watchdog._atomic_write(
            watchdog.HEARTBEAT_FILE,
            {"epoch": 990, "at": "2026-07-19T00:00:00+08:00"},
        )
        with mock.patch.object(guard, "load_config", return_value=self.config), mock.patch.object(
            watchdog, "_notify", return_value=None
        ) as notify:
            result = watchdog.check_once(now=1000, restart=False)
        self.assertEqual(result["status"], "recovered")
        notify.assert_called_once()
        state = watchdog.read_json(watchdog.WATCHDOG_STATE_FILE)
        self.assertEqual(state["failed_checks"], 0)
        self.assertFalse(state["outage_notified"])

    def test_paused_service_does_not_restart_or_notify(self):
        watchdog.DISABLED_FILE.touch()
        watchdog._atomic_write(
            watchdog.WATCHDOG_STATE_FILE,
            {"failed_checks": 3, "outage_notified": True},
        )
        with mock.patch.object(guard, "load_config", return_value=self.config), mock.patch.object(
            watchdog, "restart_backend"
        ) as restart, mock.patch.object(watchdog, "_notify") as notify:
            result = watchdog.check_once(now=1000)
        self.assertEqual(result["status"], "disabled")
        self.assertEqual(result["reason"], "service_paused")
        restart.assert_not_called()
        notify.assert_not_called()
        state = watchdog.read_json(watchdog.WATCHDOG_STATE_FILE)
        self.assertEqual(state["failed_checks"], 0)
        self.assertFalse(state["outage_notified"])

    def test_empty_configuration_is_not_treated_as_outage(self):
        self.config["users"] = []
        with mock.patch.object(guard, "load_config", return_value=self.config), mock.patch.object(
            watchdog, "restart_backend"
        ) as restart:
            result = watchdog.check_once(now=1000)
        self.assertEqual(result["status"], "disabled")
        self.assertEqual(result["reason"], "no_valid_instances")
        restart.assert_not_called()

    def test_nonfinite_and_far_future_heartbeats_are_invalid(self):
        for token in ("NaN", "Infinity"):
            with self.subTest(token=token):
                watchdog.HEARTBEAT_FILE.write_text(
                    '{{"epoch": {}, "at": "invalid"}}'.format(token),
                    encoding="utf-8",
                )
                age, heartbeat = watchdog.heartbeat_age(now=1000)
                self.assertIsNone(age)
                self.assertEqual(heartbeat, {})
        for epoch in (-1, 1301):
            with self.subTest(epoch=epoch):
                watchdog._atomic_write(
                    watchdog.HEARTBEAT_FILE,
                    {"epoch": epoch, "at": "invalid"},
                )
                age, heartbeat = watchdog.heartbeat_age(now=1000)
                self.assertIsNone(age)
                self.assertEqual(heartbeat["at"], "invalid")

    def test_watchdog_state_io_is_bounded_and_uses_unique_temporary_files(self):
        state_path = watchdog.WATCHDOG_STATE_FILE
        state_path.write_bytes(b"x" * 9)
        with mock.patch.object(watchdog, "MAX_STATE_FILE_BYTES", 8):
            self.assertEqual(watchdog.read_json(state_path), {})

        legacy_temporary = state_path.with_name(state_path.name + ".tmp")
        legacy_temporary.write_text("sentinel", encoding="utf-8")
        watchdog._atomic_write(state_path, {"failed_checks": 1})
        self.assertEqual(
            legacy_temporary.read_text(encoding="utf-8"), "sentinel"
        )
        self.assertEqual(watchdog.read_json(state_path)["failed_checks"], 1)

    def test_corrupt_watchdog_counter_is_repaired(self):
        watchdog._atomic_write(
            watchdog.HEARTBEAT_FILE,
            {"epoch": 0, "at": "1970-01-01T00:00:00+00:00"},
        )
        watchdog._atomic_write(
            watchdog.WATCHDOG_STATE_FILE,
            {"failed_checks": "invalid", "outage_notified": "false"},
        )
        with mock.patch.object(guard, "load_config", return_value=self.config):
            result = watchdog.check_once(now=1000, restart=False, notify=False)
        self.assertEqual(result["status"], "stale")
        self.assertEqual(result["failed_checks"], 1)
        state = watchdog.read_json(watchdog.WATCHDOG_STATE_FILE)
        self.assertEqual(state["failed_checks"], 1)
        self.assertFalse(state["outage_notified"])

    def test_failed_outage_notification_is_redacted_and_retried(self):
        self.config["watchdog"]["failure_threshold"] = 1
        self.config["telegram"]["bot_token"] = "private-bot-token"
        with mock.patch.object(
            guard, "load_config", return_value=self.config
        ), mock.patch.object(
            watchdog,
            "_notify",
            side_effect=[RuntimeError("failed private-bot-token"), None],
        ) as notify:
            first = watchdog.check_once(now=1000, restart=False)
            second = watchdog.check_once(now=1060, restart=False)
        self.assertEqual(first["status"], "outage")
        self.assertIn("***", first["notification_error"])
        self.assertNotIn("private-bot-token", first["notification_error"])
        self.assertEqual(second["status"], "outage")
        self.assertIsNone(second["notification_error"])
        self.assertEqual(notify.call_count, 2)
        self.assertTrue(
            watchdog.read_json(watchdog.WATCHDOG_STATE_FILE)["outage_notified"]
        )

    def test_failed_recovery_notification_is_retried(self):
        watchdog._atomic_write(
            watchdog.WATCHDOG_STATE_FILE,
            {"failed_checks": 2, "outage_notified": True},
        )
        watchdog._atomic_write(
            watchdog.HEARTBEAT_FILE,
            {"epoch": 990, "at": "2026-07-19T00:00:00+08:00"},
        )
        with mock.patch.object(
            guard, "load_config", return_value=self.config
        ), mock.patch.object(
            watchdog,
            "_notify",
            side_effect=[RuntimeError("temporary"), None],
        ) as notify:
            first = watchdog.check_once(now=1000, restart=False)
            second = watchdog.check_once(now=1010, restart=False)
        self.assertEqual(first["status"], "recovered")
        self.assertEqual(first["notification_error"], "temporary")
        self.assertEqual(second["status"], "recovered")
        self.assertIsNone(second["notification_error"])
        self.assertEqual(notify.call_count, 2)
        self.assertFalse(
            watchdog.read_json(watchdog.WATCHDOG_STATE_FILE)["outage_notified"]
        )


class DiscoveryTests(unittest.TestCase):
    def test_region_discovery_parses_account_regions(self):
        response = {
            "Regions": {
                "Region": [
                    {"RegionId": "cn-hongkong"},
                    {"RegionId": "ap-southeast-1"},
                ]
            }
        }

        class Client:
            def do_action_with_exception(self, _request):
                return json.dumps(response).encode("utf-8")

        request = mock.Mock()
        with mock.patch.object(guard, "require_sdk"), mock.patch.object(
            guard, "CommonRequest", return_value=request
        ), mock.patch.object(guard, "make_client", return_value=Client()):
            regions = guard.discover_ecs_regions("ak", "sk")
        self.assertEqual(regions, ["cn-hongkong", "ap-southeast-1"])
        request.set_action_name.assert_called_once_with("DescribeRegions")

    def test_discovery_filters_tags_and_reports_region_errors(self):
        responses = {
            "cn-hongkong": {
                "TotalCount": 2,
                "Instances": {
                    "Instance": [
                        {
                            "InstanceId": "i-prod",
                            "InstanceName": "Prod",
                            "Status": "Running",
                            "Tags": {"Tag": [{"TagKey": "env", "TagValue": "prod"}]},
                            "PublicIpAddress": {"IpAddress": ["203.0.113.1"]},
                        },
                        {
                            "InstanceId": "i-dev",
                            "InstanceName": "Dev",
                            "Status": "Stopped",
                            "Tags": {"Tag": [{"TagKey": "env", "TagValue": "dev"}]},
                        },
                    ]
                },
            }
        }

        class Client:
            def __init__(self, region):
                self.region = region

            def do_action_with_exception(self, _request):
                if self.region == "cn-shanghai":
                    raise RuntimeError("NoPermission")
                return json.dumps(responses[self.region]).encode("utf-8")

        with mock.patch.object(guard, "require_sdk"), mock.patch.object(
            guard, "DescribeInstancesRequest", return_value=mock.Mock()
        ), mock.patch.object(
            guard, "make_client", side_effect=lambda _user, region=None: Client(region)
        ):
            result = guard.discover_ecs_instances(
                "ak", "sk", ["cn-hongkong", "cn-shanghai"], "env", "prod"
            )
        self.assertEqual([item["instance_id"] for item in result["instances"]], ["i-prod"])
        self.assertEqual(result["errors"][0]["region"], "cn-shanghai")
        self.assertNotIn("ak", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
