import datetime as dt
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


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
        response.status_code = 200
        response.text = '{"ok": true, "result": {"id": 1}}'
        with mock.patch.object(
            guard, "_telegram_post", side_effect=[OSError("temporary"), response]
        ) as post, mock.patch.object(guard.time, "sleep"):
            result = guard.telegram_api(
                {"bot_token": "token", "timeout_seconds": 3, "retries": 3}, "getMe"
            )
        self.assertEqual(result["id"], 1)
        self.assertEqual(post.call_count, 2)

    def test_telegram_uses_socks5_proxy(self):
        response = mock.MagicMock(status_code=200)
        response.text = '{"ok": true, "result": {"id": 1}}'
        telegram = {
            "bot_token": "token",
            "timeout_seconds": 5,
            "retries": 1,
            "connection_mode": "socks5",
            "proxy_url": "socks5h://user:secret@127.0.0.1:1080",
        }
        with mock.patch.object(guard, "_telegram_post", return_value=response) as post:
            guard.telegram_api(telegram, "getMe")
        self.assertEqual(
            post.call_args.args[3],
            {
                "http": "socks5h://user:secret@127.0.0.1:1080",
                "https": "socks5h://user:secret@127.0.0.1:1080",
            },
        )

    def test_telegram_uses_http_proxy(self):
        response = mock.MagicMock(status_code=200)
        response.text = '{"ok": true, "result": {"id": 1}}'
        telegram = {
            "bot_token": "token",
            "timeout_seconds": 5,
            "retries": 1,
            "connection_mode": "http",
            "proxy_url": "http://127.0.0.1:8080",
        }
        with mock.patch.object(guard, "_telegram_post", return_value=response) as post:
            guard.telegram_api(telegram, "getMe")
        self.assertEqual(post.call_args.args[3]["https"], "http://127.0.0.1:8080")

    def test_non_node_connection_stops_existing_node_proxy(self):
        with mock.patch.object(guard.telegram_proxy, "stop_node_proxy") as stop:
            base_url, proxies = guard.telegram_connection(
                {"connection_mode": "direct"}
            )
        stop.assert_called_once_with()
        self.assertEqual(base_url, "https://api.telegram.org")
        self.assertIsNone(proxies)

    def test_telegram_uses_api_reverse_proxy(self):
        response = mock.MagicMock(status_code=200)
        response.text = '{"ok": true, "result": {"id": 1}}'
        telegram = {
            "bot_token": "token",
            "timeout_seconds": 5,
            "retries": 1,
            "connection_mode": "api_proxy",
            "api_base_url": "https://telegram.example.com",
        }
        with mock.patch.object(guard, "_telegram_post", return_value=response) as post:
            guard.telegram_api(telegram, "getMe")
        self.assertEqual(post.call_args.args[0], "https://telegram.example.com/bottoken/getMe")
        self.assertIsNone(post.call_args.args[3])

    def test_telegram_uses_node_proxy(self):
        response = mock.MagicMock(status_code=200)
        response.text = '{"ok": true, "result": {"id": 1}}'
        telegram = {
            "bot_token": "token",
            "timeout_seconds": 5,
            "retries": 1,
            "connection_mode": "node",
            "node_url": "vless://test-uuid@example.com:443?security=tls",
        }
        with mock.patch.object(
            guard.telegram_proxy,
            "ensure_node_proxy",
            return_value="socks5h://127.0.0.1:19001",
        ) as ensure, mock.patch.object(guard, "_telegram_post", return_value=response) as post:
            guard.telegram_api(telegram, "getMe")
        ensure.assert_called_once_with(telegram["node_url"])
        self.assertEqual(post.call_args.args[3]["https"], "socks5h://127.0.0.1:19001")

    def test_telegram_latency_samples_and_message_use_node_proxy(self):
        response = mock.MagicMock(status_code=200)
        response.text = '{"ok": true, "result": {"username": "test_bot"}}'
        telegram = {
            "bot_token": "token",
            "chat_id": "123",
            "timeout_seconds": 5,
            "retries": 1,
            "connection_mode": "node",
            "node_url": (
                "vless://11111111-1111-1111-1111-111111111111@example.com:443"
                "?security=tls#Hong%20Kong%2001"
            ),
        }
        with mock.patch.object(
            guard.telegram_proxy,
            "ensure_node_proxy",
            return_value="socks5h://127.0.0.1:19001",
        ) as ensure, mock.patch.object(
            guard, "_telegram_post", return_value=response
        ) as post, mock.patch.object(
            guard.time,
            "perf_counter",
            side_effect=[1.0, 1.020, 2.0, 2.030, 3.0, 3.040],
        ):
            guard.test_telegram(telegram, latency_attempts=3)
        self.assertEqual(ensure.call_count, 5)
        self.assertEqual(post.call_count, 5)
        self.assertTrue(all(call.args[3]["https"] == "socks5h://127.0.0.1:19001" for call in post.call_args_list))
        self.assertTrue(all(call.args[0].endswith("/getMe") for call in post.call_args_list[:4]))
        self.assertTrue(post.call_args_list[4].args[0].endswith("/sendMessage"))

    def test_proxy_notification_identifies_endpoint_without_credentials(self):
        telegram = {
            "chat_id": "123",
            "connection_mode": "socks5",
            "proxy_url": "socks5h://user:secret@proxy.example.com:1080",
        }
        with mock.patch.object(guard, "telegram_api", return_value={}) as api:
            guard.send_telegram_message(telegram, "保活检测完成")
        message = api.call_args.args[2]["text"]
        self.assertIn("Telegram 连接：SOCKS5 代理（proxy.example.com:1080）", message)
        self.assertNotIn("user", message)
        self.assertNotIn("secret", message)

    def test_node_notification_identifies_remark_without_node_secret(self):
        node_uuid = "11111111-1111-1111-1111-111111111111"
        telegram = {
            "chat_id": "123",
            "connection_mode": "node",
            "node_url": (
                "vless://{}@example.com:443?security=tls#Hong%20Kong%2001".format(
                    node_uuid
                )
            ),
        }
        with mock.patch.object(guard, "telegram_api", return_value={}) as api:
            guard.send_telegram_message(telegram, "保活检测完成")
        message = api.call_args.args[2]["text"]
        self.assertIn("Telegram 连接：VLESS 节点（Hong Kong 01）", message)
        self.assertNotIn(node_uuid, message)
        self.assertNotIn("vless://", message)

    def test_direct_notification_has_no_connection_suffix(self):
        telegram = {"chat_id": "123", "connection_mode": "direct"}
        with mock.patch.object(guard, "telegram_api", return_value={}) as api:
            guard.send_telegram_message(telegram, "保活检测完成")
        self.assertEqual(api.call_args.args[2]["text"], "保活检测完成")

    def test_telegram_test_message_includes_average_api_latency(self):
        telegram = {"chat_id": "123", "connection_mode": "node"}
        details = {}
        with mock.patch.object(
            guard, "telegram_api", return_value={"username": "test_bot"}
        ) as api, mock.patch.object(
            guard.time,
            "perf_counter",
            side_effect=[1.0, 1.042, 2.0, 2.042, 3.0, 3.042],
        ), mock.patch.object(guard, "send_telegram_message") as send:
            username = guard.test_telegram(
                telegram,
                latency_attempts=3,
                result_details=details,
            )
        self.assertEqual(username, "test_bot")
        self.assertEqual(api.call_count, 4)
        self.assertAlmostEqual(details["latency_ms"], 42.0)
        self.assertEqual(details["latency_attempts"], 3)
        self.assertIn("Telegram 往返延迟: 42 ms（3 次平均）", send.call_args.args[1])

    def test_node_proxy_start_error_redacts_node_credentials(self):
        node_uuid = "11111111-1111-1111-1111-111111111111"
        node_url = "vless://{}@example.com:443?security=tls".format(node_uuid)
        telegram = {
            "connection_mode": "node",
            "node_url": node_url,
        }
        with mock.patch.object(
            guard.telegram_proxy,
            "ensure_node_proxy",
            side_effect=guard.telegram_proxy.ProxyError(
                "sing-box failed for {} using {}".format(node_uuid, node_url)
            ),
        ):
            with self.assertRaises(guard.GuardError) as raised:
                guard.telegram_connection(telegram)
        message = str(raised.exception)
        self.assertNotIn(node_uuid, message)
        self.assertNotIn(node_url, message)
        self.assertIn("***", message)

    def test_api_reverse_proxy_error_redacts_base_url(self):
        base_url = "https://user:secret@telegram.example.com/private"
        text = guard.compact_error(
            RuntimeError("request failed for {}".format(base_url)),
            secrets=guard.telegram_secrets({"api_base_url": base_url}),
        )
        self.assertNotIn(base_url, text)
        self.assertNotIn("secret", text)

    def test_dormant_saved_node_is_redacted_from_errors(self):
        node_uuid = "11111111-1111-1111-1111-111111111111"
        node_url = "vless://{}@example.com:443?security=tls#Saved".format(node_uuid)
        text = guard.compact_error(
            RuntimeError("request failed for {}".format(node_url)),
            secrets=guard.telegram_secrets({"node_urls": [node_url]}),
        )
        self.assertNotIn(node_url, text)
        self.assertNotIn(node_uuid, text)


class ConfigTests(unittest.TestCase):
    def test_load_config_migrates_legacy_node_url_to_saved_nodes(self):
        node_url = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#Legacy"
        )
        config = make_config()
        config["telegram"].update({"connection_mode": "direct", "node_url": node_url})
        config["telegram"].pop("node_urls", None)
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            with mock.patch.object(guard, "CONFIG_FILE", config_path):
                loaded = guard.load_config()
        self.assertEqual(loaded["telegram"]["node_url"], node_url)
        self.assertEqual(loaded["telegram"]["node_urls"], [node_url])

    def test_rejects_invalid_telegram_proxy(self):
        config = make_config()
        config["telegram"].update(
            {"connection_mode": "socks5", "proxy_url": "socks5h://127.0.0.1"}
        )
        with self.assertRaises(guard.GuardError):
            guard.validate_config(config)

    def test_rejects_insecure_remote_api_proxy(self):
        config = make_config()
        config["telegram"].update(
            {"connection_mode": "api_proxy", "api_base_url": "http://proxy.example.com"}
        )
        with self.assertRaises(guard.GuardError):
            guard.validate_config(config)

    def test_rejects_api_proxy_query_string(self):
        config = make_config()
        config["telegram"].update(
            {
                "connection_mode": "api_proxy",
                "api_base_url": "https://proxy.example.com/?token=secret",
            }
        )
        with self.assertRaises(guard.GuardError):
            guard.validate_config(config)

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
    def test_current_release_returns_without_downloading(self):
        release_info = {
            "available": False,
            "version": manager.APP_VERSION,
            "release_id": "a" * 64,
        }
        output = io.StringIO()
        with mock.patch.object(manager, "download_update_file") as download, mock.patch.object(
            manager, "yes_no"
        ) as confirm, mock.patch("sys.stdout", output):
            result = manager.update_from_github(release_info=release_info)
        self.assertIsNone(result)
        self.assertIn("当前版本: v{}".format(manager.APP_VERSION), output.getvalue())
        self.assertIn("当前版本已经是最新版本了。", output.getvalue())
        download.assert_not_called()
        confirm.assert_not_called()

    def test_update_confirmation_names_target_version(self):
        release_info = {"available": True, "version": "1.3.0", "release_id": "b" * 64}
        with mock.patch.object(manager, "yes_no", return_value=False) as confirm:
            result = manager.update_from_github(release_info=release_info)
        self.assertIsNone(result)
        confirm.assert_called_once_with("下载并安装 GitHub v1.3.0", True)

    def test_startup_check_reports_remote_version(self):
        local_release = "a" * 64
        remote_release = "b" * 64
        manifest = json.dumps(
            {"version": "1.3.0", "release_id": remote_release}
        ).encode("utf-8")
        with mock.patch.object(manager, "LOCAL_RELEASE_ID", local_release), mock.patch.object(
            manager, "download_update_file", return_value=manifest
        ) as download:
            result = manager.check_for_github_update()
        self.assertTrue(result["available"])
        self.assertEqual(result["version"], "1.3.0")
        download.assert_called_once_with(
            manager.UPDATE_BASE_URL + "/version.json",
            timeout=manager.UPDATE_CHECK_TIMEOUT_SECONDS,
            retries=1,
        )

    def test_startup_check_recognizes_current_release(self):
        release_id = "a" * 64
        manifest = json.dumps(
            {"version": manager.APP_VERSION, "release_id": release_id}
        ).encode("utf-8")
        with mock.patch.object(manager, "LOCAL_RELEASE_ID", release_id), mock.patch.object(
            manager, "download_update_file", return_value=manifest
        ):
            result = manager.check_for_github_update()
        self.assertFalse(result["available"])

    def test_startup_check_failure_does_not_block_menu(self):
        with mock.patch.object(manager, "LOCAL_RELEASE_ID", "a" * 64), mock.patch.object(
            manager, "download_update_file", side_effect=OSError("offline")
        ):
            self.assertIsNone(manager.check_for_github_update())

    def test_github_update_verifies_checksum_and_runs_update_mode(self):
        installer = b"#!/bin/sh\nexit 0\n"
        checksum = hashlib.sha256(installer).hexdigest().encode("ascii") + b"  install.sh\n"
        release_info = {"available": True, "version": "1.3.0", "release_id": "b" * 64}
        output = io.StringIO()
        with mock.patch.object(
            manager, "download_update_file", side_effect=[installer, checksum]
        ), mock.patch.object(manager.subprocess, "call", return_value=0) as run:
            with mock.patch("sys.stdout", output):
                result = manager.update_from_github(
                    confirm_update=False,
                    release_info=release_info,
                )
        self.assertTrue(result)
        self.assertIn("当前版本: v{}".format(manager.APP_VERSION), output.getvalue())
        self.assertIn("最新版本: v1.3.0", output.getvalue())
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


class InstallerTemplateTests(unittest.TestCase):
    def test_update_preserves_telegram_node_configuration(self):
        template = (ROOT / "packaging" / "install.template.sh").read_text(
            encoding="utf-8"
        )
        main = template[template.rfind("\ndetect_os\n"):]
        self.assertLess(main.index("preserve_local_data"), main.index("write_payload"))
        self.assertLess(main.index("write_payload"), main.index("restore_local_data"))
        self.assertIn('cp "$APP_DIR/config.json" "$PRESERVE_DIR/config.json"', template)
        self.assertIn('"$APP_DIR/bin/sing-box"', template)
        self.assertIn("Telegram 代理和节点保持不变", template)


class FirstSetupFlowTests(unittest.TestCase):
    def test_node_connection_is_tested_before_commit(self):
        candidate = dict(guard.DEFAULT_CONFIG["telegram"])
        node_url = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls&type=ws&path=%2Ftelegram"
        )
        with mock.patch.object(manager, "prompt_int", side_effect=[4, 8]), mock.patch.object(
            manager, "prompt_secret", return_value=node_url
        ), mock.patch.object(
            manager.telegram_proxy, "find_sing_box", return_value="/usr/bin/sing-box"
        ), mock.patch.object(
            manager.guard,
            "test_telegram",
            side_effect=lambda telegram, latency_attempts, result_details: (
                result_details.update({"latency_ms": 42.4, "latency_attempts": 3})
                or "test_bot"
            ),
        ) as test:
            result, test_ok = manager.configure_telegram_connection(
                candidate, force_ipv4=False
            )
        self.assertTrue(test_ok)
        self.assertEqual(result["connection_mode"], "node")
        self.assertEqual(result["node_url"], node_url)
        self.assertEqual(result["node_urls"], [node_url])
        test.assert_called_once_with(result, latency_attempts=3, result_details=mock.ANY)

    def test_connection_menu_cancel_returns_without_save(self):
        candidate = dict(guard.DEFAULT_CONFIG["telegram"])
        with mock.patch.object(manager, "prompt_int", return_value=7):
            self.assertIsNone(
                manager.configure_telegram_connection(candidate, force_ipv4=False)
            )

    def test_connection_menu_shows_current_node(self):
        node_url = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#Hong%20Kong%2001"
        )
        candidate = dict(guard.DEFAULT_CONFIG["telegram"])
        candidate.update({"connection_mode": "node", "node_url": node_url})
        output = io.StringIO()
        with mock.patch.object(manager, "prompt_int", return_value=7), mock.patch(
            "sys.stdout", output
        ):
            manager.configure_telegram_connection(candidate, force_ipv4=False)
        self.assertIn(
            "当前方式: 节点链接（VLESS / VMess / Shadowsocks）",
            output.getvalue(),
        )
        self.assertIn("当前节点: VLESS 节点（Hong Kong 01）", output.getvalue())

    def test_connection_menu_shows_legacy_saved_node_count_while_direct(self):
        node_url = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#Hong%20Kong%2001"
        )
        candidate = dict(guard.DEFAULT_CONFIG["telegram"])
        candidate.update(
            {"connection_mode": "direct", "node_url": node_url, "node_urls": []}
        )
        output = io.StringIO()
        with mock.patch.object(manager, "prompt_int", return_value=7), mock.patch(
            "sys.stdout", output
        ):
            manager.configure_telegram_connection(candidate, force_ipv4=False)
        self.assertIn("[已保存 1 个]", output.getvalue())

    def test_saved_node_menu_recovers_and_selects_legacy_node(self):
        node_url = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#Hong%20Kong%2001"
        )
        telegram = dict(guard.DEFAULT_CONFIG["telegram"])
        telegram.update(
            {"connection_mode": "direct", "node_url": node_url, "node_urls": []}
        )
        output = io.StringIO()
        with mock.patch.object(manager, "prompt_int", return_value=1), mock.patch(
            "sys.stdout", output
        ):
            selected = manager.configure_telegram_nodes(telegram)
        self.assertTrue(selected)
        self.assertEqual(telegram["connection_mode"], "node")
        self.assertEqual(telegram["node_url"], node_url)
        self.assertEqual(telegram["node_urls"], [node_url])
        self.assertIn("VLESS 节点（Hong Kong 01）", output.getvalue())
        self.assertIn("（上次使用）", output.getvalue())

    def test_saved_node_menu_adds_a_second_node(self):
        first = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#First"
        )
        second = "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@ss.example.com:8388#Second"
        telegram = dict(guard.DEFAULT_CONFIG["telegram"])
        telegram.update(
            {"connection_mode": "direct", "node_url": first, "node_urls": [first]}
        )
        with mock.patch.object(manager, "prompt_int", return_value=2), mock.patch.object(
            manager, "prompt_secret", return_value=second
        ):
            selected = manager.configure_telegram_nodes(telegram)
        self.assertTrue(selected)
        self.assertEqual(telegram["connection_mode"], "node")
        self.assertEqual(telegram["node_url"], second)
        self.assertEqual(telegram["node_urls"], [first, second])

    def test_adding_duplicate_node_does_not_increase_count(self):
        node_url = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#Existing"
        )
        telegram = dict(guard.DEFAULT_CONFIG["telegram"])
        telegram.update(
            {"connection_mode": "direct", "node_url": node_url, "node_urls": [node_url]}
        )
        with mock.patch.object(manager, "prompt_secret", return_value=node_url):
            selected = manager.add_telegram_node(telegram)
        self.assertTrue(selected)
        self.assertEqual(telegram["node_urls"], [node_url])
        self.assertEqual(telegram["node_url"], node_url)

    def test_deleting_active_node_selects_remaining_node(self):
        first = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#First"
        )
        second = "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@ss.example.com:8388#Second"
        telegram = dict(guard.DEFAULT_CONFIG["telegram"])
        telegram.update(
            {"connection_mode": "node", "node_url": first, "node_urls": [first, second]}
        )
        with mock.patch.object(manager, "prompt_int", return_value=1), mock.patch.object(
            manager, "yes_no", return_value=True
        ):
            deleted = manager.delete_telegram_node(telegram, [first, second])
        self.assertTrue(deleted)
        self.assertEqual(telegram["connection_mode"], "node")
        self.assertEqual(telegram["node_url"], second)
        self.assertEqual(telegram["node_urls"], [second])

    def test_standalone_connection_cancel_keeps_config(self):
        config = make_config()
        original = json.loads(json.dumps(config["telegram"]))
        with mock.patch.object(
            manager, "configure_telegram_connection", return_value=None
        ):
            result = manager.configure_telegram_connection_settings(config)
        self.assertIsNone(result)
        self.assertEqual(config["telegram"], original)

    def test_current_node_connection_reports_telegram_api_latency(self):
        telegram = dict(guard.DEFAULT_CONFIG["telegram"])
        telegram.update(
            {
                "connection_mode": "node",
                "node_url": (
                    "vless://11111111-1111-1111-1111-111111111111@example.com:443"
                    "?security=tls"
                ),
            }
        )
        output = io.StringIO()
        with mock.patch.object(
            manager.guard,
            "test_telegram",
            side_effect=lambda selected, latency_attempts, result_details: (
                result_details.update({"latency_ms": 88.6, "latency_attempts": 3})
                or "test_bot"
            ),
        ) as test, mock.patch("sys.stdout", output):
            result = manager.test_current_telegram(
                {"telegram": telegram, "force_ipv4": False}
            )
        self.assertTrue(result)
        test.assert_called_once_with(telegram, latency_attempts=3, result_details=mock.ANY)
        self.assertIn("本次测试方式: 节点链接", output.getvalue())
        self.assertIn("Telegram 往返延迟: 89 ms（3 次平均）", output.getvalue())

    def test_switching_node_to_direct_preserves_node_and_requires_confirmation(self):
        node_url = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#Hong%20Kong%2001"
        )
        active = dict(guard.DEFAULT_CONFIG["telegram"])
        active.update({"connection_mode": "node", "node_url": node_url})
        candidate = dict(active)
        output = io.StringIO()
        with mock.patch.object(manager, "prompt_int", side_effect=[1, 8]), mock.patch.object(
            manager, "yes_no", return_value=True
        ) as confirm, mock.patch.object(
            manager.guard,
            "test_telegram",
            side_effect=lambda selected, latency_attempts, result_details: (
                result_details.update({"latency_ms": 35.0, "latency_attempts": 3})
                or "test_bot"
            ),
        ) as test, mock.patch("sys.stdout", output):
            result, test_ok = manager.configure_telegram_connection(
                candidate,
                force_ipv4=False,
                active=active,
            )
        self.assertTrue(test_ok)
        self.assertEqual(result["connection_mode"], "direct")
        self.assertEqual(result["node_url"], node_url)
        self.assertIn("原节点链接仍会保留", confirm.call_args.args[0])
        tested = test.call_args.args[0]
        self.assertEqual(tested["connection_mode"], "direct")
        self.assertIn("本次测试方式: 直连", output.getvalue())

    def test_rejected_connection_switch_is_not_tested_or_saved(self):
        node_url = "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@example.com:8388#saved"
        active = dict(guard.DEFAULT_CONFIG["telegram"])
        active.update({"connection_mode": "node", "node_url": node_url})
        candidate = dict(active)
        with mock.patch.object(manager, "prompt_int", side_effect=[1, 8, 7]), mock.patch.object(
            manager, "yes_no", return_value=False
        ), mock.patch.object(manager.guard, "test_telegram") as test:
            result = manager.configure_telegram_connection(
                candidate,
                force_ipv4=False,
                active=active,
            )
        self.assertIsNone(result)
        self.assertEqual(active["connection_mode"], "node")
        self.assertEqual(active["node_url"], node_url)
        test.assert_not_called()

    def test_update_notice_is_yellow_in_terminal(self):
        class TtyOutput(io.StringIO):
            def isatty(self):
                return True

        with mock.patch.object(manager.sys, "stdout", TtyOutput()), mock.patch.dict(
            manager.os.environ, {"TERM": "xterm"}, clear=True
        ):
            result = manager.yellow_text("发现新版本")
        self.assertEqual(result, "\033[33m发现新版本\033[0m")

    def test_menu_marks_available_version(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            config_path.write_text("{}", encoding="utf-8")
            config = make_config()
            config["force_ipv4"] = False
            output = io.StringIO()
            with mock.patch.object(manager, "CONFIG_FILE", config_path), mock.patch.object(
                manager, "load_config", return_value=config
            ), mock.patch.object(
                manager,
                "check_for_github_update",
                return_value={"available": True, "version": "1.3.0", "release_id": "b" * 64},
            ) as check, mock.patch.object(manager, "prompt_int", return_value=15), mock.patch(
                "sys.stdout", output
            ):
                result = manager.menu()
        self.assertEqual(result, 0)
        self.assertIn(
            "阿里云保活与通知 v{} - 管理面板".format(manager.APP_VERSION),
            output.getvalue(),
        )
        self.assertIn("发现新版本: v1.3.0（请选择 14 更新）", output.getvalue())
        self.assertIn(" 5) Telegram 连接方式", output.getvalue())
        self.assertIn("14) 更新 GitHub 版本  [有新版本 v1.3.0]", output.getvalue())
        check.assert_called_once_with()

    def test_menu_test_action_does_not_open_connection_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            config_path.write_text("{}", encoding="utf-8")
            config = make_config()
            config["force_ipv4"] = False
            with mock.patch.object(manager, "CONFIG_FILE", config_path), mock.patch.object(
                manager, "load_config", return_value=config
            ), mock.patch.object(
                manager, "check_for_github_update", return_value=None
            ), mock.patch.object(
                manager, "prompt_int", side_effect=[4, 15]
            ), mock.patch.object(
                manager, "prompt", return_value=""
            ), mock.patch.object(
                manager, "test_current_telegram", return_value=True
            ) as test, mock.patch.object(
                manager, "configure_telegram_connection_settings"
            ) as connection:
                result = manager.menu()
        self.assertEqual(result, 0)
        test.assert_called_once_with(config)
        connection.assert_not_called()

    def test_first_manual_open_runs_setup_then_starts_backend(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            config = make_config()
            with mock.patch.object(manager, "CONFIG_FILE", config_path), mock.patch.object(
                manager, "initial_setup", return_value=0
            ) as setup, mock.patch.object(manager, "run_control", return_value=0) as control, mock.patch.object(
                manager, "load_config", return_value=config
            ), mock.patch.object(manager, "prompt_int", return_value=15):
                result = manager.menu()
        self.assertEqual(result, 0)
        setup.assert_called_once_with(force=False)
        control.assert_called_once_with("start")

    def test_opening_existing_panel_does_not_force_start_service(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            config_path.write_text("{}", encoding="utf-8")
            config = make_config()
            with mock.patch.object(manager, "CONFIG_FILE", config_path), mock.patch.object(
                manager, "initial_setup"
            ) as setup, mock.patch.object(manager, "run_control") as control, mock.patch.object(
                manager, "load_config", return_value=config
            ), mock.patch.object(manager, "prompt_int", return_value=15):
                result = manager.menu()
        self.assertEqual(result, 0)
        setup.assert_not_called()
        control.assert_not_called()


if __name__ == "__main__":
    unittest.main()
