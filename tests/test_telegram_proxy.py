import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import telegram_proxy


def encoded(value):
    return base64.urlsafe_b64encode(value.encode("utf-8")).decode("ascii").rstrip("=")


class NodeParserTests(unittest.TestCase):
    def test_parses_vless_reality(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=reality&sni=www.example.com&fp=chrome&pbk=public-key"
            "&sid=abcd&type=tcp&flow=xtls-rprx-vision"
        )
        outbound = telegram_proxy.parse_node_link(link)
        self.assertEqual(outbound["type"], "vless")
        self.assertEqual(outbound["server"], "example.com")
        self.assertEqual(outbound["server_port"], 443)
        self.assertEqual(outbound["flow"], "xtls-rprx-vision")
        self.assertTrue(outbound["tls"]["reality"]["enabled"])
        self.assertEqual(outbound["tls"]["reality"]["public_key"], "public-key")
        self.assertEqual(outbound["tls"]["utls"]["fingerprint"], "chrome")

    def test_parses_vless_websocket(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls&sni=edge.example.com&type=ws&host=cdn.example.com&path=%2Ftelegram"
        )
        outbound = telegram_proxy.parse_node_link(link)
        self.assertEqual(outbound["transport"]["type"], "ws")
        self.assertEqual(outbound["transport"]["path"], "/telegram")
        self.assertEqual(outbound["transport"]["headers"]["Host"], "cdn.example.com")

    def test_parses_vmess_websocket(self):
        payload = {
            "v": "2",
            "ps": "test",
            "add": "vmess.example.com",
            "port": "443",
            "id": "22222222-2222-2222-2222-222222222222",
            "aid": "0",
            "scy": "auto",
            "net": "ws",
            "host": "cdn.example.com",
            "path": "/ws",
            "tls": "tls",
            "sni": "edge.example.com",
            "fp": "chrome",
        }
        outbound = telegram_proxy.parse_node_link("vmess://{}".format(encoded(json.dumps(payload))))
        self.assertEqual(outbound["type"], "vmess")
        self.assertEqual(outbound["server_port"], 443)
        self.assertEqual(outbound["transport"]["type"], "ws")
        self.assertEqual(outbound["tls"]["server_name"], "edge.example.com")

    def test_parses_vmess_grpc_service_name_from_path(self):
        payload = {
            "v": "2",
            "add": "vmess.example.com",
            "port": "443",
            "id": "22222222-2222-2222-2222-222222222222",
            "aid": "0",
            "net": "grpc",
            "path": "telegram-service",
            "tls": "tls",
        }
        outbound = telegram_proxy.parse_node_link(
            "vmess://{}".format(encoded(json.dumps(payload)))
        )
        self.assertEqual(outbound["transport"]["type"], "grpc")
        self.assertEqual(outbound["transport"]["service_name"], "telegram-service")

    def test_parses_vless_http_transport(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls&type=http&host=cdn.example.com&path=%2Fh2"
        )
        outbound = telegram_proxy.parse_node_link(link)
        self.assertEqual(outbound["transport"]["type"], "http")
        self.assertEqual(outbound["transport"]["host"], ["cdn.example.com"])
        self.assertEqual(outbound["transport"]["path"], "/h2")

    def test_parses_shadowsocks_sip002(self):
        userinfo = encoded("aes-256-gcm:secret-password")
        outbound = telegram_proxy.parse_node_link(
            "ss://{}@ss.example.com:8388#test".format(userinfo)
        )
        self.assertEqual(outbound["type"], "shadowsocks")
        self.assertEqual(outbound["method"], "aes-256-gcm")
        self.assertEqual(outbound["password"], "secret-password")
        self.assertEqual(outbound["server_port"], 8388)

    def test_builds_loopback_only_sing_box_config(self):
        link = "ss://{}@ss.example.com:8388".format(encoded("aes-128-gcm:password"))
        config = telegram_proxy.build_sing_box_config(link, 19001)
        inbound = config["inbounds"][0]
        self.assertEqual(inbound["listen"], "127.0.0.1")
        self.assertEqual(inbound["listen_port"], 19001)
        self.assertEqual(config["outbounds"][0]["type"], "shadowsocks")

    def test_rejects_unknown_node_scheme(self):
        with self.assertRaises(telegram_proxy.ProxyError):
            telegram_proxy.parse_node_link("trojan://password@example.com:443")

    def test_maps_supported_linux_architectures(self):
        expected = {
            "x86_64": "amd64",
            "aarch64": "arm64",
            "armv7l": "armv7",
            "i686": "386",
        }
        for machine, architecture in expected.items():
            with self.subTest(machine=machine), mock.patch.object(
                telegram_proxy.platform, "machine", return_value=machine
            ):
                self.assertEqual(telegram_proxy._architecture(), architecture)

    def test_official_assets_have_sha256(self):
        for asset_name, digest in telegram_proxy.SING_BOX_ASSETS.values():
            self.assertTrue(asset_name.startswith("sing-box-1.13.14-linux-"))
            self.assertEqual(len(digest), 64)
            int(digest, 16)

    def test_check_exception_removes_runtime_directory(self):
        link = "ss://{}@ss.example.com:8388".format(encoded("aes-128-gcm:password"))
        telegram_proxy.stop_node_proxy()
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            telegram_proxy, "APP_DIR", Path(directory)
        ), mock.patch.object(
            telegram_proxy, "find_sing_box", return_value="/usr/bin/sing-box"
        ), mock.patch.object(
            telegram_proxy.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired("sing-box check", 15),
        ):
            with self.assertRaises(telegram_proxy.ProxyError):
                telegram_proxy.ensure_node_proxy(link)
            runtime = Path(directory) / "runtime"
            self.assertEqual(list(runtime.glob("telegram-node-*")), [])

    def test_stop_node_proxy_is_idempotent(self):
        telegram_proxy.stop_node_proxy()
        telegram_proxy.stop_node_proxy()


if __name__ == "__main__":
    unittest.main()
