"""catalogue-spec.json, parsed and gated. Nothing downstream re-checks a licence or an id.

An entry's `source` says where the bytes come from; its `kind` says what the app does with them. The licence
table carries the only redistribution policy the publisher has: a paid tier may hold these licences and nothing
else, and the ones marked `attribution` must name their authors in the catalogue.

A `kiwix_external` source is never stored or served by OfflineVault: the catalogue points the app at Kiwix's own
file and its published sha256. Only the non-redistributable licences in EXTERNAL_LICENCES may use it, so a book
that could be mirrored is mirrored, and a book that cannot is offered from Kiwix and marked as such.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal, Union

Tier = Literal["free", "core", "full", "complete"]
# `free` needs no plan; the ranks above it need the plan that includes them (Core/.../Licence.swift, Grant.forLevel).
TIER_RANK: dict[str, int] = {"free": 0, "core": 1, "full": 2, "complete": 3}
Kind = Literal["zim", "model", "document-pack", "map"]
KINDS = ("zim", "model", "document-pack", "map")
ROLES = ("procedural", "encyclopaedic", "reference")


@dataclass(frozen=True)
class Licence:
    id: str
    label: str
    attribution: bool


LICENCES: dict[str, Licence] = {l.id: l for l in (
    Licence("CC0-1.0", "CC0 1.0", False),
    Licence("PD", "Public domain", False),
    Licence("PD-USGov", "Public domain (US Government, 17 USC §105)", False),
    Licence("CC-BY-4.0", "CC BY 4.0", True),
    Licence("CC-BY-SA-2.0", "CC BY-SA 2.0", True),
    Licence("CC-BY-SA-3.0", "CC BY-SA 3.0", True),
    Licence("CC-BY-SA-4.0", "CC BY-SA 4.0", True),
    Licence("GFDL-1.3", "GFDL 1.3", True),
    Licence("OGL-3.0", "Open Government Licence v3.0", True),
    Licence("ODbL-1.0", "ODbL 1.0", True),
    Licence("Apache-2.0", "Apache 2.0", False),
)}

# Licences OfflineVault may not redistribute. Valid only on a `kiwix_external` source, which downloads from Kiwix.
EXTERNAL_LICENCES: dict[str, Licence] = {l.id: l for l in (
    Licence("CC-BY-NC-SA-3.0", "CC BY-NC-SA 3.0", True),
    Licence("CC-BY-NC-SA-4.0", "CC BY-NC-SA 4.0", True),
    Licence("CC-BY-NC-4.0", "CC BY-NC 4.0", True),
    Licence("Mixed", "Mixed; parts are not redistributable", True),
)}
assert not set(LICENCES) & set(EXTERNAL_LICENCES)
ALL_LICENCES: dict[str, Licence] = {**LICENCES, **EXTERNAL_LICENCES}


@dataclass(frozen=True)
class KiwixSource:
    category: str
    base: str


@dataclass(frozen=True)
class KiwixExternalSource:
    """Resolved like KiwixSource, but the app downloads from download.kiwix.org; nothing enters the store."""
    category: str
    base: str


@dataclass(frozen=True)
class UrlSource:
    url: str


@dataclass(frozen=True)
class ArchiveSource:
    item: str
    file: str

    @property
    def url(self) -> str:
        from urllib.parse import quote
        return f"https://archive.org/download/{self.item}/{quote(self.file)}"


@dataclass(frozen=True)
class Document:
    id: str
    title: str
    licence: str
    source: Union[UrlSource, ArchiveSource]
    publisher: str | None = None
    summary: str | None = None

    @property
    def file_name(self) -> str:
        return f"{self.id}.pdf"


@dataclass(frozen=True)
class DocumentsSource:
    documents: tuple[Document, ...]


@dataclass(frozen=True)
class ZimitSource:
    name: str
    seeds: tuple[str, ...]
    scope: str | None = None


@dataclass(frozen=True)
class MapExtractSource:
    maxzoom: int
    bbox: str | None = None


@dataclass(frozen=True)
class BuiltSource:
    builder: str
    params: dict = field(default_factory=dict)


Source = Union[KiwixSource, KiwixExternalSource, UrlSource, ArchiveSource, DocumentsSource, ZimitSource, MapExtractSource, BuiltSource]

SOURCE_KINDS = {"kiwix": KiwixSource, "kiwix_external": KiwixExternalSource, "url": UrlSource, "archive": ArchiveSource,
                "documents": DocumentsSource, "zimit": ZimitSource, "map_extract": MapExtractSource, "built": BuiltSource}


@dataclass(frozen=True)
class Entry:
    id: str
    kind: str
    tier: str
    title: str
    description: str
    licence: str
    attribution: str | None
    source: Source
    role: str | None = None
    language: str | None = None
    replaces_entry: str | None = None
    stream: bool = False

    @property
    def dated(self) -> bool:
        """Dated kinds get a new artefact id per edition; the client installs the new one and removes the old."""
        return self.kind in ("zim", "map")

    @property
    def external(self) -> bool:
        return isinstance(self.source, KiwixExternalSource)

    @property
    def licence_label(self) -> str:
        return ALL_LICENCES[self.licence].label


@dataclass(frozen=True)
class Exclusion:
    id: str
    reason: str


@dataclass(frozen=True)
class Spec:
    version: str
    entries: tuple[Entry, ...]
    excluded: tuple[Exclusion, ...]

    def by_id(self) -> dict[str, Entry]:
        return {e.id: e for e in self.entries}

    def within(self, tier: str) -> tuple[Entry, ...]:
        return tuple(e for e in self.entries if TIER_RANK[e.tier] <= TIER_RANK[tier])

    def documents(self) -> dict[str, tuple[Entry, Document]]:
        """Every PDF the spec knows, by document id. The Field Guide cites PDFs through this table."""
        out: dict[str, tuple[Entry, Document]] = {}
        for e in self.entries:
            if isinstance(e.source, DocumentsSource):
                for d in e.source.documents:
                    out[d.id] = (e, d)
        return out


class SpecError(ValueError):
    """Every offence in the file, one per line, so an editor fixes them in one pass."""

    def __init__(self, problems: list[str]):
        super().__init__("\n".join(problems))
        self.problems = problems


def load_spec(path: Path) -> Spec:
    return parse_spec(json.loads(Path(path).read_text()))


def parse_spec(data: dict) -> Spec:
    problems: list[str] = []
    entries: list[Entry] = []
    ids: list[str] = []
    for raw in data.get("entries", []):
        eid = str(raw.get("id", "<missing id>"))
        ids.append(eid)
        try:
            entries.append(_parse_entry(raw))
        except SpecError as e:
            problems.extend(e.problems)
    excluded = tuple(Exclusion(str(x.get("id")), str(x.get("reason", ""))) for x in data.get("excluded", []))
    for x in excluded:
        if not x.reason:
            problems.append(f"excluded {x.id}: needs a reason")

    seen: set[str] = set()
    for i in ids:
        if i in seen:
            problems.append(f"{i}: duplicate id")
        seen.add(i)
    for a in sorted(seen):
        for b in seen:
            if a != b and b.startswith(a):
                problems.append(f"{a}: is a prefix of {b}; ids must be prefix-free")
    both = seen & {x.id for x in excluded}
    for i in sorted(both):
        problems.append(f"{i}: appears in both entries and excluded")
    for e in entries:
        if e.replaces_entry and e.replaces_entry not in seen:
            problems.append(f"{e.id}.replacesEntry: {e.replaces_entry} is not an entry")
    doc_ids: dict[str, str] = {}
    for e in entries:
        if isinstance(e.source, DocumentsSource):
            for d in e.source.documents:
                if d.id in doc_ids:
                    problems.append(f"{e.id}.documents: document id {d.id} already used by {doc_ids[d.id]}")
                doc_ids[d.id] = e.id
    if "version" not in data:
        problems.append("version: missing")
    if problems:
        raise SpecError(sorted(set(problems)))
    return Spec(version=str(data["version"]), entries=tuple(entries), excluded=excluded)


def _parse_entry(raw: dict) -> Entry:
    eid = str(raw.get("id", "<missing id>"))
    p: list[str] = []
    for key in ("id", "kind", "tier", "title", "description", "licence", "source"):
        if key not in raw:
            p.append(f"{eid}.{key}: missing")
    kind, tier = raw.get("kind"), raw.get("tier")
    if kind is not None and kind not in KINDS:
        p.append(f"{eid}.kind: {kind!r} is not one of {', '.join(KINDS)}")
    if tier is not None and tier not in TIER_RANK:
        p.append(f"{eid}.tier: {tier!r} is not one of {', '.join(TIER_RANK)}")
    role = raw.get("role")
    if role is not None and role not in ROLES:
        p.append(f"{eid}.role: {role!r} is not one of {', '.join(ROLES)}")
    source = None
    if "source" in raw:
        try:
            source = _parse_source(eid, raw["source"])
        except SpecError as e:
            p.extend(e.problems)
    lic = raw.get("licence")
    attribution = raw.get("attribution")
    if lic is not None:
        p.extend(_check_licence(f"{eid}", lic, attribution, external=isinstance(source, KiwixExternalSource)))
    if p:
        raise SpecError(p)
    return Entry(id=raw["id"], kind=kind, tier=tier, title=raw["title"], description=raw["description"], licence=lic,
                 attribution=attribution, source=source, role=role, language=raw.get("language"),
                 replaces_entry=raw.get("replacesEntry"), stream=bool(raw.get("stream", False)))


def _check_licence(where: str, lic: object, attribution: object, external: bool = False) -> list[str]:
    """The licence table is chosen by where the bytes will live: ours (LICENCES) or Kiwix's (EXTERNAL_LICENCES)."""
    table = EXTERNAL_LICENCES if external else LICENCES
    if lic not in table:
        if external and lic in LICENCES:
            return [f"{where}.licence: {lic} is redistributable; use source kind kiwix so OfflineVault serves it"]
        if not external and lic in EXTERNAL_LICENCES:
            return [f"{where}.licence: {lic!r} is not an allowed licence ({', '.join(LICENCES)}); source kind kiwix_external offers it from Kiwix"]
        return [f"{where}.licence: {lic!r} is not an allowed licence ({', '.join(table)})"]
    if table[lic].attribution and not (isinstance(attribution, str) and attribution.strip()):
        return [f"{where}.attribution: required for {lic}"]
    return []


def _parse_source(eid: str, raw: object) -> Source:
    if not isinstance(raw, dict) or "kind" not in raw:
        raise SpecError([f"{eid}.source: needs a kind"])
    kind = raw["kind"]
    if kind not in SOURCE_KINDS:
        raise SpecError([f"{eid}.source.kind: {kind!r} is not one of {', '.join(SOURCE_KINDS)}"])
    need = {"kiwix": ("category", "base"), "kiwix_external": ("category", "base"), "url": ("url",), "archive": ("item", "file"), "documents": ("documents",),
            "zimit": ("name", "seeds"), "map_extract": ("maxzoom",), "built": ("builder",)}[kind]
    missing = [k for k in need if k not in raw]
    if missing:
        raise SpecError([f"{eid}.source.{k}: missing" for k in missing])
    if kind == "kiwix":
        return KiwixSource(raw["category"], raw["base"])
    if kind == "kiwix_external":
        return KiwixExternalSource(raw["category"], raw["base"])
    if kind == "url":
        return UrlSource(raw["url"])
    if kind == "archive":
        return ArchiveSource(raw["item"], raw["file"])
    if kind == "zimit":
        return ZimitSource(raw["name"], tuple(raw["seeds"]), raw.get("scope"))
    if kind == "map_extract":
        return MapExtractSource(int(raw["maxzoom"]), raw.get("bbox"))
    if kind == "built":
        return BuiltSource(raw["builder"], dict(raw.get("params", {})))
    docs: list[Document] = []
    p: list[str] = []
    for d in raw["documents"]:
        did = str(d.get("id", "<missing id>"))
        for key in ("id", "title", "licence"):
            if key not in d:
                p.append(f"{eid}.documents.{did}.{key}: missing")
        if "licence" in d:
            p.extend(_check_licence(f"{eid}.documents.{did}", d["licence"], d.get("publisher")))
        if "url" in d:
            src: Union[UrlSource, ArchiveSource] = UrlSource(d["url"])
            if str(d["url"]).startswith("MANUAL:") or "://" not in str(d["url"]):
                p.append(f"{eid}.documents.{did}.url: not a verified URL ({d['url']!r})")
        elif isinstance(d.get("archive"), dict) and {"item", "file"} <= set(d["archive"]):
            src = ArchiveSource(d["archive"]["item"], d["archive"]["file"])
        else:
            p.append(f"{eid}.documents.{did}: needs url or archive{{item, file}}")
            continue
        if not p:
            docs.append(Document(d["id"], d["title"], d["licence"], src, d.get("publisher"), d.get("summary")))
    if p:
        raise SpecError(p)
    if not docs:
        raise SpecError([f"{eid}.documents: empty"])
    return DocumentsSource(tuple(docs))
