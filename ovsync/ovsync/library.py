from __future__ import annotations

import hashlib
import json
import struct
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from xml.etree import ElementTree as ET

from .store import write_atomic

RECORD_NAME = "ovsync.json"
LIBRARY_NAME = "library.xml"
ZIM_MAGIC = 0x044D495A


@dataclass(frozen=True)
class Installed:
    path: str
    sha256: str
    size_bytes: int
    kind: str
    external: bool = False


class Record:
    def __init__(self, directory: Path, entries: dict[str, Installed]):
        self.directory = directory
        self.entries = entries

    @classmethod
    def load(cls, directory: Path) -> "Record":
        path = directory / RECORD_NAME
        if not path.exists():
            return cls(directory, {})
        obj = json.loads(path.read_text())
        return cls(directory, {k: Installed(**v) for k, v in obj.get("artefacts", {}).items()})

    def save(self) -> None:
        write_atomic(self.directory / RECORD_NAME, json.dumps(
            {"artefacts": {k: asdict(v) for k, v in sorted(self.entries.items())}}, indent=2) + "\n")

    def file(self, entry: Installed) -> Path:
        return self.directory.joinpath(*entry.path.split("/"))

    def is_complete(self, artefact_id: str, sha256: str) -> bool:
        e = self.entries.get(artefact_id)
        if e is None or e.sha256 != sha256:
            return False
        f = self.file(e)
        return f.exists() and f.stat().st_size == e.size_bytes

    def put(self, artefact_id: str, entry: Installed) -> Path | None:
        old = self.entries.get(artefact_id)
        self.entries[artefact_id] = entry
        return self._delete_orphan(old) if old and old.path != entry.path else None

    def forget(self, artefact_id: str) -> Path | None:
        old = self.entries.pop(artefact_id, None)
        return self._delete_orphan(old) if old else None

    def _delete_orphan(self, old: Installed) -> Path | None:
        if any(e.path == old.path for e in self.entries.values()):
            return None
        file = self.file(old)
        if not file.exists():
            return None
        file.unlink()
        return file

    def zims(self) -> list[tuple[str, Installed]]:
        out: dict[str, tuple[str, Installed]] = {}
        for artefact_id, e in sorted(self.entries.items(), key=lambda kv: (kv[1].path, kv[0])):
            if e.kind == "zim" and e.path not in out and self.file(e).exists():
                out[e.path] = (artefact_id, e)
        return list(out.values())


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def zim_uuid(path: Path) -> str | None:
    """ZIM header: magic(4) major(2) minor(2) uuid(16)."""
    with open(path, "rb") as f:
        head = f.read(24)
    if len(head) < 24 or struct.unpack("<I", head[:4])[0] != ZIM_MAGIC:
        return None
    return str(uuid.UUID(bytes=head[8:24]))


def write_library(record: Record, catalogue: dict[str, dict]) -> int:
    """Paths are relative; Kiwix resolves them against the library file's directory."""
    root = ET.Element("library", version="20110515")
    for artefact_id, entry in record.zims():
        meta = catalogue.get(artefact_id, {})
        file = record.file(entry)
        book = ET.SubElement(root, "book", id=zim_uuid(file) or artefact_id, path=entry.path)
        book.set("name", meta.get("fileName") or file.stem)
        book.set("title", meta.get("title") or file.stem)
        book.set("size", str(entry.size_bytes // 1024))
        for attr, key in (("description", "description"), ("language", "language"), ("creator", "attribution")):
            if meta.get(key):
                book.set(attr, str(meta[key]))
        book.set("publisher", "Kiwix" if entry.external else "OfflineVault")
        if meta.get("licence"):
            book.set("tags", f"_licence:{meta['licence']}")
    ET.indent(root)
    xml = ET.tostring(root, encoding="unicode")
    write_atomic(record.directory / LIBRARY_NAME, '<?xml version="1.0" encoding="UTF-8"?>\n' + xml + "\n")
    return len(root)
