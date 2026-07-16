#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Telegram proxy helpers backed by an official sing-box binary."""

import atexit
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import tarfile
import tempfile
import threading
import time
import urllib.parse
import urllib.request


APP_DIR = Path(os.environ.get("ALIYUN_GUARD_HOME", Path(__file__).resolve().parent))
SING_BOX_VERSION = "1.13.14"
SING_BOX_BINARY = APP_DIR / "bin" / "sing-box"
SING_BOX_RELEASE_BASE = (
    "https://github.com/SagerNet/sing-box/releases/download/v{}".format(SING_BOX_VERSION)
)
SING_BOX_ASSETS = {
    "386": (
        "sing-box-1.13.14-linux-386.tar.gz",
        "4d1c66260dfcb2120fde6c1c5ad125ce0f94769843c34aab4eef53c8d3bf3ae9",
    ),
    "amd64": (
        "sing-box-1.13.14-linux-amd64.tar.gz",
        "f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697",
    ),
    "arm64": (
        "sing-box-1.13.14-linux-arm64.tar.gz",
        "4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e",
    ),
    "armv7": (
        "sing-box-1.13.14-linux-armv7.tar.gz",
        "e01a58d28512b1447ab6156017afdeeaa306169a95d27abc00e112599e4ae46c",
    ),
}

_PROCESS = None
_PROCESS_KEY = None
_PROCESS_PROXY_URL = None
_PROCESS_DIR = None
_PROCESS_LOG = None
_PROCESS_LOCK = threading.RLock()


class ProxyError(RuntimeError):
    pass


def _decode_base64(value):
    value = urllib.parse.unquote(str(value or "").strip())
    value += "=" * (-len(value) % 4)
    try:
        return base64.urlsafe_b64decode(value.encode("ascii")).decode("utf-8")
    except Exception:
        raise ProxyError("节点链接包含无效的 Base64 数据")


def _query_value(query, *names, **kwargs):
    default = kwargs.get("default", "")
    for name in names:
        values = query.get(name)
        if values:
            return str(values[0])
    return default


def _truthy(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def _require_server(parsed):
    try:
        port = parsed.port
    except ValueError:
        raise ProxyError("节点端口无效")
    if not parsed.hostname or not port:
        raise ProxyError("节点链接缺少服务器地址或端口")
    return parsed.hostname, port


def _build_tls(query, server, security):
    if security not in ("tls", "reality"):
        return None
    tls = {
        "enabled": True,
        "server_name": _query_value(query, "sni", "serverName", default=server),
    }
    if _truthy(_query_value(query, "allowInsecure", "insecure")):
        tls["insecure"] = True
    alpn = _query_value(query, "alpn")
    if alpn:
        tls["alpn"] = [item.strip() for item in alpn.split(",") if item.strip()]
    fingerprint = _query_value(query, "fp", "fingerprint")
    if fingerprint and fingerprint.lower() != "none":
        tls["utls"] = {"enabled": True, "fingerprint": fingerprint}
    if security == "reality":
        public_key = _query_value(query, "pbk", "publicKey")
        if not public_key:
            raise ProxyError("Reality 节点缺少 public key（pbk）")
        tls["reality"] = {
            "enabled": True,
            "public_key": public_key,
            "short_id": _query_value(query, "sid", "shortId"),
        }
    return tls


def _build_transport(network, query, host="", path=""):
    network = str(network or "tcp").strip().lower()
    if network in ("", "tcp", "raw"):
        return None
    if network == "ws":
        transport = {
            "type": "ws",
            "path": urllib.parse.unquote(path or _query_value(query, "path", default="/")),
        }
        ws_host = host or _query_value(query, "host")
        if ws_host:
            transport["headers"] = {"Host": ws_host}
        return transport
    if network == "grpc":
        return {
            "type": "grpc",
            "service_name": urllib.parse.unquote(
                path or _query_value(query, "serviceName", "service_name", "path")
            ),
        }
    if network in ("http", "h2"):
        transport = {
            "type": "http",
            "path": urllib.parse.unquote(path or _query_value(query, "path", default="/")),
        }
        http_host = host or _query_value(query, "host")
        if http_host:
            transport["host"] = [http_host]
        return transport
    if network in ("httpupgrade", "http-upgrade"):
        transport = {
            "type": "httpupgrade",
            "path": urllib.parse.unquote(path or _query_value(query, "path", default="/")),
        }
        upgrade_host = host or _query_value(query, "host")
        if upgrade_host:
            transport["host"] = upgrade_host
        return transport
    raise ProxyError("暂不支持节点传输类型: {}".format(network))


def parse_vless_link(link):
    parsed = urllib.parse.urlsplit(link)
    server, port = _require_server(parsed)
    uuid = urllib.parse.unquote(parsed.username or "").strip()
    if not uuid:
        raise ProxyError("VLESS 节点缺少 UUID")
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    outbound = {
        "type": "vless",
        "tag": "telegram-node",
        "server": server,
        "server_port": port,
        "uuid": uuid,
    }
    flow = _query_value(query, "flow")
    if flow:
        outbound["flow"] = flow
    packet_encoding = _query_value(query, "packetEncoding", "packet_encoding")
    if packet_encoding:
        outbound["packet_encoding"] = packet_encoding
    security = _query_value(query, "security").lower()
    tls = _build_tls(query, server, security)
    if tls:
        outbound["tls"] = tls
    transport = _build_transport(
        _query_value(query, "type", default="tcp"),
        query,
        _query_value(query, "host"),
        _query_value(query, "path"),
    )
    if transport:
        outbound["transport"] = transport
    return outbound


def parse_vmess_link(link):
    encoded = link[len("vmess://"):].split("#", 1)[0].strip()
    try:
        data = json.loads(_decode_base64(encoded))
    except ValueError:
        raise ProxyError("VMess 节点内容不是有效 JSON")
    if not isinstance(data, dict):
        raise ProxyError("VMess 节点内容格式无效")
    server = str(data.get("add", "")).strip()
    uuid = str(data.get("id", "")).strip()
    try:
        port = int(data.get("port", 0))
        alter_id = int(data.get("aid", 0) or 0)
    except (TypeError, ValueError):
        raise ProxyError("VMess 节点端口或 alterId 无效")
    if not server or not port or not uuid:
        raise ProxyError("VMess 节点缺少服务器、端口或 UUID")
    outbound = {
        "type": "vmess",
        "tag": "telegram-node",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "security": str(data.get("scy", "auto") or "auto"),
        "alter_id": alter_id,
    }
    query = {
        "sni": [str(data.get("sni", ""))],
        "alpn": [str(data.get("alpn", ""))],
        "fp": [str(data.get("fp", ""))],
        "allowInsecure": [str(data.get("allowInsecure", ""))],
    }
    security = "tls" if str(data.get("tls", "")).lower() in ("tls", "1", "true") else ""
    tls = _build_tls(query, server, security)
    if tls:
        outbound["tls"] = tls
    transport = _build_transport(
        data.get("net", "tcp"),
        {},
        str(data.get("host", "")),
        str(data.get("path", "")),
    )
    if transport:
        outbound["transport"] = transport
    return outbound


def parse_shadowsocks_link(link):
    raw = link[len("ss://"):]
    raw = raw.split("#", 1)[0]
    main, separator, raw_query = raw.partition("?")
    if "@" not in main:
        main = _decode_base64(main)
    userinfo, marker, server_part = main.rpartition("@")
    if not marker:
        raise ProxyError("Shadowsocks 节点格式无效")
    userinfo = urllib.parse.unquote(userinfo)
    if ":" not in userinfo:
        userinfo = _decode_base64(userinfo)
    method, marker, password = userinfo.partition(":")
    if not marker or not method or not password:
        raise ProxyError("Shadowsocks 节点缺少加密方式或密码")
    parsed = urllib.parse.urlsplit("ss://placeholder@{}".format(server_part))
    server, port = _require_server(parsed)
    outbound = {
        "type": "shadowsocks",
        "tag": "telegram-node",
        "server": server,
        "server_port": port,
        "method": method,
        "password": urllib.parse.unquote(password),
    }
    query = urllib.parse.parse_qs(raw_query, keep_blank_values=True)
    plugin_spec = urllib.parse.unquote(_query_value(query, "plugin"))
    if plugin_spec:
        plugin_parts = plugin_spec.split(";")
        outbound["plugin"] = plugin_parts[0]
        if len(plugin_parts) > 1:
            outbound["plugin_opts"] = ";".join(plugin_parts[1:])
    return outbound


def parse_node_link(link):
    link = str(link or "").strip()
    scheme = urllib.parse.urlsplit(link).scheme.lower()
    if scheme == "vless":
        return parse_vless_link(link)
    if scheme == "vmess":
        return parse_vmess_link(link)
    if scheme == "ss":
        return parse_shadowsocks_link(link)
    raise ProxyError("节点链接必须以 vless://、vmess:// 或 ss:// 开头")


def _clean_display_label(value, limit=80):
    value = "".join(char if char.isprintable() else " " for char in str(value or ""))
    return " ".join(value.split())[:limit]


def _node_remark(link, outbound):
    parsed = urllib.parse.urlsplit(link)
    remark = _clean_display_label(urllib.parse.unquote(parsed.fragment))
    if not remark and outbound.get("type") == "vmess":
        encoded = link[len("vmess://"):].split("#", 1)[0].strip()
        try:
            data = json.loads(_decode_base64(encoded))
            if isinstance(data, dict):
                remark = _clean_display_label(data.get("ps"))
        except (ProxyError, ValueError):
            pass
    if remark:
        return remark
    server = _clean_display_label(outbound.get("server"))
    port = outbound.get("server_port")
    if ":" in server:
        server = "[{}]".format(server)
    return "{}:{}".format(server, port) if server and port else server


def describe_node_link(link):
    outbound = parse_node_link(link)
    remark = _node_remark(str(link or "").strip(), outbound)
    if remark:
        return "{} 节点（{}）".format(outbound["type"].upper(), remark)
    return "{} 节点".format(outbound["type"].upper())


def build_sing_box_config(node_link, listen_port):
    return {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [
            {
                "type": "socks",
                "tag": "telegram-in",
                "listen": "127.0.0.1",
                "listen_port": int(listen_port),
            }
        ],
        "outbounds": [parse_node_link(node_link)],
    }


def _architecture():
    machine = platform.machine().lower()
    mapping = {
        "x86_64": "amd64",
        "amd64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
        "armv7l": "armv7",
        "armv7": "armv7",
        "i386": "386",
        "i686": "386",
        "x86": "386",
    }
    architecture = mapping.get(machine)
    if not architecture:
        raise ProxyError("暂不支持当前 CPU 架构: {}".format(machine or "unknown"))
    return architecture


def find_sing_box():
    candidates = [
        os.environ.get("ALIYUN_GUARD_SING_BOX", ""),
        str(SING_BOX_BINARY),
        shutil.which("sing-box") or "",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _check_binary(path):
    try:
        result = subprocess.run(
            [str(path), "version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
            text=True,
        )
    except Exception as exc:
        raise ProxyError("无法执行 sing-box: {}".format(exc))
    if result.returncode != 0:
        raise ProxyError("sing-box 自检失败")


def install_sing_box(progress=None):
    existing = find_sing_box()
    if existing:
        _check_binary(existing)
        return existing
    if platform.system().lower() != "linux":
        raise ProxyError("自动安装 sing-box 仅支持 Linux")
    architecture = _architecture()
    asset_name, expected_sha256 = SING_BOX_ASSETS[architecture]
    url = "{}/{}".format(SING_BOX_RELEASE_BASE, asset_name)
    if progress:
        progress("正在下载官方 sing-box {} ({})...".format(SING_BOX_VERSION, architecture))
    APP_DIR.mkdir(parents=True, exist_ok=True)
    bin_dir = SING_BOX_BINARY.parent
    bin_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(str(bin_dir), 0o700)
    with tempfile.TemporaryDirectory(prefix="aliyun-guard-sing-box-") as directory:
        archive_path = Path(directory) / asset_name
        digest = hashlib.sha256()
        request = urllib.request.Request(url, headers={"User-Agent": "Aliyun-Guard-Installer"})
        try:
            with urllib.request.urlopen(request, timeout=90) as response, archive_path.open("wb") as handle:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                    handle.write(chunk)
        except Exception as exc:
            raise ProxyError("sing-box 下载失败: {}".format(exc))
        if digest.hexdigest() != expected_sha256:
            raise ProxyError("sing-box SHA-256 校验失败，已拒绝安装")
        try:
            with tarfile.open(str(archive_path), "r:gz") as archive:
                members = [
                    member for member in archive.getmembers()
                    if member.isfile() and Path(member.name).name == "sing-box"
                ]
                if len(members) != 1:
                    raise ProxyError("sing-box 压缩包结构无效")
                source = archive.extractfile(members[0])
                if source is None:
                    raise ProxyError("无法读取 sing-box 可执行文件")
                temporary_binary = bin_dir / "sing-box.tmp"
                with temporary_binary.open("wb") as target:
                    shutil.copyfileobj(source, target)
                    target.flush()
                    os.fsync(target.fileno())
                os.chmod(str(temporary_binary), 0o700)
                os.replace(str(temporary_binary), str(SING_BOX_BINARY))
        except ProxyError:
            raise
        except Exception as exc:
            raise ProxyError("sing-box 解压失败: {}".format(exc))
    _check_binary(SING_BOX_BINARY)
    return str(SING_BOX_BINARY)


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def _read_log(directory):
    if not directory:
        return ""
    path = Path(directory) / "sing-box.log"
    try:
        return path.read_text(encoding="utf-8", errors="replace")[-1200:].strip()
    except OSError:
        return ""


def _terminate_process(process):
    if process is None:
        return
    try:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def _cleanup_runtime(process=None, log_handle=None, directory=None):
    try:
        _terminate_process(process)
    finally:
        if log_handle is not None:
            try:
                log_handle.close()
            except OSError:
                pass
        if directory:
            shutil.rmtree(directory, ignore_errors=True)


def stop_node_proxy():
    global _PROCESS, _PROCESS_KEY, _PROCESS_PROXY_URL, _PROCESS_DIR, _PROCESS_LOG
    with _PROCESS_LOCK:
        process = _PROCESS
        log_handle = _PROCESS_LOG
        directory = _PROCESS_DIR
        _PROCESS = None
        _PROCESS_KEY = None
        _PROCESS_PROXY_URL = None
        _PROCESS_DIR = None
        _PROCESS_LOG = None
        _cleanup_runtime(process, log_handle, directory)


def ensure_node_proxy(node_link, startup_timeout=12):
    global _PROCESS, _PROCESS_KEY, _PROCESS_PROXY_URL, _PROCESS_DIR, _PROCESS_LOG
    node_link = str(node_link or "").strip()
    key = hashlib.sha256(node_link.encode("utf-8")).hexdigest()
    with _PROCESS_LOCK:
        if _PROCESS is not None and _PROCESS.poll() is None and _PROCESS_KEY == key:
            return _PROCESS_PROXY_URL
        stop_node_proxy()
        binary = find_sing_box()
        if not binary:
            raise ProxyError("未安装 sing-box，请在 Telegram 连接设置中重新测试并安装")
        port = _free_port()
        config = build_sing_box_config(node_link, port)
        runtime_root = APP_DIR / "runtime"
        runtime_root.mkdir(parents=True, exist_ok=True)
        os.chmod(str(runtime_root), 0o700)
        directory = None
        log_handle = None
        process = None
        managed = False
        try:
            directory = tempfile.mkdtemp(prefix="telegram-node-", dir=str(runtime_root))
            os.chmod(directory, 0o700)
            config_path = Path(directory) / "config.json"
            config_path.write_text(
                json.dumps(config, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            os.chmod(str(config_path), 0o600)
            try:
                check = subprocess.run(
                    [binary, "check", "-c", str(config_path)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=15,
                    check=False,
                    text=True,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                raise ProxyError("无法执行 sing-box 节点配置校验") from exc
            if check.returncode != 0:
                raise ProxyError("sing-box 节点配置校验失败")
            log_path = Path(directory) / "sing-box.log"
            log_handle = log_path.open("a", encoding="utf-8")
            os.chmod(str(log_path), 0o600)
            try:
                process = subprocess.Popen(
                    [binary, "run", "-c", str(config_path)],
                    stdin=subprocess.DEVNULL,
                    stdout=log_handle,
                    stderr=subprocess.STDOUT,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                raise ProxyError("无法启动 sing-box 进程") from exc
            deadline = time.monotonic() + max(3, startup_timeout)
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    break
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                        _PROCESS = process
                        _PROCESS_KEY = key
                        _PROCESS_PROXY_URL = "socks5h://127.0.0.1:{}".format(port)
                        _PROCESS_DIR = directory
                        _PROCESS_LOG = log_handle
                        managed = True
                        return _PROCESS_PROXY_URL
                except OSError:
                    time.sleep(0.15)
            _terminate_process(process)
            detail = _read_log(directory)
            if detail:
                raise ProxyError("sing-box 启动失败: {}".format(detail))
            raise ProxyError("sing-box 启动失败或本地代理端口未就绪")
        finally:
            if not managed:
                _cleanup_runtime(process, log_handle, directory)


atexit.register(stop_node_proxy)
