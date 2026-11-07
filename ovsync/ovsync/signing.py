"""Wire format: Core/Sources/OfflineVaultCore/Signing/SignedEnvelope.swift."""
from __future__ import annotations

import base64
import json
import os
from dataclasses import dataclass

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from .errors import OvsyncError, VerificationFailed

MANIFEST_FORMAT = "offlinevault-manifest/1"
LICENCE_FORMAT = "offlinevault-licence/2"

# Must match Core/Sources/OfflineVaultCore/Config.swift.
CATALOGUE_KEYS = {"content-2026-10": "1O0FL/5hswGi0rSwLEeeyLagHiQRrYDsygaY4yW6QF4="}
LICENCE_KEYS = {"prod-2026-10": "8h7YxMEMfZYxgvZC3XxVxeiJdEW8/ogs00YTCxzk3iQ="}


@dataclass(frozen=True)
class Envelope:
    format: str
    key_id: str | None
    payload: bytes
    signature: bytes

    @classmethod
    def from_json(cls, data: bytes) -> "Envelope":
        try:
            obj = json.loads(data)
        except ValueError:
            raise VerificationFailed("the file is not JSON")
        return cls.from_object(obj)

    @classmethod
    def from_object(cls, obj: object) -> "Envelope":
        if not isinstance(obj, dict) or not ("format" in obj or "signature" in obj):
            raise VerificationFailed("the file carries no signature")
        try:
            key_id = obj.get("keyId")
            return cls(
                format=str(obj["format"]),
                key_id=None if key_id is None else str(key_id),
                payload=base64.b64decode(obj["payload"], validate=True),
                signature=base64.b64decode(obj["signature"], validate=True),
            )
        except (KeyError, TypeError, ValueError):
            raise VerificationFailed("the signed envelope is malformed")

    def to_object(self) -> dict:
        return {
            "format": self.format,
            "keyId": self.key_id,
            "payload": base64.b64encode(self.payload).decode(),
            "signature": base64.b64encode(self.signature).decode(),
        }


class Keyring:
    def __init__(self, keys: dict[str, str]):
        self.keys: dict[str, Ed25519PublicKey] = {}
        for key_id, b64 in keys.items():
            raw = base64.b64decode(b64)
            if len(raw) != 32:
                raise ValueError(f"public key '{key_id}' is not a 32-byte Ed25519 key")
            self.keys[key_id] = Ed25519PublicKey.from_public_bytes(raw)

    @classmethod
    def from_env(cls, builtin: dict[str, str], env_var: str) -> "Keyring":
        keys = dict(builtin)
        for entry in filter(None, os.environ.get(env_var, "").split(",")):
            key_id, sep, b64 = entry.partition("=")
            if not sep:
                raise OvsyncError(f"{env_var}: expected id=base64, got '{entry}'")
            keys[key_id.strip()] = b64.strip()
        try:
            return cls(keys)
        except ValueError as e:
            raise OvsyncError(f"{env_var}: {e}")

    def open(self, envelope: Envelope, format: str) -> tuple[bytes, str]:
        if envelope.format != format:
            raise VerificationFailed(f"unsupported format '{envelope.format}'")
        if envelope.key_id is None:
            raise VerificationFailed("no key id")
        key = self.keys.get(envelope.key_id)
        if key is None:
            raise VerificationFailed(f"signed with key '{envelope.key_id}', which this ovsync does not trust")
        try:
            key.verify(envelope.signature, envelope.payload)
        except InvalidSignature:
            raise VerificationFailed("signature does not match: the file was altered or signed with a different key")
        return envelope.payload, envelope.key_id
