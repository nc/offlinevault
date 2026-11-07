"""Shape: Core/Sources/OfflineVaultCore/Updates/Manifest.swift."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import quote

from .errors import VerificationFailed

TIERS = ("free", "core", "full", "complete")
DEFAULT_TIER = "core"
CATALOGUE_ID = "catalogue"
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


def tier_rank(tier: str) -> int:
    return TIERS.index(tier) if tier in TIERS else len(TIERS)


def parse_iso(s: str) -> datetime:
    m = re.fullmatch(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(\.\d+)?Z", s)
    if not m:
        raise ValueError(f"invalid ISO-8601 date: {s}")
    return datetime.strptime(f"{m[1]}T{m[2]}", "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


@dataclass(frozen=True)
class External:
    """The bytes live on Kiwix's servers; OfflineVault signs the URL and the sha256 Kiwix publishes, nothing more."""
    url: str
    sha_source: str
    licence: str | None
    attribution: str | None


@dataclass(frozen=True)
class Artefact:
    id: str
    kind: str
    path: str
    size_bytes: int
    sha256: str
    tier: str
    replaces: tuple[str, ...]
    title: str | None
    summary: str | None
    external: External | None = None

    @property
    def file_name(self) -> str:
        return self.path.rsplit("/", 1)[-1]

    @property
    def display_title(self) -> str:
        return self.title or self.file_name

    def url(self, base: str) -> str:
        if self.external:
            return self.external.url
        return base + "/".join(quote(part) for part in self.path.split("/"))


@dataclass(frozen=True)
class Manifest:
    version: str
    published_at: datetime
    catalogue_version: str
    artefacts: tuple[Artefact, ...]

    def by_id(self) -> dict[str, Artefact]:
        return {a.id: a for a in self.artefacts}

    @property
    def catalogue(self) -> Artefact | None:
        return next((a for a in self.artefacts if a.kind == "catalogue"), None)


def parse_manifest(payload: bytes) -> Manifest:
    try:
        obj = json.loads(payload)
        artefacts = tuple(_artefact(a) for a in obj["artefacts"])
        manifest = Manifest(
            version=str(obj["version"]),
            published_at=parse_iso(obj["publishedAt"]),
            catalogue_version=str(obj.get("catalogueVersion", "")),
            artefacts=artefacts,
        )
    except (KeyError, TypeError, ValueError) as e:
        raise VerificationFailed(f"invalid manifest: {e}")
    seen: set[str] = set()
    for a in artefacts:
        if not a.id or a.id in seen:
            raise VerificationFailed(f"invalid manifest: duplicate or empty artefact id '{a.id}'")
        seen.add(a.id)
        if not _HEX64.match(a.sha256):
            raise VerificationFailed(f"invalid manifest: artefact '{a.id}' has a malformed SHA-256")
        parts = a.path.split("/")
        if not a.path or a.path.startswith("/") or "\\" in a.path or any(p in ("", ".", "..") for p in parts) or ":" in parts[0]:
            raise VerificationFailed(f"invalid manifest: artefact '{a.id}' has an invalid path")
        if a.size_bytes < 0:
            raise VerificationFailed(f"invalid manifest: artefact '{a.id}' has a negative size")
        if a.external and not a.external.url.startswith(("http://", "https://")):
            raise VerificationFailed(f"invalid manifest: artefact '{a.id}' has an invalid external URL")
    return manifest


def _artefact(a: dict) -> Artefact:
    return Artefact(
        id=str(a["id"]),
        kind=str(a["kind"]),
        path=str(a["path"]),
        size_bytes=int(a["sizeBytes"]),
        sha256=str(a["sha256"]).lower(),
        tier=str(a.get("tier") or DEFAULT_TIER),
        replaces=tuple(str(r) for r in a.get("replaces") or ()),
        title=a.get("title"),
        summary=a.get("summary"),
        external=_external(a.get("external")),
    )


def _external(e: dict | None) -> External | None:
    if e is None:
        return None
    return External(str(e["url"]), str(e.get("shaSource", "")), e.get("licence"), e.get("attribution"))
