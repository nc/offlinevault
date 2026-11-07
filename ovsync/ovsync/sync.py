from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .client import Progress, Service
from .errors import LicenceNeeded, OvsyncError
from .library import Installed, Record, sha256_of, write_library
from .manifest import Artefact, Manifest, tier_rank

INCLUDE_KINDS = {"models": "model", "maps": "map"}
# Artefacts that download from Kiwix's servers rather than the catalogue; opt-in, like the extra kinds.
INCLUDE_EXTERNAL = "external"
INCLUDES = (*INCLUDE_KINDS, INCLUDE_EXTERNAL)
EXTERNAL_NOTE = "from Kiwix, not verified by OfflineVault"
Log = Callable[[str], None]


def select(manifest: Manifest, tier: str, only: tuple[str, ...], include: frozenset[str]) -> list[Artefact]:
    if only:
        by_id = manifest.by_id()
        unknown = [i for i in only if i not in by_id or by_id[i].kind == "catalogue"]
        if unknown:
            raise OvsyncError(f"not in the catalogue: {', '.join(unknown)}")
        return [by_id[i] for i in only]
    kinds = {"zim"} | {INCLUDE_KINDS[i] for i in include if i in INCLUDE_KINDS}
    external = INCLUDE_EXTERNAL in include
    return [a for a in manifest.artefacts if a.kind in kinds and tier_rank(a.tier) <= tier_rank(tier) and (external or a.external is None)]


def gate(artefacts: list[Artefact], allowed: frozenset[str], has_licence: bool) -> None:
    denied = [a for a in artefacts if a.tier not in allowed]
    if not denied:
        return
    first = denied[0]
    more = f" and {len(denied) - 1} more" if len(denied) > 1 else ""
    covers = ", ".join(sorted(allowed, key=tier_rank))
    fix = "activate a key with 'ovsync activate OV-...'" if not has_licence else "upgrade the plan, or narrow the run with --tier or --only"
    raise LicenceNeeded(f"'{first.id}' is in tier '{first.tier}'{more}; your licence covers {covers}. To continue, {fix}")


@dataclass
class Summary:
    downloaded: int = 0
    skipped: int = 0
    removed: int = 0
    books: int = 0


def run_sync(service: Service, manifest: Manifest, directory: Path, wanted: list[Artefact], log: Log, progress: Progress) -> Summary:
    directory.mkdir(parents=True, exist_ok=True)
    record = Record.load(directory)
    summary = Summary()
    catalogue = manifest.catalogue
    for a in ([catalogue] if catalogue else []) + wanted:
        if record.is_complete(a.id, a.sha256):
            log(f"ok   {a.id}  ({human(a.size_bytes)}, complete)")
            summary.skipped += 1
            continue
        dest = directory.joinpath(*a.path.split("/"))
        if dest.exists() and dest.stat().st_size == a.size_bytes and sha256_of(dest) == a.sha256:
            log(f"ok   {a.id}  ({human(a.size_bytes)}, verified on disk)")
            summary.skipped += 1
        else:
            if dest.exists():
                dest.unlink()
            log(f"get  {a.id}  {a.display_title} ({human(a.size_bytes)}{', ' + EXTERNAL_NOTE if a.external else ''})")
            service.download(a.url(service.content), dest, a.size_bytes, a.sha256, progress)
            summary.downloaded += 1
        _log_removed(record.put(a.id, Installed(a.path, a.sha256, a.size_bytes, a.kind, a.external is not None)), log, summary)
        record.save()
    for a in wanted:
        for old_id in a.replaces:
            if old_id in record.entries and old_id != a.id:
                log(f"drop {old_id}  (replaced by {a.id})")
                _log_removed(record.forget(old_id), log, summary)
                record.save()
    summary.books = write_library(record, _catalogue_entries(record, catalogue))
    return summary


def run_verify(directory: Path, log: Log) -> list[str]:
    record = Record.load(directory)
    failed = []
    for artefact_id, e in sorted(record.entries.items()):
        f = record.file(e)
        if not f.exists():
            log(f"MISSING  {artefact_id}  {e.path}")
            failed.append(artefact_id)
        elif sha256_of(f) != e.sha256:
            log(f"BAD      {artefact_id}  {e.path}  (SHA-256 mismatch)")
            failed.append(artefact_id)
        else:
            log(f"ok       {artefact_id}  {e.path}")
    for artefact_id in failed:
        record.entries.pop(artefact_id)
    if failed:
        record.save()
    for part in sorted(directory.rglob("*.part")):
        log(f"partial  {part.relative_to(directory)}  (rerun 'ovsync sync' to finish)")
    return failed


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1000:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000
    return f"{n:.1f} TB"


def _log_removed(path: Path | None, log: Log, summary: Summary) -> None:
    if path:
        summary.removed += 1
        log(f"rm   {path.name}")


def _catalogue_entries(record: Record, catalogue: Artefact | None) -> dict[str, dict]:
    if not catalogue or catalogue.id not in record.entries:
        return {}
    try:
        entries = json.loads(record.file(record.entries[catalogue.id]).read_text(encoding="utf-8"))["entries"]
        return {e["artefactId"]: e for e in entries if isinstance(e, dict) and "artefactId" in e}
    except (OSError, ValueError, KeyError, TypeError):
        return {}
