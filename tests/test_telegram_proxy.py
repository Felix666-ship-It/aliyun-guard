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

    def test_describes_vless_node_with_safe_remark(self):
        link = (
            "vless://11111111-1111-1111-1111-111111111111@example.com:443"
            "?security=tls#Hong%20Kong%0A01"
        )
        self.assertEqual(
            telegram_proxy.describe_node_link(link),
            "VLESS 节点（Hong Kong 01）",
        )

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
        self.assertEqual(
            telegram_proxy.describe_node_link(
                "vmess://{}".format(encoded(json.dumps(payload)))
            ),
            "VMESS 节点（test）",
        )

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

    def test_parses_trojan_hysteria2_tuic_and_anytls(self):
        trojan = telegram_proxy.parse_node_link(
            "trojan://trojan-password@trojan.example:443?sni=edge.example.com#Trojan"
        )
        hysteria2 = telegram_proxy.parse_node_link(
            "hy2://hy2-password@hy2.example:443?obfs=salamander&obfs-password=obfs-secret#Hysteria2"
        )
        tuic = telegram_proxy.parse_node_link(
            "tuic://33333333-3333-3333-3333-333333333333:tuic-password@tuic.example:443?congestion_control=bbr#TUIC"
        )
        anytls = telegram_proxy.parse_node_link(
            "anytls://anytls-password@anytls.example:443?sni=edge.example.com#AnyTLS"
        )

        self.assertEqual(trojan["type"], "trojan")
        self.assertEqual(trojan["password"], "trojan-password")
        self.assertEqual(hysteria2["type"], "hysteria2")
        self.assertEqual(hysteria2["obfs"], {"type": "salamander", "password": "obfs-secret"})
        self.assertEqual(tuic["type"], "tuic")
        self.assertEqual(tuic["uuid"], "33333333-3333-3333-3333-333333333333")
        self.assertEqual(anytls["type"], "anytls")
        self.assertEqual(anytls["tls"]["server_name"], "edge.example.com")
        self.assertEqual(
            telegram_proxy.describe_node_link(
                "anytls://anytls-password@anytls.example:443#AnyTLS"
            ),
            "ANYTLS 节点（AnyTLS）",
        )

    def test_parses_plain_and_base64_subscription_nodes(self):
        vless = (
            "vless://11111111-1111-1111-1111-111111111111@node.example:443"
            "?security=tls#First"
        )
        anytls = "anytls://subscription-password@anytls.example:443#AnyTLS"
        plain = "{}\nunsupported://ignored\n{}\n{}\n".format(vless, anytls, vless)
        self.assertEqual(
            telegram_proxy.parse_subscription_content(plain), [vless, anytls]
        )
        encoded_subscription = base64.b64encode(plain.encode("utf-8"))
        self.assertEqual(
            telegram_proxy.parse_subscription_content(encoded_subscription), [vless, anytls]
        )

    def test_rejects_private_subscription_address(self):
        with mock.patch.object(
            telegram_proxy.socket,
            "getaddrinfo",
            return_value=[(2, 1, 6, "", ("127.0.0.1", 443))],
        ):
            with self.assertRaises(telegram_proxy.ProxyError):
                telegram_proxy._subscription_url("https://subscription.example/list")

    def test_malformed_node_link_is_a_proxy_error_and_subscription_skips_it(self):
        malformed = "anytls://password@[broken:443"
        valid = "anytls://password@valid.example:443#Valid"
        with self.assertRaises(telegram_proxy.ProxyError):
            telegram_proxy.parse_node_link(malformed)
        self.assertEqual(
            telegram_proxy.parse_subscription_content(malformed + "\n" + valid),
            [valid],
        )

    def test_subscription_fetch_connects_to_validated_address(self):
        response = mock.MagicMock(status=200)
        response.getheader.return_value = None
        response.read.return_value = b"anytls://password@node.example:443#Node"
        connection = mock.MagicMock()
        connection.getresponse.return_value = response
        addresses = [(2, 1, 6, "", ("8.8.8.8", 443))]
        with mock.patch.object(
            telegram_proxy.socket, "getaddrinfo", return_value=addresses
        ), mock.patch.object(
            telegram_proxy, "_PinnedHTTPSConnection", return_value=connection
        ) as pinned:
            nodes = telegram_proxy.fetch_subscription_nodes(
                "https://subscription.example/list"
            )
        pinned.assert_called_once_with("subscription.example", 443, "8.8.8.8", 20)
        self.assertEqual(nodes, ["anytls://password@node.example:443#Node"])

    def test_node_description_falls_back_to_server(self):
        link = "ss://{}@ss.example.com:8388".format(
            encoded("aes-256-gcm:secret-password")
        )
        self.assertEqual(
            telegram_proxy.describe_node_link(link),
            "SHADOWSOCKS 节点（ss.example.com:8388）",
        )

    def test_builds_loopback_only_sing_box_config(self):
        link = "ss://{}@ss.example.com:8388".format(encoded("aes-128-gcm:password"))
        config = telegram_proxy.build_sing_box_config(link, 19001)
        inbound = config["inbounds"][0]
        self.assertEqual(inbound["listen"], "127.0.0.1")
        self.assertEqual(inbound["listen_port"], 19001)
        self.assertEqual(config["outbounds"][0]["type"], "shadowsocks")

    def test_rejects_unknown_node_scheme(self):
        with self.assertRaises(telegram_proxy.ProxyError):
            telegram_proxy.parse_node_link("unsupported://password@example.com:443")

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
