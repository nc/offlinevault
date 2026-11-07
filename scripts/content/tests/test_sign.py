import base64
import json
import subprocess
import sys
from pathlib import Path

import pytest

from ovpub import sign

ROOT = Path(__file__).resolve().parents[3]
DEV_PRIVATE = ROOT / "scripts/dev-keys/licence-private.key"
DEV_PUBLIC = ROOT / "scripts/dev-keys/licence-public.key"
LICENCETOOL = ROOT / "Core/.build/debug/licencetool"


def test_round_trip_with_dev_key():
    seed = sign.read_key(DEV_PRIVATE)
    payload = sign.canonical({"version": "2026.10.20", "artefacts": [], "publishedAt": "2026-10-20T00:00:00Z", "catalogueVersion": "2026.10.20"})
    env = sign.sign(payload, seed, "dev-2026")
    assert env["format"] == "offlinevault-manifest/1" and env["keyId"] == "dev-2026"
    assert sign.verify(env, DEV_PUBLIC.read_text().strip(), key_id="dev-2026") == payload
    assert sign.public_key_b64(seed) == DEV_PUBLIC.read_text().strip()


def test_canonical_is_compact_sorted_utf8():
    assert sign.canonical({"b": 1, "a": "é/x"}) == '{"a":"é/x","b":1}'.encode()


def test_tampered_payload_wrong_key_and_wrong_format_are_rejected():
    seed = sign.read_key(DEV_PRIVATE)
    pub = DEV_PUBLIC.read_text().strip()
    env = sign.sign(b'{"a":1}', seed, "dev-2026")
    bad = dict(env, payload=base64.b64encode(b'{"a":2}').decode())
    with pytest.raises(sign.BadSignature, match="does not match"):
        sign.verify(bad, pub)
    with pytest.raises(sign.BadSignature, match="format"):
        sign.verify(dict(env, format="offlinevault-licence/2"), pub)
    with pytest.raises(sign.BadSignature, match="expected"):
        sign.verify(env, pub, key_id="content-2026-10")
    other = sign.public_key_b64(b"\x01" * 32)
    with pytest.raises(sign.BadSignature):
        sign.verify(env, other)


@pytest.mark.skipif(not LICENCETOOL.exists(), reason="build with: cd Core && swift build --product licencetool")
def test_swift_accepts_a_licence_envelope_signed_by_this_signer(tmp_path):
    """Same primitive, same envelope shape: a licence-format payload signed here must pass the app's own verifier."""
    payload = sign.canonical({"licenceId": "py-0001", "subscriber": "Signer Proof", "plan": "core", "seats": 1,
                              "issuedAt": "2026-10-01T00:00:00Z", "expiresAt": "2099-01-01T00:00:00Z"})
    env = sign.sign(payload, sign.read_key(DEV_PRIVATE), "dev-2026", fmt=sign.LICENCE_FORMAT)
    good = tmp_path / "good.json"
    good.write_bytes(sign.envelope_bytes(env))
    r = subprocess.run([str(LICENCETOOL), "verify", "--pubkey", f"dev-2026={DEV_PUBLIC}", str(good)], capture_output=True, text=True)
    assert r.returncode == 0 and "Core plan for Signer Proof" in r.stdout, r.stdout + r.stderr

    tampered = dict(env, payload=base64.b64encode(payload.replace(b"core", b"drive")).decode())
    bad = tmp_path / "bad.json"
    bad.write_bytes(sign.envelope_bytes(tampered))
    r = subprocess.run([str(LICENCETOOL), "verify", "--pubkey", f"dev-2026={DEV_PUBLIC}", str(bad)], capture_output=True, text=True)
    assert r.returncode == 1 and "signature does not match" in r.stdout, r.stdout + r.stderr


def test_cli_writes_envelope(tmp_path):
    src = tmp_path / "m.json"
    src.write_text(json.dumps({"version": "1", "artefacts": []}, indent=2))
    out = tmp_path / "m.signed.json"
    r = subprocess.run([sys.executable, "-m", "ovpub.sign", str(src), "--key", str(DEV_PRIVATE), "--key-id", "dev-2026", "--out", str(out)],
                       capture_output=True, text=True, cwd=ROOT / "scripts/content")
    assert r.returncode == 0, r.stderr
    env = json.loads(out.read_text())
    assert sign.verify(env, DEV_PUBLIC.read_text().strip()) == sign.canonical({"version": "1", "artefacts": []})
