#!/usr/bin/env python3
"""Build a self-contained shell installer from the maintained source files."""

import argparse
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "packaging" / "install.template.sh"
PAYLOADS = [
    (ROOT / "src" / "aliyun_guard.py", "aliyun_guard.py", "__AG_APP_PY_EOF__"),
    (ROOT / "src" / "manager.py", "manager.py", "__AG_MANAGER_PY_EOF__"),
    (ROOT / "src" / "control.sh", "control.sh", "__AG_CONTROL_SH_EOF__"),
    (ROOT / "src" / "uninstall.sh", "uninstall.sh", "__AG_UNINSTALL_SH_EOF__"),
]


def build(output):
    template = TEMPLATE.read_text(encoding="utf-8")
    marker = "# __PAYLOAD_BLOCKS__"
    if template.count(marker) != 1:
        raise RuntimeError("installer template must contain exactly one payload marker")
    blocks = []
    for source, target_name, delimiter in PAYLOADS:
        content = source.read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n")
        if delimiter in content:
            raise RuntimeError("payload delimiter appears in {}".format(source))
        blocks.append(
            "    cat > \"$APP_DIR/{}\" <<'{}'\n{}\n{}".format(
                target_name, delimiter, content, delimiter
            )
        )
    rendered = template.replace(marker, "\n".join(blocks)).replace("\r\n", "\n")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered)
    digest = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    checksum = output.with_name(output.name + ".sha256")
    with checksum.open("w", encoding="ascii", newline="\n") as handle:
        handle.write("{}  {}\n".format(digest, output.name))
    print("built {} (sha256 {})".format(output, digest))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.output.resolve())


if __name__ == "__main__":
    main()
