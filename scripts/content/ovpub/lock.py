"""catalogue.lock.json: what has been verified in the store, per spec entry.

Invariant the publisher relies on: an `artefact` here was confirmed by `Store.head` with this sha before it was
written (`uploadedAt` is null only when a FakeStore stood in for R2), unless `externalURL` is set, in which case
the bytes live at that URL on Kiwix's servers and were never in the store. `history` keeps the previous artefact
ids, newest first, and feeds `Artefact.replaces` so a client that skipped months still removes the right edition.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path

FORMAT = "offlinevault-lock/1"
HISTORY_CAP = 12


@dataclass(frozen=True)
class SourceFacts:
    url: str | None
    size: int | None
    sha256: str | None
    edition: str | None
    resolved_at: str
    sha_source: str | None = None


@dataclass(frozen=True)
class ArtefactFacts:
    id: str
    path: str
    size: int
    sha256: str
    uploaded_at: str | None
    external_url: str | None = None


@dataclass(frozen=True)
class LockEntry:
    source: SourceFacts | None = None
    artefact: ArtefactFacts | None = None
    history: tuple[str, ...] = ()
    inputs: dict = field(default_factory=dict)


@dataclass
class Lock:
    entries: dict[str, LockEntry] = field(default_factory=dict)
    spec_version: str | None = None

    @classmethod
    def load(cls, path: Path) -> "Lock":
        if not Path(path).exists():
            return cls()
        data = json.loads(Path(path).read_text())
        if data.get("format") != FORMAT:
            raise ValueError(f"{path}: unknown lock format {data.get('format')!r}")
        entries = {}
        for eid, raw in data["entries"].items():
            src = raw.get("source")
            art = raw.get("artefact")
            entries[eid] = LockEntry(
                source=SourceFacts(src["url"], src["size"], src["sha256"], src["edition"], src["resolvedAt"], src.get("shaSource")) if src else None,
                artefact=ArtefactFacts(art["id"], art["path"], art["size"], art["sha256"], art.get("uploadedAt"), art.get("externalURL")) if art else None,
                history=tuple(raw.get("history", ())),
                inputs=dict(raw.get("inputs", {})))
        return cls(entries=entries, spec_version=data.get("specVersion"))

    def save(self, path: Path) -> None:
        out = {"format": FORMAT, "specVersion": self.spec_version, "entries": {}}
        for eid in sorted(self.entries):
            e = self.entries[eid]
            row: dict = {}
            if e.source:
                s = e.source
                row["source"] = {"url": s.url, "size": s.size, "sha256": s.sha256, "edition": s.edition, "resolvedAt": s.resolved_at, "shaSource": s.sha_source}
            if e.artefact:
                a = e.artefact
                row["artefact"] = {"id": a.id, "path": a.path, "size": a.size, "sha256": a.sha256, "uploadedAt": a.uploaded_at}
                if a.external_url:
                    row["artefact"]["externalURL"] = a.external_url
            row["history"] = list(e.history)
            if e.inputs:
                row["inputs"] = e.inputs
            out["entries"][eid] = row
        tmp = Path(str(path) + ".tmp")
        tmp.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
        os.replace(tmp, path)

    def record(self, entry_id: str, artefact: ArtefactFacts, source: SourceFacts | None = None, inputs: dict | None = None) -> LockEntry:
        """Same artefact id twice is a no-op for history; a new id pushes the old one onto history."""
        prev = self.entries.get(entry_id, LockEntry())
        history = prev.history
        if prev.artefact and prev.artefact.id != artefact.id:
            history = (prev.artefact.id,) + tuple(h for h in prev.history if h != prev.artefact.id)
        history = tuple(h for h in history if h != artefact.id)[:HISTORY_CAP]
        e = LockEntry(source=source if source is not None else prev.source, artefact=artefact, history=history,
                      inputs=inputs if inputs is not None else prev.inputs)
        self.entries[entry_id] = e
        return e

    def forget(self, entry_id: str) -> None:
        self.entries.pop(entry_id, None)

    def all_artefact_ids(self) -> set[str]:
        ids = set()
        for e in self.entries.values():
            if e.artefact:
                ids.add(e.artefact.id)
            ids.update(e.history)
        return ids

    def all_paths(self) -> set[str]:
        return {e.artefact.path for e in self.entries.values() if e.artefact}


def as_dict(obj) -> dict:
    return asdict(obj)


__all__ = ["Lock", "LockEntry", "SourceFacts", "ArtefactFacts", "FORMAT", "HISTORY_CAP", "replace"]
