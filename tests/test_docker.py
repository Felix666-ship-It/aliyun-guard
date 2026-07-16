from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import manager


class DockerArtifactTests(unittest.TestCase):
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
        self.assertIn("COPY version.json ./version.json", dockerfile)
        self.assertIn("ENTRYPOINT", dockerfile)
        self.assertNotIn("COPY config.json", dockerfile)
        self.assertNotIn("COPY state.json", dockerfile)
        self.assertIn('VOLUME ["/data", "/opt/aliyun-guard/bin"]', dockerfile)

    def test_compose_persists_data_and_defaults_to_loopback(self):
        compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        self.assertIn("restart: unless-stopped", compose)
        self.assertIn(
            '"127.0.0.1:${ALIYUN_GUARD_WEB_PORT:-8765}:8765"', compose
        )
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
        self.assertIn("exec \"$PYTHON\" \"$APP_DIR/aliyun_guard.py\" daemon", entrypoint)


if __name__ == "__main__":
    unittest.main()
