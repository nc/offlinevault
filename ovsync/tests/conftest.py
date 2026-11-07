from __future__ import annotations

import base64
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

TESTS = Path(__file__).resolve().parent
PACKAGE_ROOT = TESTS.parent
REPO = TESTS.parents[1]
# The tree these tests live in, ahead of any `pip install -e` of another checkout (a worktree would otherwise test main).
sys.path.insert(0, str(PACKAGE_ROOT))
FIXTURE_OUT = Path(os.environ.get("OV_FIXTURE_OUT", REPO / "fixture" / "out"))
LICENCES = REPO / "fixture"
DEV_KEYS = REPO / "scripts" / "dev-keys"
FIXTURE_SERVER = REPO / "scripts" / "fixture_server.py"
CORE_KEY = "OV-DEVC-2222-2222-2222"
REQUEST_LINE = re.compile(r'"(GET|POST) (\S+) HTTP/[\d.]+" (\d{3})')


def signed_manifest_path(version: int) -> Path:
    return FIXTURE_OUT / f"manifest.v{version}.signed.json"


def manifest_payload(version: int) -> dict:
    return json.loads(base64.b64decode(json.loads(signed_manifest_path(version).read_text())["payload"]))


@pytest.fixture(scope="session")
def dev_public_key() -> str:
    return (DEV_KEYS / "licence-public.key").read_text().strip()


@pytest.fixture(scope="session")
def dev_private_key() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(base64.b64decode((DEV_KEYS / "licence-private.key").read_text().strip()))


def sign(payload: bytes, private_key: Ed25519PrivateKey, key_id: str | None = "dev-2026", format: str = "offlinevault-manifest/1") -> bytes:
    return json.dumps({"format": format, "keyId": key_id, "payload": base64.b64encode(payload).decode(),
                       "signature": base64.b64encode(private_key.sign(payload)).decode()}).encode()


@pytest.fixture
def config_dir(tmp_path, monkeypatch, dev_public_key) -> Path:
    directory = tmp_path / "config"
    monkeypatch.setenv("OVSYNC_CONFIG_DIR", str(directory))
    monkeypatch.setenv("OVSYNC_CATALOGUE_KEYS", f"dev-2026={dev_public_key}")
    monkeypatch.setenv("OVSYNC_LICENCE_KEYS", f"dev-2026={dev_public_key}")
    return directory


class Server:
    def __init__(self, root: Path, log: Path, port: int):
        self.root, self.log, self.port = root, log, port
        self.process: subprocess.Popen | None = None
        self.log_handle = None

    @property
    def origin(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def serve(self, version: int | None = 2, manifest: bytes | None = None) -> "Server":
        self.stop()
        updates = self.root / "updates"
        if not updates.exists():
            updates.mkdir()
            for entry in FIXTURE_OUT.iterdir():
                if not entry.name.startswith("manifest."):
                    (updates / entry.name).symlink_to(entry)
        target = updates / "manifest.json"
        target.unlink(missing_ok=True)
        if manifest is not None:
            target.write_bytes(manifest)
        else:
            target.symlink_to(signed_manifest_path(version))
        self.log_handle = open(self.log, "ab")
        self.process = subprocess.Popen(
            [sys.executable, str(FIXTURE_SERVER), "--root", str(self.root), "--port", str(self.port), "--licences", str(LICENCES)],
            stdout=self.log_handle, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), 1).close()
                return self
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("fixture server did not start")

    def stop(self) -> None:
        if self.process:
            self.process.terminate()
            self.process.wait(10)
            self.process = None
            self.log_handle.close()

    def requests(self, path_fragment: str) -> list[tuple[str, str, str]]:
        out = []
        for line in self.log.read_text().splitlines():
            m = REQUEST_LINE.search(line)
            if m and path_fragment in m[2]:
                out.append((m[1], m[2], m[3]))
        return out


@pytest.fixture
def server(tmp_path) -> Server:
    if not signed_manifest_path(2).exists():
        pytest.skip(f"no fixture at {FIXTURE_OUT}; run scripts/make_fixture_server.sh or set OV_FIXTURE_OUT")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    srv = Server(tmp_path / "server-root", tmp_path / "server.log", port)
    srv.root.mkdir()
    try:
        yield srv
    finally:
        srv.stop()


def ovsync(*args: str, origin: str | None = None) -> subprocess.CompletedProcess:
    argv = [sys.executable, "-m", "ovsync.cli", *args]
    if origin:
        argv += ["--origin", origin]
    return subprocess.run(argv, capture_output=True, text=True, cwd=TESTS, env={**os.environ, "PYTHONPATH": str(PACKAGE_ROOT)})
