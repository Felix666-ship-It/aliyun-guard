import copy
import http.client
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import aliyun_guard as guard
import manager
import web_panel


def make_user():
    return {
        "name": "Hong Kong",
        "ak": "test-access-key-private",
        "sk": "test-secret-key-private",
        "region": "cn-hongkong",
        "instance_id": "i-webtest123",
        "traffic_limit_gb": 180,
        "actions_enabled": True,
        "instance_log_enabled": False,
        "paused": False,
        "billing": {
            "enabled": False,
            "site": "china",
            "endpoint": "business.aliyuncs.com",
            "region": "cn-hangzhou",
            "currency_code": "CNY",
            "currency_symbol": "¥",
        },
        "schedule": {
            "enabled": True,
            "start_time": "08:00",
            "stop_time": "23:00",
        },
    }


def make_config(password="correct-horse"):
    config = copy.deepcopy(guard.DEFAULT_CONFIG)
    config["telegram"]["bot_token"] = "test-bot-token-private"
    config["telegram"]["chat_id"] = "123"
    config["users"] = [make_user()]
    config["web_panel"] = {
        "enabled": True,
        "host": "127.0.0.1",
        "port": 8765,
        "username": "admin",
        "password_hash": web_panel.hash_password(password, iterations=1000),
        "cookie_secure": False,
    }
    return config


class PasswordTests(unittest.TestCase):
    def test_web_and_manager_versions_match(self):
        self.assertEqual(web_panel.APP_VERSION, manager.APP_VERSION)

    def test_password_hash_round_trip_and_rejects_wrong_password(self):
        encoded = web_panel.hash_password("a-long-password", iterations=1000)
        self.assertTrue(web_panel.verify_password("a-long-password", encoded))
        self.assertFalse(web_panel.verify_password("wrong-password", encoded))
        self.assertNotIn("a-long-password", encoded)

    def test_password_must_have_eight_characters(self):
        with self.assertRaises(ValueError):
            web_panel.hash_password("short")

    def test_enabled_panel_requires_valid_hash(self):
        config = make_config()
        config["web_panel"]["password_hash"] = ""
        with self.assertRaises(web_panel.WebPanelError):
            web_panel.validate_web_config(config)


class WebAddressTests(unittest.TestCase):
    def test_public_listener_uses_detected_local_ipv4(self):
        web = {"host": "0.0.0.0", "port": 8765}
        with mock.patch.object(
            web_panel, "detect_primary_ipv4", return_value="192.0.2.25"
        ):
            self.assertEqual(
                web_panel.browser_access_url(web), "http://192.0.2.25:8765"
            )

    def test_public_listener_falls_back_when_ipv4_cannot_be_detected(self):
        web = {"host": "0.0.0.0", "port": 8765}
        with mock.patch.object(web_panel, "detect_primary_ipv4", return_value=""):
            self.assertEqual(
                web_panel.browser_access_url(web), "http://服务器IP:8765"
            )

    def test_loopback_listener_keeps_loopback_address(self):
        web = {"host": "127.0.0.1", "port": 9000}
        self.assertEqual(web_panel.browser_access_url(web), "http://127.0.0.1:9000")

    def test_container_listener_uses_public_ip_and_host_port(self):
        web = {"host": "0.0.0.0", "port": 8765}
        with mock.patch.dict(
            "os.environ",
            {
                "ALIYUN_GUARD_CONTAINER": "1",
                "ALIYUN_GUARD_HOST_BIND_IP": "0.0.0.0",
                "ALIYUN_GUARD_PUBLIC_IP": "8.8.4.4",
                "ALIYUN_GUARD_PUBLIC_WEB_PORT": "9876",
            },
        ):
            self.assertEqual(
                web_panel.browser_access_url(web), "http://8.8.4.4:9876"
            )

    def test_container_listener_has_clear_public_ip_fallback(self):
        web = {"host": "0.0.0.0", "port": 8765}
        with mock.patch.dict(
            "os.environ",
            {
                "ALIYUN_GUARD_CONTAINER": "1",
                "ALIYUN_GUARD_HOST_BIND_IP": "0.0.0.0",
                "ALIYUN_GUARD_PUBLIC_IP": "",
                "ALIYUN_GUARD_PUBLIC_WEB_PORT": "8765",
            },
        ):
            self.assertEqual(
                web_panel.browser_access_url(web),
                "http://服务器公网IP:8765",
            )

    def test_container_loopback_override_does_not_report_public_ip(self):
        web = {"host": "0.0.0.0", "port": 8765}
        with mock.patch.dict(
            "os.environ",
            {
                "ALIYUN_GUARD_CONTAINER": "1",
                "ALIYUN_GUARD_HOST_BIND_IP": "127.0.0.1",
                "ALIYUN_GUARD_PUBLIC_IP": "8.8.4.4",
                "ALIYUN_GUARD_PUBLIC_WEB_PORT": "9876",
            },
        ):
            self.assertEqual(
                web_panel.browser_access_url(web), "http://127.0.0.1:9876"
            )

    def test_manager_prints_detected_browser_address(self):
        output = io.StringIO()
        web = {"host": "0.0.0.0", "port": 8765, "cookie_secure": True}
        with mock.patch.object(
            web_panel, "detect_primary_ipv4", return_value="10.20.30.40"
        ), mock.patch("sys.stdout", output):
            manager.print_web_panel_access(web)
        self.assertIn("网页监听: http://0.0.0.0:8765", output.getvalue())
        self.assertIn("浏览器访问: http://10.20.30.40:8765", output.getvalue())
        self.assertIn("HTTPS 反向代理: 支持", output.getvalue())


class PayloadTests(unittest.TestCase):
    def test_dashboard_never_returns_raw_credentials(self):
        config = make_config()
        state = {
            "cycle_count": 3,
            "last_cycle_ok": True,
            "last_cycle_finished_at": "2026-07-16T12:00:00+08:00",
            "instances": {
                "i-webtest123": {
                    "traffic_gb": 42.5,
                    "status_after": "Running",
                    "bill_amount": 8.2,
                    "bill_currency": "CNY",
                    "level": "ok",
                    "message": "正常",
                }
            },
            "history": [
                {
                    "at": "2026-07-16T11:55:00+08:00",
                    "instances": {"i-webtest123": {"traffic_gb": 41.0}},
                },
                {
                    "at": "2026-07-16T12:00:00+08:00",
                    "instances": {"i-webtest123": {"traffic_gb": 42.5}},
                },
            ],
        }
        payload = web_panel.dashboard_payload(guard, config, state)
        serialized = json.dumps(payload, ensure_ascii=False)
        self.assertNotIn(config["users"][0]["ak"], serialized)
        self.assertNotIn(config["users"][0]["sk"], serialized)
        self.assertNotIn(config["telegram"]["bot_token"], serialized)
        self.assertEqual(payload["users"][0]["status"], "Running")
        self.assertEqual(len(payload["users"][0]["history"]), 2)
        self.assertEqual(payload["users"][0]["history"][0]["action"], "none")
        self.assertFalse(payload["users"][0]["history"][0]["action_performed"])

    def test_dashboard_history_returns_action_details(self):
        config = make_config()
        state = {
            "instances": {},
            "history": [
                {
                    "at": "2026-07-16T12:00:00+08:00",
                    "instances": {
                        "i-webtest123": {
                            "traffic_gb": 180.5,
                            "status_before": "Running",
                            "status_after": "Stopped",
                            "action": "stop",
                            "action_performed": True,
                            "message": "流量达到阈值，已停止实例",
                            "level": "action",
                        }
                    },
                }
            ],
        }
        point = web_panel.dashboard_payload(guard, config, state)["users"][0][
            "history"
        ][0]
        self.assertEqual(point["status_before"], "Running")
        self.assertEqual(point["status"], "Stopped")
        self.assertEqual(point["action"], "stop")
        self.assertTrue(point["action_performed"])
        self.assertIn("已停止", point["message"])


class WebApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        directory = Path(self.temp.name)
        self.originals = {
            "CONFIG_FILE": guard.CONFIG_FILE,
            "STATE_FILE": guard.STATE_FILE,
            "LOCK_FILE": guard.LOCK_FILE,
            "LOG_FILE": guard.LOG_FILE,
        }
        guard.CONFIG_FILE = directory / "config.json"
        guard.STATE_FILE = directory / "state.json"
        guard.LOCK_FILE = directory / "cycle.lock"
        guard.LOG_FILE = directory / "guard.log"
        self.config = make_config()
        guard.atomic_write_json(guard.CONFIG_FILE, self.config)
        guard.atomic_write_json(
            guard.STATE_FILE,
            {
                "cycle_count": 1,
                "last_cycle_ok": True,
                "last_cycle_finished_at": "2026-07-16T12:00:00+08:00",
                "instances": {
                    "i-webtest123": {
                        "traffic_gb": 22.0,
                        "status_after": "Running",
                        "level": "ok",
                        "message": "运行正常",
                    }
                },
            },
        )
        self.server = web_panel.create_server(
            guard,
            self.config,
            host="127.0.0.1",
            port=0,
            html="<!doctype html><title>Aliyun Guard</title>",
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        for name, value in self.originals.items():
            setattr(guard, name, value)
        self.temp.cleanup()

    def request(self, method, path, body=None, cookie=None, csrf=None, extra_headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Accept": "application/json"}
        headers.update(extra_headers or {})
        encoded = None
        if body is not None:
            encoded = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if cookie:
            headers["Cookie"] = cookie
        if csrf:
            headers["X-CSRF-Token"] = csrf
        connection.request(method, path, body=encoded, headers=headers)
        response = connection.getresponse()
        data = json.loads(response.read().decode("utf-8"))
        result = response.status, data, dict(response.getheaders())
        connection.close()
        return result

    def login(self):
        status, data, headers = self.request(
            "POST",
            "/api/login",
            {"username": "admin", "password": "correct-horse"},
        )
        self.assertEqual(status, 200)
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        return cookie, data["csrf"]

    def test_dashboard_requires_login_and_security_headers_are_present(self):
        status, _data, headers = self.request("GET", "/api/dashboard")
        self.assertEqual(status, 401)
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])

    def test_session_reports_current_http_transport(self):
        status, data, _headers = self.request("GET", "/api/session")
        self.assertEqual(status, 200)
        self.assertFalse(data["secure_cookie"])

    def test_login_dashboard_and_session_do_not_leak_credentials(self):
        cookie, _csrf = self.login()
        status, data, _headers = self.request("GET", "/api/dashboard", cookie=cookie)
        self.assertEqual(status, 200)
        serialized = json.dumps(data)
        self.assertNotIn("test-access-key-private", serialized)
        self.assertNotIn("test-secret-key-private", serialized)
        self.assertNotIn("test-bot-token-private", serialized)
        self.assertNotIn("access_key", data["users"][0])

    def test_management_payload_is_authenticated_and_redacted(self):
        status, _data, _headers = self.request("GET", "/api/management")
        self.assertEqual(status, 401)
        cookie, _csrf = self.login()
        status, data, _headers = self.request(
            "GET", "/api/management", cookie=cookie
        )
        self.assertEqual(status, 200)
        serialized = json.dumps(data, ensure_ascii=False)
        self.assertNotIn("test-access-key-private", serialized)
        self.assertNotIn("test-secret-key-private", serialized)
        self.assertNotIn("test-bot-token-private", serialized)
        self.assertTrue(data["telegram"]["bot_token_configured"])
        self.assertTrue(data["instances"][0]["secret_key_configured"])

    def test_schedule_update_requires_csrf_then_persists(self):
        cookie, csrf = self.login()
        payload = {"enabled": True, "start_time": "22:30", "stop_time": "06:15"}
        status, _data, _headers = self.request(
            "POST", "/api/instances/0/schedule", payload, cookie=cookie
        )
        self.assertEqual(status, 403)
        status, data, _headers = self.request(
            "POST", "/api/instances/0/schedule", payload, cookie=cookie, csrf=csrf
        )
        self.assertEqual(status, 200)
        self.assertTrue(data["ok"])
        saved = guard.load_config()["users"][0]["schedule"]
        self.assertEqual(saved["start_time"], "22:30")
        self.assertEqual(saved["stop_time"], "06:15")

    def test_instance_logs_can_be_selected_toggled_and_read_after_disable(self):
        cookie, csrf = self.login()
        user = guard.load_config()["users"][0]
        path = guard.instance_log_path(user)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("historical instance line\n", encoding="utf-8")

        status, _data, _headers = self.request(
            "POST",
            "/api/instances/0/logging",
            {"enabled": True},
            cookie=cookie,
        )
        self.assertEqual(status, 403)
        status, data, _headers = self.request(
            "POST",
            "/api/instances/0/logging",
            {"enabled": True},
            cookie=cookie,
            csrf=csrf,
        )
        self.assertEqual(status, 200)
        self.assertTrue(data["result"]["enabled"])

        status, data, _headers = self.request(
            "GET", "/api/logs?instance=0&limit=200", cookie=cookie
        )
        self.assertEqual(status, 200)
        self.assertEqual(data["source"], "instance")
        self.assertEqual(data["instance_id"], "i-webtest123")
        self.assertTrue(data["enabled"])
        self.assertEqual(data["lines"], ["historical instance line"])

        status, _data, _headers = self.request(
            "POST",
            "/api/instances/0/logging",
            {"enabled": False},
            cookie=cookie,
            csrf=csrf,
        )
        self.assertEqual(status, 200)
        status, data, _headers = self.request(
            "GET", "/api/logs?instance=0", cookie=cookie
        )
        self.assertEqual(status, 200)
        self.assertFalse(data["enabled"])
        self.assertEqual(data["lines"], ["historical instance line"])

        status, _data, _headers = self.request(
            "GET", "/api/logs?instance=../../etc/passwd", cookie=cookie
        )
        self.assertEqual(status, 400)

    def test_settings_update_persists(self):
        cookie, csrf = self.login()
        status, _data, _headers = self.request(
            "POST",
            "/api/settings",
            {"interval_seconds": 600, "notification_mode": "events"},
            cookie=cookie,
            csrf=csrf,
        )
        self.assertEqual(status, 200)
        saved = guard.load_config()
        self.assertEqual(saved["interval_seconds"], 600)
        self.assertEqual(saved["notification_mode"], "events")

    def test_http_login_works_with_legacy_secure_option_enabled(self):
        self.config["web_panel"]["cookie_secure"] = True
        guard.atomic_write_json(guard.CONFIG_FILE, self.config)
        status, data, headers = self.request(
            "POST",
            "/api/login",
            {"username": "admin", "password": "correct-horse"},
            extra_headers={"Origin": "http://127.0.0.1:{}".format(self.port)},
        )
        self.assertEqual(status, 200)
        self.assertFalse(data["secure_cookie"])
        self.assertTrue(headers["Set-Cookie"].startswith("ag_session="))
        self.assertNotIn("; Secure", headers["Set-Cookie"])

    def test_https_reverse_proxy_uses_independent_secure_cookie(self):
        self.config["web_panel"]["cookie_secure"] = False
        guard.atomic_write_json(guard.CONFIG_FILE, self.config)
        status, data, headers = self.request(
            "POST",
            "/api/login",
            {"username": "admin", "password": "correct-horse"},
            extra_headers={"X-Forwarded-Proto": "https"},
        )
        self.assertEqual(status, 200)
        self.assertTrue(data["secure_cookie"])
        self.assertTrue(headers["Set-Cookie"].startswith("ag_session_secure="))
        self.assertIn("; Secure", headers["Set-Cookie"])
        secure_cookie = headers["Set-Cookie"].split(";", 1)[0]
        status, _data, _headers = self.request(
            "GET", "/api/dashboard", cookie=secure_cookie
        )
        self.assertEqual(status, 401)
        status, _data, _headers = self.request(
            "GET",
            "/api/dashboard",
            cookie=secure_cookie,
            extra_headers={"X-Forwarded-Proto": "https"},
        )
        self.assertEqual(status, 200)

    def test_run_endpoint_starts_and_finishes_one_cycle(self):
        cookie, csrf = self.login()
        with mock.patch.object(guard, "run_cycle", return_value=0) as run_cycle:
            status, data, _headers = self.request(
                "POST", "/api/run", {}, cookie=cookie, csrf=csrf
            )
            self.assertEqual(status, 202)
            self.assertTrue(data["job"]["running"])
            deadline = time.time() + 3
            while time.time() < deadline:
                status, job, _headers = self.request(
                    "GET", "/api/job", cookie=cookie
                )
                self.assertEqual(status, 200)
                if not job["running"]:
                    break
                time.sleep(0.02)
            self.assertFalse(job["running"])
            self.assertIsNone(job["error"])
        run_cycle.assert_called_once_with(dry_run=False)

    def test_run_endpoint_supports_dry_run(self):
        cookie, csrf = self.login()
        with mock.patch.object(guard, "run_cycle", return_value=0) as run_cycle:
            status, _data, _headers = self.request(
                "POST",
                "/api/run",
                {"dry_run": True},
                cookie=cookie,
                csrf=csrf,
            )
            self.assertEqual(status, 202)
            deadline = time.time() + 3
            while time.time() < deadline:
                _status, job, _headers = self.request(
                    "GET", "/api/job", cookie=cookie
                )
                if not job["running"]:
                    break
                time.sleep(0.02)
        run_cycle.assert_called_once_with(dry_run=True)

    def test_telegram_identity_blank_token_preserves_secret(self):
        cookie, csrf = self.login()
        status, data, _headers = self.request(
            "POST",
            "/api/telegram/identity",
            {
                "bot_token": "",
                "chat_id": "456",
                "timeout_seconds": 15,
                "retries": 2,
            },
            cookie=cookie,
            csrf=csrf,
        )
        self.assertEqual(status, 200)
        self.assertNotIn("bot_token", data["telegram"])
        saved = guard.load_config()["telegram"]
        self.assertEqual(saved["bot_token"], "test-bot-token-private")
        self.assertEqual(saved["chat_id"], "456")


class ManualControlTests(unittest.TestCase):
    def test_manual_start_is_blocked_when_traffic_reaches_limit(self):
        config = make_config()
        config["users"][0]["paused"] = True
        with mock.patch.object(guard, "load_config", return_value=config), mock.patch.object(
            guard, "query_instance_status", return_value="Stopped"
        ), mock.patch.object(
            guard, "query_cdt_traffic_gb", return_value=180.0
        ), mock.patch.object(guard, "start_instance") as start:
            with self.assertRaises(web_panel.WebPanelError) as raised:
                web_panel.control_instance(guard, 0, "start")
        self.assertEqual(raised.exception.status, 409)
        start.assert_not_called()

    def test_manual_stop_sends_notification(self):
        config = make_config()
        config["users"][0]["paused"] = True
        with mock.patch.object(guard, "load_config", return_value=config), mock.patch.object(
            guard, "query_instance_status", return_value="Running"
        ), mock.patch.object(guard, "stop_instance") as stop, mock.patch.object(
            guard, "wait_for_status", return_value=("Stopped", None)
        ), mock.patch.object(guard, "send_telegram_message") as send, mock.patch.object(
            guard, "load_state", return_value={"instances": {}, "history": []}
        ), mock.patch.object(guard, "save_state") as save_state, mock.patch.object(
            guard, "write_instance_log"
        ) as write_log:
            result = web_panel.control_instance(guard, 0, "stop")
        stop.assert_called_once()
        send.assert_called_once()
        saved_state = save_state.call_args.args[0]
        event = saved_state["history"][0]["instances"]["i-webtest123"]
        self.assertEqual(event["action"], "manual_stop")
        self.assertTrue(event["action_performed"])
        self.assertEqual(result["after"], "Stopped")
        write_log.assert_called_once()
        self.assertEqual(write_log.call_args.kwargs["event"], "网页手动关机")

    def test_manual_stop_requires_pausing_active_keepalive(self):
        config = make_config()
        config["users"][0]["schedule"]["enabled"] = False
        with mock.patch.object(guard, "load_config", return_value=config), mock.patch.object(
            guard, "stop_instance"
        ) as stop:
            with self.assertRaises(web_panel.WebPanelError) as raised:
                web_panel.control_instance(guard, 0, "stop")
        self.assertEqual(raised.exception.status, 409)
        stop.assert_not_called()


class WebHtmlTests(unittest.TestCase):
    def test_sparkline_points_keep_fixed_size_and_edge_padding(self):
        html = (ROOT / "src" / "web_panel.html").read_text(encoding="utf-8")
        self.assertIn("const chartLeft = 4, chartRight = 316", html)
        self.assertIn('class="chart-point" d="M ${latest.x} ${latest.y} h .01"', html)
        self.assertIn("vector-effect: non-scaling-stroke", html)
        self.assertNotIn('<circle class="chart-point"', html)

    def test_sensitive_fields_use_leave_blank_guidance(self):
        html = (ROOT / "src" / "web_panel.html").read_text(encoding="utf-8")
        self.assertGreaterEqual(html.count("已保存，留空不修改"), 5)
        self.assertIn("当时流量", html)
        self.assertIn("执行动作", html)
        self.assertIn("仅检测，无动作", html)
        self.assertIn("单机设置", html)
        self.assertIn("查看独立日志", html)
        self.assertIn("记录该实例独立日志", html)
        self.assertIn("instanceLogToggle", html)
        self.assertIn("删除监控实例", html)

if __name__ == "__main__":
    unittest.main()
