import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import manager


class DockerArtifactTests(unittest.TestCase):
    @staticmethod
    def shell_path():
        shell = shutil.which("sh")
        if shell is None and os.name == "nt":
            candidate = (
                Path(os.environ.get("ProgramFiles", "C:/Program Files"))
                / "Git/bin/sh.exe"
            )
            if candidate.exists():
                shell = str(candidate)
        return shell

    @staticmethod
    def shell_environment(shell):
        environment = dict(os.environ)
        if os.name == "nt":
            existing_path = ""
            for key in list(environment):
                if key.lower() == "path":
                    existing_path = existing_path or environment.pop(key)
            git_root = Path(shell).resolve().parent.parent
            environment["PATH"] = os.pathsep.join(
                (
                    str(git_root / "usr/bin"),
                    str(git_root / "bin"),
                    existing_path,
                )
            )
        environment["ALIYUN_GUARD_DOCKER_INSTALL_LIB_ONLY"] = "1"
        return environment

    def test_docker_versions_match_application(self):
        dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        self.assertIn("ARG APP_VERSION={}".format(manager.APP_VERSION), dockerfile)
        self.assertIn(
            'APP_VERSION: "{}"'.format(manager.APP_VERSION), compose
        )
        self.assertIn("aliyun-guard:{}".format(manager.APP_VERSION), compose)

    def test_image_uses_runtime_sources_without_baking_configuration(self):
        dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("FROM python:3.11-slim-bookworm", dockerfile)
        self.assertIn("COPY src/web_actions.py", dockerfile)
        self.assertIn("src/telegram_control.py", dockerfile)
        self.assertIn("src/backup_manager.py", dockerfile)
        self.assertIn("src/s3_backup.py", dockerfile)
        self.assertIn("src/watchdog.py", dockerfile)
        requirements = (ROOT / "requirements.txt").read_text(encoding="utf-8")
        self.assertIn("boto3>=1.34,<2", requirements)
        self.assertIn("COPY version.json ./version.json", dockerfile)
        self.assertIn("ENTRYPOINT", dockerfile)
        self.assertNotIn("COPY config.json", dockerfile)
        self.assertNotIn("COPY state.json", dockerfile)
        self.assertIn('VOLUME ["/data", "/opt/aliyun-guard/bin"]', dockerfile)

    def test_compose_new_install_is_public_and_legacy_fallback_is_loopback(self):
        compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        env_example = (ROOT / ".env.example").read_text(encoding="utf-8")
        self.assertIn("restart: unless-stopped", compose)
        self.assertIn(
            '"${ALIYUN_GUARD_BIND_IP:-127.0.0.1}:${ALIYUN_GUARD_WEB_PORT:-8765}:8765"',
            compose,
        )
        self.assertIn("ALIYUN_GUARD_BIND_IP=0.0.0.0", env_example)
        self.assertIn('ALIYUN_GUARD_PUBLIC_IP: "${ALIYUN_GUARD_PUBLIC_IP:-}"', compose)
        self.assertIn("ALIYUN_GUARD_HOST_BIND_IP:", compose)
        self.assertIn("ALIYUN_GUARD_PUBLIC_WEB_PORT:", compose)
        self.assertIn("./docker-data:/data", compose)
        self.assertIn("aliyun-guard-bin:/opt/aliyun-guard/bin", compose)
        self.assertIn("no-new-privileges:true", compose)
        self.assertIn("cap_drop:", compose)

    def test_docker_dependencies_match_linux_installer(self):
        requirements = {
            line.strip()
            for line in (ROOT / "requirements.txt").read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
        installer = (ROOT / "packaging" / "install.template.sh").read_text(
            encoding="utf-8"
        )
        for requirement in requirements:
            self.assertIn("'{}'".format(requirement), installer)

    def test_entrypoint_supports_setup_and_normalizes_web_listener(self):
        entrypoint = (ROOT / "docker" / "entrypoint.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("docker compose run --rm aliyun-guard setup", entrypoint)
        self.assertIn('web["host"] = "0.0.0.0"', entrypoint)
        self.assertIn("normalize_web_panel", entrypoint)
        self.assertIn("detect_public_ip", entrypoint)
        self.assertIn("Docker 网页面板访问地址", entrypoint)
        self.assertIn("exec \"$PYTHON\" \"$APP_DIR/aliyun_guard.py\" daemon", entrypoint)

    def test_one_click_installer_preserves_data_and_uses_interactive_setup(self):
        installer = (ROOT / "docker-install.sh").read_text(encoding="utf-8")
        self.assertIn("/opt/aliyun-guard-docker", installer)
        self.assertIn("exec 3</dev/tty", installer)
        self.assertIn('compose run --rm aliyun-guard setup <&3', installer)
        self.assertIn('compose up -d --remove-orphans --force-recreate', installer)
        self.assertIn('if [ ! -f "$INSTALL_DIR/.env" ]', installer)
        self.assertIn('if [ -s "$INSTALL_DIR/docker-data/config.json" ]', installer)
        self.assertIn('ALIYUN_GUARD_BIND_IP=127.0.0.1', installer)
        self.assertIn('mkdir -p "$INSTALL_DIR/docker-data/logs"', installer)
        self.assertIn(
            "aliyun-guard-bin",
            (ROOT / "docker-compose.yml").read_text(encoding="utf-8"),
        )
        self.assertNotIn('rm -rf "$INSTALL_DIR"', installer)

    def test_one_click_installer_supports_docker_install_and_compose_fallback(self):
        installer = (ROOT / "docker-install.sh").read_text(encoding="utf-8")
        for package_manager in ("apt", "dnf", "yum", "apk", "pacman", "zypper"):
            self.assertIn("{})".format(package_manager), installer)
        self.assertIn('docker compose "$@"', installer)
        self.assertIn('docker-compose "$@"', installer)
        self.assertIn('https://get.docker.com', installer)
        self.assertIn('migrate_native_installation', installer)
        self.assertIn('--update 要求已有', installer)

    def test_one_click_installer_path_and_port_guards(self):
        shell = self.shell_path()
        if shell is None:
            self.skipTest("POSIX sh is unavailable")
        environment = self.shell_environment(shell)
        command = (
            '. ./docker-install.sh; '
            'validate_source_ref; '
            'validate_install_dir /opt/aliyun-guard-docker; '
            'valid_port 8765; '
            '! validate_install_dir /; '
            '! validate_install_dir relative/path; '
            '! valid_port 70000'
        )
        subprocess.run(
            [shell, "-c", command],
            cwd=str(ROOT),
            env=environment,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

    def test_one_click_installer_help_needs_no_root_or_network(self):
        shell = self.shell_path()
        if shell is None:
            self.skipTest("POSIX sh is unavailable")
        environment = self.shell_environment(shell)
        environment.pop("ALIYUN_GUARD_DOCKER_INSTALL_LIB_ONLY", None)
        result = subprocess.run(
            [shell, "docker-install.sh", "--help"],
            cwd=str(ROOT),
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("用法: docker-install.sh [--update]", result.stdout)

    def test_one_click_source_update_preserves_env_and_data(self):
        shell = self.shell_path()
        if shell is None:
            self.skipTest("POSIX sh is unavailable")
        output_dir = ROOT / "output"
        output_dir.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=str(output_dir)) as directory:
            root = Path(directory)
            source = root / "source"
            install = root / "install"
            (source / "src").mkdir(parents=True)
            (source / "docker").mkdir()
            for name in (
                "Dockerfile",
                "docker-compose.yml",
                "requirements.txt",
                "version.json",
                "README.md",
                "docker-install.sh",
                ".dockerignore",
                ".env.example",
            ):
                (source / name).write_text(
                    "ALIYUN_GUARD_BIND_IP=0.0.0.0\n"
                    if name == ".env.example"
                    else name,
                    encoding="utf-8",
                )
            (source / "src" / "new.py").write_text("new", encoding="utf-8")
            (source / "docker" / "entrypoint.sh").write_text(
                "new", encoding="utf-8"
            )
            (install / "docker-data").mkdir(parents=True)
            (install / ".env").write_text("KEEP_ENV=1\n", encoding="utf-8")
            (install / "docker-data" / "config.json").write_text(
                '{"keep": true}\n', encoding="utf-8"
            )
            (install / "src").mkdir()
            (install / "src" / "old.py").write_text("old", encoding="utf-8")
            environment = self.shell_environment(shell)
            command = (
                '. ./docker-install.sh; '
                'INSTALL_DIR="$1"; SOURCE_DIR="$2"; install_source'
            )
            result = subprocess.run(
                [
                    shell,
                    "-c",
                    command,
                    "sh",
                    install.relative_to(ROOT).as_posix(),
                    source.relative_to(ROOT).as_posix(),
                ],
                cwd=str(ROOT),
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (install / ".env").read_text(encoding="utf-8"), "KEEP_ENV=1\n"
            )
            self.assertEqual(
                (install / "docker-data" / "config.json").read_text(encoding="utf-8"),
                '{"keep": true}\n',
            )
            self.assertTrue((install / "src" / "new.py").exists())
            self.assertFalse((install / "src" / "old.py").exists())
            (install / ".env").unlink()
            result = subprocess.run(
                [
                    shell,
                    "-c",
                    command,
                    "sh",
                    install.relative_to(ROOT).as_posix(),
                    source.relative_to(ROOT).as_posix(),
                ],
                cwd=str(ROOT),
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                "ALIYUN_GUARD_BIND_IP=127.0.0.1",
                (install / ".env").read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
