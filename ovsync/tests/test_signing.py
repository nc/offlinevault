import base64
import json

import pytest

from ovsync.errors import VerificationFailed
from ovsync.manifest import parse_manifest
from ovsync.signing import CATALOGUE_KEYS, MANIFEST_FORMAT, Envelope, Keyring

from conftest import CORE_KEY, manifest_payload, ovsync, sign, signed_manifest_path


@pytest.fixture
def signed_v2() -> bytes:
    if not signed_manifest_path(2).exists():
        pytest.skip("no fixture manifest")
    return signed_manifest_path(2).read_bytes()


def test_dev_signed_fixture_manifest_verifies(signed_v2, dev_public_key):
    payload, key_id = Keyring({"dev-2026": dev_public_key}).open(Envelope.from_json(signed_v2), MANIFEST_FORMAT)
    assert key_id == "dev-2026"
    manifest = parse_manifest(payload)
    assert manifest.version == "2026.10.08"
    assert {a.id for a in manifest.artefacts} >= {"catalogue", "zim-fieldguide-2026-10", "zim-fieldguide-full"}


def test_one_altered_payload_byte_is_rejected(signed_v2, dev_public_key):
    envelope = json.loads(signed_v2)
    payload = bytearray(base64.b64decode(envelope["payload"]))
    payload[len(payload) // 2] ^= 0x01
    envelope["payload"] = base64.b64encode(bytes(payload)).decode()
    with pytest.raises(VerificationFailed, match="signature does not match"):
        Keyring({"dev-2026": dev_public_key}).open(Envelope.from_json(json.dumps(envelope).encode()), MANIFEST_FORMAT)


def test_wrong_key_id_is_rejected(signed_v2, dev_public_key):
    envelope = json.loads(signed_v2)
    envelope["keyId"] = "content-2026-10"
    with pytest.raises(VerificationFailed, match="signature does not match"):
        Keyring(CATALOGUE_KEYS).open(Envelope.from_json(json.dumps(envelope).encode()), MANIFEST_FORMAT)
    envelope["keyId"] = "nobody"
    with pytest.raises(VerificationFailed, match="does not trust"):
        Keyring({"dev-2026": dev_public_key}).open(Envelope.from_json(json.dumps(envelope).encode()), MANIFEST_FORMAT)


def test_production_key_never_vouches_for_the_dev_signature(signed_v2):
    with pytest.raises(VerificationFailed, match="does not trust"):
        Keyring(CATALOGUE_KEYS).open(Envelope.from_json(signed_v2), MANIFEST_FORMAT)


def test_unsigned_or_wrong_format_is_rejected(signed_v2, dev_public_key, dev_private_key):
    with pytest.raises(VerificationFailed, match="no signature"):
        Envelope.from_json(json.dumps(manifest_payload(2)).encode())
    licence_shaped = sign(b"{}", dev_private_key, format="offlinevault-licence/2")
    with pytest.raises(VerificationFailed, match="unsupported format"):
        Keyring({"dev-2026": dev_public_key}).open(Envelope.from_json(licence_shaped), MANIFEST_FORMAT)


def test_replayed_older_catalogue_is_refused(server, config_dir):
    server.serve(version=2)
    assert ovsync("list", origin=server.origin).returncode == 0
    server.serve(version=1)
    result = ovsync("list", origin=server.origin)
    assert result.returncode == 3
    assert "older than the one already accepted" in result.stderr
    server.serve(version=2)
    assert ovsync("list", origin=server.origin).returncode == 0


def test_list_prints_every_tier_and_marks_coverage(server, config_dir):
    server.serve(version=2)
    result = ovsync("activate", CORE_KEY, origin=server.origin)
    assert result.returncode == 0, result.stderr
    out = ovsync("list", origin=server.origin).stdout
    assert "verified with key dev-2026" in out
    assert "* zim-fieldguide-2026-10" in out
    assert "  zim-fieldguide-full" in out and "full (1 artefacts" in out and "not in your plan" in out
