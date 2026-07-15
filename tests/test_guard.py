import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import aliyun_guard as guard
import manager


def make_user(**overrides):
    user = {
        "name": "HK",
        "ak": "test-ak",
        "sk": "test-sk",
        "region": "cn-hongkong",
        "instance_id": "i-test123",
        "traffic_limit_gb": 180,
        "actions_enabled": True,
        "paused": False,
        "billing": {
            "enabled": False,
            "site": "china",
            "endpoint": "business.aliyuncs.com",
            "region": "cn-hangzhou",
            "currency_code": "CNY",
            "currency_symbol": "¥",
        },
    }
    user.update(overrides)
    return user


def make_config(user=None):
    config = json.loads(json.dumps(guard.DEFAULT_CONFIG))
    config["users"] = [user or make_user()]
    config["telegram"] = {"bot_token": "test-token", "chat_id": "123", "timeout_seconds": 5}
    return config


class GuardDecisionTests(unittest.TestCase):
    def test_safe_running_needs_no_action(self):
        with mock.patch.object(guard, "query_cdt_traffic_gb", return_value=46.22), mock.patch.object(
            guard, "query_instance_status", return_value="Running"
        ):
            result = guard.check_one(make_user(), make_config())
        self.assertEqual(result["level"], "ok")
        self.assertEqual(result["action"], "none")
        self.assertIn("运行正常", result["message"])

    def test_safe_stopped_starts_and_confirms(self):
        with mock.patch.object(guard, "query_cdt_traffic_gb", return_value=10.0), mock.patch.object(
            guard, "query_instance_status", return_value="Stopped"
        ), mock.patch.object(guard, "start_instance") as start, mock.patch.object(
            guard, "wait_for_status", return_value=("Running", None)
        ):
            result = guard.check_one(make_user(), make_config())
        start.assert_called_once()
        self.assertEqual(result["action"], "start")
        self.assertEqual(result["status_after"], "Running")
        self.assertEqual(result["level"], "action")

    def test_over_limit_running_stops(self):
        with mock.patch.object(guard, "query_cdt_traffic_gb", return_value=180.0), mock.patch.object(
            guard, "query_instance_status", return_value="Running"
        ), mock.patch.object(guard, "stop_instance") as stop, mock.patch.object(
            guard, "wait_for_status", return_value=("Stopped", None)
        ):
            result = guard.check_one(make_user(), make_config())
        stop.assert_called_once()
        self.assertEqual(result["action"], "stop")
        self.assertEqual(result["level"], "action")
        self.assertEqual(result["status_after"], "Stopped")

    def test_dry_run_never_calls_stop(self):
        with mock.patch.object(guard, "query_cdt_traffic_gb", return_value=200.0), mock.patch.object(
            guard, "query_instance_status", return_value="Running"
        ), mock.patch.object(guard, "stop_instance") as stop:
            result = guard.check_one(make_user(), make_config(), dry_run=True)
        stop.assert_not_called()
        self.assertIn("演练", result["message"])

    def test_cdt_error_is_attributed(self):
        with mock.patch.object(guard, "query_cdt_traffic_gb", side_effect=RuntimeError("bad key")), mock.patch.object(
            guard, "query_instance_status", return_value="Running"
        ):
            result = guard.check_one(make_user(), make_config())
        self.assertEqual(result["level"], "error")
        self.assertTrue(any("CDT 流量查询失败" in error for error in result["errors"]))
        self.assertEqual(result["status_before"], "Running")

    def test_bill_error_does_not_block_keepalive_action(self):
        billing = dict(guard.DEFAULT_BILLING)
        with mock.patch.object(guard, "query_cdt_traffic_gb", return_value=10.0), mock.patch.object(
            guard, "query_instance_status", return_value="Stopped"
        ), mock.patch.object(
            guard, "query_instance_bill", side_effect=RuntimeError("NoPermission")
        ), mock.patch.object(guard, "start_instance") as start, mock.patch.object(
            guard, "wait_for_status", return_value=("Running", None)
        ):
            result = guard.check_one(make_user(billing=billing), make_config())
        start.assert_called_once()
        self.assertTrue(result["action_performed"])
        self.assertEqual(result["status_after"], "Running")
        self.assertEqual(result["level"], "error")
        self.assertIn("BSS 账单查询失败", result["bill_error"])

    def test_bill_success_is_recorded(self):
        billing = dict(guard.DEFAULT_BILLING)
        with mock.patch.object(guard, "query_cdt_traffic_gb", return_value=10.0), mock.patch.object(
            guard, "query_instance_status", return_value="Running"
        ), mock.patch.object(guard, "query_instance_bill", return_value=(12.34, "CNY")):
            result = guard.check_one(make_user(billing=billing), make_config())
        self.assertEqual(result["bill_amount"], 12.34)
        self.assertEqual(result["bill_currency"], "CNY")
        self.assertEqual(result["level"], "ok")

    def test_paused_user_makes_no_api_calls(self):
        with mock.patch.object(guard, "query_cdt_traffic_gb") as traffic, mock.patch.object(
            guard, "query_instance_status"
        ) as status:
            result = guard.check_one(make_user(paused=True), make_config())
        traffic.assert_not_called()
        status.assert_not_called()
        self.assertEqual(result["level"], "paused")


class GuardNotificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_state = guard.STATE_FILE
        self.old_lock = guard.LOCK_FILE
        guard.STATE_FILE = Path(self.temp.name) / "state.json"
        guard.LOCK_FILE = Path(self.temp.name) / "cycle.lock"

    def tearDown(self):
        guard.STATE_FILE = self.old_state
        guard.LOCK_FILE = self.old_lock
        self.temp.cleanup()

    def test_always_mode_sends_each_cycle_summary(self):
        config = make_config()
        result = {
            "name": "HK",
            "instance_id": "i-test123",
            "traffic_gb": 46.22,
            "limit_gb": 180.0,
            "status_before": "Running",
            "status_after": "Running",
            "action": "none",
            "level": "ok",
            "message": "流量安全，实例运行正常",
            "errors": [],
            "paused": False,
        }
        with mock.patch.object(guard, "load_config", return_value=config), mock.patch.object(
            guard, "check_one", return_value=result
        ), mock.patch.object(guard, "send_telegram_message") as send:
            code = guard.run_cycle()
        self.assertEqual(code, 0)
        send.assert_called_once()
        message = send.call_args.args[1]
        self.assertIn("阿里云保活检测完成", message)
        self.assertIn("46.22 / 180.00 GB", message)
        state = json.loads(guard.STATE_FILE.read_text(encoding="utf-8"))
        self.assertTrue(state["last_cycle_ok"])
        self.assertEqual(state["cycle_count"], 1)

    def test_errors_mode_skips_healthy_cycle(self):
        config = make_config()
        config["notification_mode"] = "errors"
        healthy = {
            "name": "HK",
            "instance_id": "i-test123",
            "traffic_gb": 1.0,
            "limit_gb": 180.0,
            "status_before": "Running",
            "status_after": "Running",
            "action": "none",
            "level": "ok",
            "message": "正常",
            "errors": [],
            "paused": False,
        }
        with mock.patch.object(guard, "load_config", return_value=config), mock.patch.object(
            guard, "check_one", return_value=healthy
        ), mock.patch.object(guard, "send_telegram_message") as send:
            guard.run_cycle()
        send.assert_not_called()

    def test_telegram_retries_transient_network_error(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b'{"ok": true, "result": {"id": 1}}'
        with mock.patch.object(
            guard.urllib.request,
            "urlopen",
            side_effect=[urllib.error.URLError("temporary"), response],
        ) as urlopen, mock.patch.object(guard.time, "sleep"):
            result = guard.telegram_api(
                {"bot_token": "token", "timeout_seconds": 3, "retries": 3}, "getMe"
            )
        self.assertEqual(result["id"], 1)
        self.assertEqual(urlopen.call_count, 2)


class ConfigTests(unittest.TestCase):
    def test_bss_query_uses_selected_endpoint_and_parses_amount(self):
        class FakeRequest:
            def __init__(self):
                self.domain = None
                self.params = {}

            def set_protocol_type(self, value):
                pass

            def set_accept_format(self, value):
                pass

            def set_method(self, value):
                pass

            def set_domain(self, value):
                self.domain = value

            def set_version(self, value):
                pass

            def set_action_name(self, value):
                self.action = value

            def set_connect_timeout(self, value):
                pass

            def set_read_timeout(self, value):
                pass

            def add_query_param(self, key, value):
                self.params[key] = value

        request_holder = {}

        class FakeClient:
            def do_action_with_exception(self, request):
                request_holder["request"] = request
                return json.dumps(
                    {
                        "Success": True,
                        "Data": {
                            "Items": {
                                "Item": [
                                    {"PretaxAmount": "1.20", "Currency": "USD"},
                                    {"PretaxAmount": "2.30", "Currency": "USD"},
                                ]
                            }
                        },
                    }
                ).encode("utf-8")

        billing = {
            "enabled": True,
            "site": "international",
            "endpoint": "business.ap-southeast-1.aliyuncs.com",
            "region": "ap-southeast-1",
            "currency_code": "USD",
            "currency_symbol": "$",
        }
        with mock.patch.object(guard, "SDK_IMPORT_ERROR", None), mock.patch.object(
            guard, "CommonRequest", FakeRequest
        ), mock.patch.object(guard, "make_client", return_value=FakeClient()):
            amount, currency = guard.query_instance_bill(make_user(billing=billing))
        self.assertAlmostEqual(amount, 3.50)
        self.assertEqual(currency, "USD")
        request = request_holder["request"]
        self.assertEqual(request.domain, "business.ap-southeast-1.aliyuncs.com")
        self.assertEqual(request.action, "DescribeInstanceBill")
        self.assertEqual(request.params["InstanceID"], "i-test123")

    def test_normalizes_bss_item_shapes(self):
        wrapped = {"Data": {"Items": {"Item": [{"PretaxAmount": "1.20"}]}}}
        direct = {"Data": {"Items": [{"PretaxAmount": "2.30"}]}}
        self.assertEqual(len(guard.normalize_bill_items(wrapped)), 1)
        self.assertEqual(len(guard.normalize_bill_items(direct)), 1)

    def test_error_text_redacts_credentials(self):
        text = guard.compact_error(
            RuntimeError("request failed for test-ak with test-sk"),
            secrets=("test-ak", "test-sk"),
        )
        self.assertNotIn("test-ak", text)
        self.assertNotIn("test-sk", text)
        self.assertIn("***", text)

    def test_rejects_duplicate_instance(self):
        config = make_config()
        config["users"].append(dict(config["users"][0]))
        with self.assertRaises(guard.GuardError):
            guard.validate_config(config)

    def test_rejects_interval_below_one_minute(self):
        config = make_config()
        config["interval_seconds"] = 30
        with self.assertRaises(guard.GuardError):
            guard.validate_config(config)

    def test_summary_has_source_specific_error(self):
        result = {
            "name": "HK",
            "instance_id": "i-test123",
            "traffic_gb": None,
            "limit_gb": 180,
            "status_before": "Running",
            "status_after": "Running",
            "action": "none",
            "level": "error",
            "message": "CDT 流量查询失败: InvalidAccessKeyId.NotFound",
            "errors": ["CDT 流量查询失败: InvalidAccessKeyId.NotFound"],
            "paused": False,
        }
        summary, errors, _actions, _warnings = guard.build_summary(
            [result], dt.datetime.now().astimezone(), 0.5
        )
        self.assertEqual(errors, 1)
        self.assertIn("CDT 流量查询失败", summary)

    def test_summary_includes_bill_amount_and_bss_error(self):
        base = {
            "name": "HK",
            "instance_id": "i-test123",
            "traffic_gb": 10.0,
            "limit_gb": 180.0,
            "status_before": "Running",
            "status_after": "Running",
            "action": "none",
            "action_performed": False,
            "level": "ok",
            "message": "流量安全，实例运行正常",
            "errors": [],
            "paused": False,
            "billing_enabled": True,
            "bill_amount": 12.34,
            "bill_currency": "CNY",
            "bill_symbol": "¥",
            "bill_error": None,
        }
        summary, errors, _actions, _warnings = guard.build_summary(
            [base], dt.datetime.now().astimezone(), 0.5
        )
        self.assertEqual(errors, 0)
        self.assertIn("账单: ¥12.34 (CNY)", summary)
        failed = dict(base)
        failed["level"] = "error"
        failed["bill_amount"] = None
        failed["bill_error"] = "BSS 账单查询失败: NoPermission"
        failed["errors"] = [failed["bill_error"]]
        summary, errors, _actions, _warnings = guard.build_summary(
            [failed], dt.datetime.now().astimezone(), 0.5
        )
        self.assertEqual(errors, 1)
        self.assertIn("账单: 查询失败", summary)
        self.assertIn("错误: BSS 账单查询失败: NoPermission", summary)


class UpdateTests(unittest.TestCase):
    def test_github_update_verifies_checksum_and_runs_update_mode(self):
        installer = b"#!/bin/sh\nexit 0\n"
        checksum = hashlib.sha256(installer).hexdigest().encode("ascii") + b"  install.sh\n"
        with mock.patch.object(
            manager, "download_update_file", side_effect=[installer, checksum]
        ), mock.patch.object(manager.subprocess, "call", return_value=0) as run:
            result = manager.update_from_github(confirm_update=False)
        self.assertTrue(result)
        command = run.call_args.args[0]
        self.assertEqual(command[0], "/bin/sh")
        self.assertEqual(command[-1], "--update")

    def test_github_update_rejects_checksum_mismatch(self):
        installer = b"#!/bin/sh\nexit 0\n"
        bad_checksum = ("0" * 64 + "  install.sh\n").encode("ascii")
        with mock.patch.object(
            manager, "download_update_file", side_effect=[installer, bad_checksum]
        ), mock.patch.object(manager.subprocess, "call") as run:
            result = manager.update_from_github(confirm_update=False)
        self.assertFalse(result)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
