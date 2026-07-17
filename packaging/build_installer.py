#!/usr/bin/env python3
"""Build a self-contained shell installer from the maintained source files."""

import argparse
import ast
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "packaging" / "install.template.sh"
PAYLOADS = [
    (ROOT / "src" / "telegram_proxy.py", "telegram_proxy.py", "__AG_PROXY_PY_EOF__"),
    (ROOT / "src" / "telegram_control.py", "telegram_control.py", "__AG_CONTROL_PY_EOF__"),
    (ROOT / "src" / "web_actions.py", "web_actions.py", "__AG_WEB_ACTIONS_PY_EOF__"),
    (ROOT / "src" / "web_panel.py", "web_panel.py", "__AG_WEB_PY_EOF__"),
    (ROOT / "src" / "web_panel.html", "web_panel.html", "__AG_WEB_HTML_EOF__"),
    (ROOT / "src" / "aliyun_guard.py", "aliyun_guard.py", "__AG_APP_PY_EOF__"),
    (ROOT / "src" / "manager.py", "manager.py", "__AG_MANAGER_PY_EOF__"),
    (ROOT / "src" / "control.sh", "control.sh", "__AG_CONTROL_SH_EOF__"),
    (ROOT / "src" / "uninstall.sh", "uninstall.sh", "__AG_UNINSTALL_SH_EOF__"),
]
RELEASE_MARKER = "__AG_RELEASE_ID__"


def normalize_text(path):
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def calculate_release_id(template, payloads):
    digest = hashlib.sha256()
    digest.update(b"aliyun-guard-release-v1\0")
    materials = [("install.template.sh", template)] + [
        (target_name, content) for _source, target_name, _delimiter, content in payloads
    ]
    for name, content in materials:
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(content.encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def read_app_version(manager_source):
    tree = ast.parse(manager_source, filename="manager.py")
    for node in tree.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1:
            continue
        target = node.targets[0]
        if isinstance(target, ast.Name) and target.id == "APP_VERSION":
            value = ast.literal_eval(node.value)
            if isinstance(value, str) and value:
                return value
    raise RuntimeError("manager.py must define a non-empty APP_VERSION string")


def build(output):
    template = normalize_text(TEMPLATE)
    marker = "# __PAYLOAD_BLOCKS__"
    if template.count(marker) != 1:
        raise RuntimeError("installer template must contain exactly one payload marker")
    payloads = []
    for source, target_name, delimiter in PAYLOADS:
        payloads.append((source, target_name, delimiter, normalize_text(source).rstrip("\n")))
    manager_source = next(
        content for _source, name, _delimiter, content in payloads if name == "manager.py"
    )
    app_version = read_app_version(manager_source)
    release_id = calculate_release_id(template, payloads)
    blocks = []
    for source, target_name, delimiter, content in payloads:
        if delimiter in content:
            raise RuntimeError("payload delimiter appears in {}".format(source))
        blocks.append(
            "    cat > \"$APP_DIR/{}\" <<'{}'\n{}\n{}".format(
                target_name, delimiter, content, delimiter
            )
        )
    rendered = template.replace(marker, "\n".join(blocks))
    if rendered.count(RELEASE_MARKER) != 1:
        raise RuntimeError("manager payload must contain exactly one release marker")
    rendered = rendered.replace(RELEASE_MARKER, release_id)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered)
    digest = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    checksum = output.with_name(output.name + ".sha256")
    with checksum.open("w", encoding="ascii", newline="\n") as handle:
        handle.write("{}  {}\n".format(digest, output.name))
    manifest = output.with_name("version.json")
    manifest_data = {
        "version": app_version,
        "release_id": release_id,
    }
    with manifest.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest_data, handle, ensure_ascii=True, indent=2)
        handle.write("\n")
    print("built {} (version {}, release {}, sha256 {})".format(
        output, manifest_data["version"], release_id, digest
    ))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.output.resolve())


if __name__ == "__main__":
    main()
