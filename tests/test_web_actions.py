import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import aliyun_guard as guard
import web_actions
import web_panel


NODE_URL = (
    "vless://11111111-1111-1111-1111-111111111111@node.example:443"
    "?security=tls&type=tcp#Saved"
)


def instance_config():
    return {
        "name": "HK",
        "ak": "private-access-key",
        "sk": "private-secret-key",
        "region": "cn-hongkong",
        "instance_id": "i-test-web-actions",
        "traffic_limit_gb": 180,
        "actions_enabled": True,
        "instance_log_enabled": False,
        "paused": False,
        "billing": {"enabled": False, "site": "china"},
        "schedule": {
            "enabled": False,
            "start_time": "08:00",
            "stop_time": "23:00",
        },
    }


class WebActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.original_config = guard.CONFIG_FILE
        guard.CONFIG_FILE = Path(self.temp.name) / "config.json"
        self.config = copy.deepcopy(guard.DEFAULT_CONFIG)
        self.config["telegram"].update(
            {
                "bot_token": "private-bot-token",
                "chat_id": "123456",
                "connection_mode": "direct",
            }
        )
        self.config["users"] = [instance_config()]
        guard.atomic_write_json(guard.CONFIG_FILE, self.config)

    def tearDown(self):
        guard.CONFIG_FILE = self.original_config
        self.temp.cleanup()

    def test_management_payload_never_returns_raw_secrets_or_node_links(self):
        config = guard.load_config()
        config["telegram"].update(
            {
                "connection_mode": "socks5",
                "proxy_url": "socks5://proxy-user:proxy-pass@proxy.example:1080",
                "node_urls": [NODE_URL],
            }
        )
        config["web_panel"]["password_hash"] = web_panel.hash_password(
            "web-password", iterations=1000
        )
        guard.atomic_write_json(guard.CONFIG_FILE, config)
        payload = web_actions.management_payload(guard, "systemd")
        serialized = json.dumps(payload, ensure_ascii=False)
        for secret in (
            "private-access-key",
            "private-secret-key",
            "private-bot-token",
            "proxy-pass",
            NODE_URL,
            config["web_panel"]["password_hash"],
        ):
            self.assertNotIn(secret, serialized)
        self.assertTrue(payload["telegram"]["proxy_configured"])
        self.assertNotIn("proxy_display", payload["telegram"])
        self.assertNotIn("api_base_display", payload["telegram"])
        self.assertNotIn("access_key", payload["instances"][0])
        self.assertFalse(payload["instances"][0]["instance_log_enabled"])
        self.assertEqual(payload["telegram"]["nodes"][0]["description"], "VLESS 节点（Saved）")
        self.assertTrue(payload["telegram"]["control_enabled"])
        self.assertEqual(payload["telegram"]["control_effective_admin_ids"], [123456])
        self.assertTrue(payload["telegram"]["control_uses_chat_id"])

    def test_updates_bot_control_admins(self):
        result = web_actions.update_telegram_identity(
            guard,
            {
                "bot_token": "",
                "chat_id": "123456",
                "timeout_seconds": 12,
                "retries": 3,
                "control_enabled": True,
                "control_admin_ids": "9001, 9002",
            },
        )
        self.assertTrue(result["control_enabled"])
        self.assertEqual(result["control_admin_ids"], [9001, 9002])
        self.assertEqual(result["control_effective_admin_ids"], [9001, 9002])
        saved = guard.load_config()["telegram"]
        self.assertEqual(saved["control_admin_ids"], [9001, 9002])

    def test_instance_logging_switch_persists(self):
        result = web_actions.update_instance_logging(guard, 0, True)
        self.assertTrue(result["enabled"])
        self.assertTrue(result["instance"]["instance_log_enabled"])
        self.assertTrue(guard.load_config()["users"][0]["instance_log_enabled"])
        result = web_actions.update_instance_logging(guard, 0, False)
        self.assertFalse(result["enabled"])
        self.assertFalse(guard.load_config()["users"][0]["instance_log_enabled"])

    def test_failed_instance_validation_does_not_save_without_force(self):
        data = {
            "name": "New",
            "ak": "new-access-key",
            "sk": "new-secret-key",
            "region": "cn-shanghai",
            "instance_id": "i-new-instance",
            "traffic_limit_gb": 100,
            "actions_enabled": True,
            "billing": {"enabled": False, "site": "china"},
            "schedule": {
                "enabled": False,
                "start_time": "08:00",
                "stop_time": "23:00",
            },
        }
        validation = {
            "ok": False,
            "traffic_gb": None,
            "status": None,
            "bill_amount": None,
            "bill_currency": None,
            "billing_enabled": False,
            "errors": ["ECS 校验失败"],
        }
        with mock.patch.object(
            guard, "validate_user_connection", return_value=validation
        ):
            with self.assertRaises(web_actions.ManagementError) as raised:
                web_actions.save_instance(guard, data)
            self.assertEqual(raised.exception.status, 422)
            self.assertEqual(len(guard.load_config()["users"]), 1)
            data["force_save"] = True
            result = web_actions.save_instance(guard, data)
        self.assertTrue(result["saved"])
        self.assertEqual(len(guard.load_config()["users"]), 2)

    def test_blank_web_password_preserves_hash(self):
        config = guard.load_config()
        password_hash = web_panel.hash_password("existing-password", iterations=1000)
        config["web_panel"].update(
            {
                "enabled": True,
                "host": "127.0.0.1",
                "port": 8765,
                "username": "admin",
                "password_hash": password_hash,
            }
        )
        guard.atomic_write_json(guard.CONFIG_FILE, config)
        result = web_actions.update_web_settings(
            guard,
            {
                "enabled": True,
                "host": "127.0.0.1",
                "port": 9000,
                "username": "operator",
                "password": "",
                "password_confirm": "",
            },
        )
        self.assertTrue(result["password_configured"])
        self.assertNotIn("password_hash", result)
        saved = guard.load_config()["web_panel"]
        self.assertEqual(saved["password_hash"], password_hash)
        self.assertEqual(saved["port"], 9000)

    def test_node_is_saved_only_after_success_and_does_not_switch_mode(self):
        result = {
            "username": "example_bot",
            "latency_ms": 120.0,
            "latency_attempts": 3,
            "connection": "节点链接",
        }
        with mock.patch.object(web_actions, "_telegram_test", return_value=result), mock.patch.object(
            web_actions.telegram_proxy, "stop_node_proxy"
        ):
            saved = web_actions.add_telegram_node(guard, {"node_url": NODE_URL})
        self.assertTrue(saved["saved"])
        telegram = guard.load_config()["telegram"]
        self.assertEqual(telegram["connection_mode"], "direct")
        self.assertIn(NODE_URL, telegram["node_urls"])

    def test_failed_node_test_does_not_save_link(self):
        with mock.patch.object(
            web_actions,
            "_telegram_test",
            side_effect=web_actions.ManagementError("Telegram 测试失败", 502),
        ):
            with self.assertRaises(web_actions.ManagementError):
                web_actions.add_telegram_node(guard, {"node_url": NODE_URL})
        self.assertNotIn(NODE_URL, guard.load_config()["telegram"]["node_urls"])

    def test_container_rejects_internal_listener_changes(self):
        config = guard.load_config()
        config["web_panel"].update(
            {
                "enabled": True,
                "host": "0.0.0.0",
                "port": 8765,
                "username": "admin",
                "password_hash": web_panel.hash_password(
                    "existing-password", iterations=1000
                ),
            }
        )
        guard.atomic_write_json(guard.CONFIG_FILE, config)
        with mock.patch.dict(
            "os.environ",
            {
                "ALIYUN_GUARD_CONTAINER": "1",
                "ALIYUN_GUARD_CONTAINER_WEB_PORT": "8765",
            },
        ):
            with self.assertRaises(web_actions.ManagementError) as raised:
                web_actions.update_web_settings(
                    guard,
                    {
                        "enabled": True,
                        "host": "127.0.0.1",
                        "port": 8765,
                        "username": "admin",
                        "password": "",
                        "password_confirm": "",
                    },
                )
        self.assertEqual(raised.exception.status, 409)

    def test_container_restart_targets_pid_one(self):
        with mock.patch.dict("os.environ", {"ALIYUN_GUARD_CONTAINER": "1"}), mock.patch.object(
            web_actions, "detached_process", return_value=77
        ) as detached:
            self.assertEqual(web_actions.service_command("restart"), 77)
        command = detached.call_args.args[0]
        self.assertEqual(command[:2], ["/bin/sh", "-c"])
        self.assertIn("kill -TERM 1", command[2])

    def test_container_self_update_is_rejected(self):
        with mock.patch.dict("os.environ", {"ALIYUN_GUARD_CONTAINER": "1"}):
            with self.assertRaises(web_actions.ManagementError) as raised:
                web_actions.install_update()
        self.assertEqual(raised.exception.status, 409)
        self.assertIn("docker compose", str(raised.exception))

    def test_systemd_update_uses_independent_transient_unit(self):
        app_dir = Path(self.temp.name) / "app"
        app_dir.mkdir()
        manager_path = app_dir / "manager.py"
        manager_path.write_text("# manager\n", encoding="utf-8")
        (app_dir / "service_backend").write_text("systemd\n", encoding="utf-8")
        completed = subprocess.CompletedProcess([], 0, "")
        with mock.patch.dict("os.environ", {"ALIYUN_GUARD_CONTAINER": "0"}), mock.patch.object(
            web_actions, "APP_DIR", app_dir
        ), mock.patch.object(
            web_actions.shutil, "which", return_value="/usr/bin/systemd-run"
        ), mock.patch.object(
            web_actions.subprocess, "run", return_value=completed
        ) as run, mock.patch.object(
            web_actions, "detached_process"
        ) as detached:
            unit = web_actions.install_update("1.5.4")
        self.assertTrue(unit.startswith("aliyun-guard-update-"))
        detached.assert_not_called()
        launcher = run.call_args.args[0]
        self.assertEqual(launcher[0], "/usr/bin/systemd-run")
        self.assertIn("--no-block", launcher)
        self.assertIn("--unit={}".format(unit), launcher)
        self.assertIn(str(manager_path), launcher)
        self.assertIn(str(app_dir / "logs" / "web-update.log"), launcher)
        self.assertIn("-u", launcher)
        self.assertIn(web_actions.UPDATE_EXIT_MARKER, launcher[6])
        state = json.loads(
            (app_dir / "logs" / web_actions.UPDATE_STATE_NAME).read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(state["target_version"], "1.5.4")
        self.assertEqual(state["job"], unit)

    def test_systemd_update_without_systemd_run_reports_cli_fallback(self):
        app_dir = Path(self.temp.name) / "app"
        app_dir.mkdir()
        (app_dir / "manager.py").write_text("# manager\n", encoding="utf-8")
        (app_dir / "service_backend").write_text("systemd\n", encoding="utf-8")
        with mock.patch.dict("os.environ", {"ALIYUN_GUARD_CONTAINER": "0"}), mock.patch.object(
            web_actions, "APP_DIR", app_dir
        ), mock.patch.object(web_actions.shutil, "which", return_value=None):
            with self.assertRaises(web_actions.ManagementError) as raised:
                web_actions.install_update()
        self.assertIn("aliyun-guard update", str(raised.exception))

    def test_non_systemd_update_keeps_detached_process_fallback(self):
        app_dir = Path(self.temp.name) / "app"
        app_dir.mkdir()
        manager_path = app_dir / "manager.py"
        manager_path.write_text("# manager\n", encoding="utf-8")
        (app_dir / "service_backend").write_text("openrc\n", encoding="utf-8")
        with mock.patch.dict("os.environ", {"ALIYUN_GUARD_CONTAINER": "0"}), mock.patch.object(
            web_actions, "APP_DIR", app_dir
        ), mock.patch.object(
            web_actions, "detached_process", return_value=77
        ) as detached:
            self.assertEqual(web_actions.install_update(), 77)
        command, log_name = detached.call_args.args
        self.assertEqual(command[:2], ["/bin/sh", "-c"])
        self.assertIn(web_actions.UPDATE_EXIT_MARKER, command[2])
        self.assertIn(sys.executable, command)
        self.assertIn("-u", command)
        self.assertIn(str(manager_path), command)
        self.assertEqual(log_name, web_actions.UPDATE_LOG_NAME)

    def test_update_progress_tracks_installer_stages_and_success(self):
        app_dir = Path(self.temp.name) / "app"
        with mock.patch.object(web_actions, "APP_DIR", app_dir):
            web_actions._prepare_update_tracking("1.5.4", "systemd")
            log_path = app_dir / "logs" / web_actions.UPDATE_LOG_NAME
            with log_path.open("a", encoding="utf-8") as handle:
                handle.write("正在下载更新和校验文件...\n")
                handle.write("SHA-256 校验通过\n")
                handle.write("[3/6] 写入程序文件...\n")
            running = web_actions.update_progress()
            self.assertEqual(running["status"], "running")
            self.assertEqual(running["progress"], 62)
            self.assertEqual(running["target_version"], "1.5.4")
            with log_path.open("a", encoding="utf-8") as handle:
                handle.write("GitHub 最新版本已安装，后台服务已重启。\n")
                handle.write(web_actions.UPDATE_EXIT_MARKER + "0\n")
            complete = web_actions.update_progress()
        self.assertEqual(complete["status"], "success")
        self.assertEqual(complete["progress"], 100)

    def test_update_progress_reports_nonzero_exit(self):
        app_dir = Path(self.temp.name) / "app"
        with mock.patch.object(web_actions, "APP_DIR", app_dir):
            web_actions._prepare_update_tracking("1.5.4", "systemd")
            log_path = app_dir / "logs" / web_actions.UPDATE_LOG_NAME
            with log_path.open("a", encoding="utf-8") as handle:
                handle.write("[2/6] 创建 Python 独立环境...\n")
                handle.write(web_actions.UPDATE_EXIT_MARKER + "2\n")
            result = web_actions.update_progress()
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["progress"], 48)

    def test_second_web_update_is_rejected_while_job_is_running(self):
        app_dir = Path(self.temp.name) / "app"
        app_dir.mkdir()
        (app_dir / "manager.py").write_text("# manager\n", encoding="utf-8")
        (app_dir / "service_backend").write_text("systemd\n", encoding="utf-8")
        with mock.patch.object(web_actions, "APP_DIR", app_dir):
            web_actions._prepare_update_tracking("1.5.4", "systemd")
            with self.assertRaises(web_actions.ManagementError) as raised:
                web_actions.install_update("1.5.4")
        self.assertEqual(raised.exception.status, 409)
        self.assertIn("正在运行", str(raised.exception))

    def test_update_check_identifies_container_deployment(self):
        with mock.patch.dict("os.environ", {"ALIYUN_GUARD_CONTAINER": "1"}), mock.patch(
            "manager.check_for_github_update", return_value=None
        ):
            result = web_actions.check_update()
        self.assertEqual(result["deployment"], "docker")


if __name__ == "__main__":
    unittest.main()
