"""(spec, lock) -> manifest payload and catalogue. Pure; the same inputs give the same bytes.

The manifest covers every lock entry the spec still names, whatever tier the run was scoped to, so a `--tier
core` publish keeps last month's full and complete artefacts live. `replaces` lists every artefact id this one
supersedes: the entry's own history, then the current id and history of the entry it `replacesEntry`.

An external artefact (lock `externalURL`, spec `kiwix_external`) carries an `external` block the app downloads
from instead of `path`; the signature covers it like every other field. The lock and the spec must agree on which
entries are external, or the manifest would point the app at a file that is not where it says.
"""
from __future__ import annotations

import hashlib
import json

from .lock import Lock
from .spec import DocumentsSource, Entry, KiwixExternalSource, KiwixSource, Spec, UrlSource, ZimitSource

MIN_APP_VERSION = "1.0.0"


def catalogue_path(version: str) -> str:
    return f"catalogue/catalogue-{version}.json"


def build_manifest(spec: Spec, lock: Lock, version: str, now: str, min_app: str = MIN_APP_VERSION) -> tuple[dict, bytes]:
    """Returns (manifest payload, catalogue JSON bytes). Entries without a locked artefact are left out."""
    by_id = spec.by_id()
    artefacts: list[dict] = []
    cat_entries: list[dict] = []
    for eid in sorted(lock.entries):
        entry = by_id.get(eid)
        le = lock.entries[eid]
        if entry is None or le.artefact is None:
            continue
        a = le.artefact
        if entry.external != bool(a.external_url):
            raise ValueError(f"{eid}: the spec says {'external' if entry.external else 'stored'} but the lock says "
                             f"{'external' if a.external_url else 'stored'}; publish it again without --frozen")
        row = {
            "id": a.id, "kind": entry.kind, "path": a.path, "sizeBytes": a.size, "sha256": a.sha256,
            "minAppVersion": min_app, "replaces": replaces_for(entry, lock), "title": entry.title,
            "summary": entry.description, "tier": entry.tier,
        }
        if a.external_url:
            row["external"] = {"url": a.external_url, "shaSource": "kiwix-meta4", "licence": entry.licence_label, "attribution": entry.attribution}
        artefacts.append(row)
        cat_entries.append(_catalogue_entry(entry, a.id, a.path, le))
    catalogue = {"catalogueVersion": version, "entries": cat_entries}
    cat_bytes = (json.dumps(catalogue, indent=2, ensure_ascii=False, sort_keys=True) + "\n").encode()
    artefacts.insert(0, {
        "id": "catalogue", "kind": "catalogue", "path": catalogue_path(version), "sizeBytes": len(cat_bytes),
        "sha256": hashlib.sha256(cat_bytes).hexdigest(), "minAppVersion": min_app, "replaces": [], "title": "Catalogue", "tier": "free",
    })
    payload = {"version": version, "publishedAt": now, "catalogueVersion": version, "artefacts": artefacts}
    return payload, cat_bytes


def replaces_for(entry: Entry, lock: Lock) -> list[str]:
    own = lock.entries.get(entry.id)
    ids: list[str] = list(own.history) if own else []
    if entry.replaces_entry:
        other = lock.entries.get(entry.replaces_entry)
        if other:
            if other.artefact:
                ids.append(other.artefact.id)
            ids.extend(other.history)
    me = own.artefact.id if own and own.artefact else None
    seen: set[str] = set()
    out = []
    for i in ids:
        if i != me and i not in seen:
            seen.add(i)
            out.append(i)
    return out


def _catalogue_entry(entry: Entry, artefact_id: str, path: str, le) -> dict:
    name = path.rsplit("/", 1)[-1]
    file_name = name[:-4] if entry.kind == "zim" and name.endswith(".zim") else name
    source_url = None
    if isinstance(entry.source, ZimitSource):
        source_url = entry.source.seeds[0]
    elif isinstance(entry.source, (KiwixSource, KiwixExternalSource, UrlSource)) and le.source:
        source_url = le.source.url
    row = {
        "artefactId": artefact_id, "title": entry.title, "description": entry.description, "language": entry.language,
        "licence": entry.licence_label, "attribution": entry.attribution, "fileName": file_name,
        "role": entry.role, "tier": entry.tier, "sourceURL": source_url,
    }
    if isinstance(entry.source, DocumentsSource):
        row["description"] = f"{entry.description} {len(entry.source.documents)} documents: " + "; ".join(d.title for d in entry.source.documents)
    return {k: v for k, v in row.items() if v is not None}


def is_noop(new_payload: dict, live_payload: dict | None, new_catalogue: bytes | None = None, live_catalogue: bytes | None = None) -> bool:
    """True when publishing would change nothing a client can see: same artefacts (the catalogue artefact's dated
    path and sha are ignored) and, when both are known, the same catalogue entries."""
    if live_payload is None:
        return False
    if _comparable(new_payload) != _comparable(live_payload):
        return False
    if new_catalogue is not None and live_catalogue is not None:
        return json.loads(new_catalogue)["entries"] == json.loads(live_catalogue)["entries"]
    return True


def _comparable(payload: dict) -> list[dict]:
    rows = [a for a in payload.get("artefacts", []) if a.get("kind") != "catalogue"]
    return sorted(rows, key=lambda a: a["id"])
