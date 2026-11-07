"""Ed25519 envelopes in the shape the app's LicenceFile/SignedEnvelope reads.

The signed bytes are whatever the caller hands over. For a manifest that is the exact JSON the publisher wrote
(`canonical`), and the client verifies those bytes without re-encoding, so there is no cross-language canonical
form to agree on. Key files hold a base64 raw 32-byte seed, as `licencetool keygen` writes them.

    python -m ovpub.sign --key FILE --key-id ID [--format F] IN.json --out OUT.json
"""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

MANIFEST_FORMAT = "offlinevault-manifest/1"
LICENCE_FORMAT = "offlinevault-licence/2"


class BadSignature(ValueError):
    pass


def canonical(obj: object) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def read_key(path: Path) -> bytes:
    raw = base64.b64decode(Path(path).read_text().strip())
    if len(raw) != 32:
        raise ValueError(f"{path}: not a 32-byte Ed25519 key")
    return raw


def public_key_b64(seed: bytes) -> str:
    from cryptography.hazmat.primitives import serialization
    pub = Ed25519PrivateKey.from_private_bytes(seed).public_key()
    return base64.b64encode(pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()


def sign(payload: bytes, seed: bytes, key_id: str, fmt: str = MANIFEST_FORMAT) -> dict:
    sig = Ed25519PrivateKey.from_private_bytes(seed).sign(payload)
    return {"format": fmt, "keyId": key_id, "payload": base64.b64encode(payload).decode(), "signature": base64.b64encode(sig).decode()}


def verify(envelope: dict, public_b64: str, fmt: str = MANIFEST_FORMAT, key_id: str | None = None) -> bytes:
    """Returns the payload bytes, or raises BadSignature naming what failed (format, key id, base64, signature)."""
    if envelope.get("format") != fmt:
        raise BadSignature(f"format {envelope.get('format')!r}, expected {fmt!r}")
    if key_id is not None and envelope.get("keyId") != key_id:
        raise BadSignature(f"signed with key {envelope.get('keyId')!r}, expected {key_id!r}")
    try:
        payload = base64.b64decode(envelope["payload"], validate=True)
        sig = base64.b64decode(envelope["signature"], validate=True)
        pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_b64))
    except (KeyError, ValueError) as e:
        raise BadSignature(f"malformed envelope: {e}") from e
    try:
        pub.verify(sig, payload)
    except InvalidSignature as e:
        raise BadSignature("signature does not match the payload") from e
    return payload


def envelope_bytes(envelope: dict) -> bytes:
    return (json.dumps(envelope, indent=2, sort_keys=True) + "\n").encode()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("payload", help="JSON file whose bytes (re-encoded compact, sorted) are signed")
    ap.add_argument("--key", required=True)
    ap.add_argument("--key-id", required=True)
    ap.add_argument("--format", default=MANIFEST_FORMAT)
    ap.add_argument("--raw", action="store_true", help="sign the file bytes as they are instead of re-encoding")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    data = Path(a.payload).read_bytes()
    payload = data if a.raw else canonical(json.loads(data))
    Path(a.out).write_bytes(envelope_bytes(sign(payload, read_key(Path(a.key)), a.key_id, a.format)))
    print(f"wrote {a.out} ({a.format}, key {a.key_id}, {len(payload)} payload bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
