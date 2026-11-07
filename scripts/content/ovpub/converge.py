"""Make the store hold the artefact a candidate describes, then say what happened. Every decision reads the
state that exists (store head, local file, builder inputs, the lock's confirmed facts); nothing depends on what an
earlier run intended, so a run that crashed between upload and lock write converges on the next run."""
from __future__ import annotations

import os
import time
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path

from . import fetch
from .builders import BuildContext, builder_for
from .lock import ArtefactFacts, LockEntry, SourceFacts
from .resolve import Candidate, Edition, now_month
from .store import ObjectInfo, Store

EVICT_OVER_BYTES = 4 * 1024 ** 3
RESERVE_BYTES = 40 * 1024 ** 3


class ConvergeError(Exception):
    pass


@dataclass
class Outcome:
    entry_id: str
    action: str                      # unchanged | uploaded | streamed | built | external | failed | skipped
    bytes: int = 0
    seconds: float = 0.0
    detail: str = ""
    artefact: ArtefactFacts | None = None
    source: SourceFacts | None = None
    inputs: dict = field(default_factory=dict)


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def stream_decision(cand: Candidate, free_bytes: int, reserve: int = RESERVE_BYTES) -> bool:
    """Decided on the main thread before dispatch so two workers never both claim the same disk."""
    if not cand.passthrough or cand.external:
        return False
    if cand.entry.stream:
        return True
    size = cand.upstream.size if cand.upstream else None
    return size is not None and size > free_bytes - reserve


def source_facts(cand: Candidate) -> SourceFacts | None:
    if cand.upstream is None:
        return None
    u = cand.upstream
    return SourceFacts(u.url, u.size, u.sha256, cand.edition, now_iso(), u.sha_source)


def converge(cand: Candidate, previous: LockEntry | None, store: Store, ctx: BuildContext, stream: bool, store_is_real: bool = True) -> Outcome:
    t0 = time.time()
    key = cand.path
    try:
        out = _converge(cand, previous, store, ctx, stream, store_is_real)
    except Exception as e:  # noqa: BLE001 - one entry's failure must not stop the run
        out = Outcome(cand.entry.id, "failed", detail=f"{type(e).__name__}: {e}", source=source_facts(cand))
    out.seconds = round(time.time() - t0, 1)
    if out.artefact is None and out.action not in ("failed", "skipped"):
        out.action = "failed"
        out.detail = out.detail or f"{key}: no artefact facts"
    return out


def _converge(cand: Candidate, previous: LockEntry | None, store: Store, ctx: BuildContext, stream: bool, store_is_real: bool) -> Outcome:
    uploaded_at = now_iso() if store_is_real else None
    src = source_facts(cand)
    if cand.external:
        return _converge_external(cand, src)
    if cand.mirror:
        return _converge_mirror(cand, previous, store, ctx, stream, uploaded_at, src)
    return _converge_dated(cand, previous, store, ctx, stream, uploaded_at, src)


def _converge_external(cand: Candidate, src: SourceFacts | None) -> Outcome:
    """Nothing to store: the artefact is Kiwix's file at Kiwix's URL, and the manifest repeats the size and sha Kiwix publishes."""
    up = cand.upstream
    if up is None or up.sha256 is None or up.size is None:
        raise ConvergeError(f"{cand.path}: Kiwix publishes no sha256 and size for it (meta4 missing), so it cannot be offered from Kiwix")
    return Outcome(cand.entry.id, "external", bytes=up.size, artefact=ArtefactFacts(cand.artefact_id, cand.path, up.size, up.sha256, None, up.url), source=src)


def _converge_mirror(cand: Candidate, previous: LockEntry | None, store: Store, ctx: BuildContext, stream: bool, uploaded_at: str | None, src: SourceFacts | None) -> Outcome:
    """The key is the upstream file name and the bytes are the upstream bytes; different bytes under it is a hard failure."""
    key = cand.path
    eid = cand.entry.id
    assert cand.upstream is not None
    same_id = previous is not None and previous.artefact is not None and previous.artefact.id == cand.artefact_id
    expected = cand.upstream.sha256 or (previous.artefact.sha256 if same_id else None)
    info = store.head(key)
    if info and expected and info.sha256 == expected:
        kept = previous.artefact.uploaded_at if same_id else None
        return Outcome(eid, "unchanged", artefact=ArtefactFacts(cand.artefact_id, key, info.size, expected, kept or uploaded_at), source=src)
    if info and expected and info.sha256 and info.sha256 != expected:
        raise ConvergeError(f"{key} is already in the store with sha {info.sha256[:12]}, expected {expected[:12]}; upstream republished under the same name?")
    if stream:
        sent = store.put_stream(key, fetch.stream(cand.upstream.url), expected, cand.upstream.size)
        if expected and sent.sha256 != expected:
            store.delete(key)
            raise ConvergeError(f"{key}: streamed bytes hash to {sent.sha256[:12]}, expected {expected[:12]}; deleted the object")
        _confirm(store, key, sent.sha256)
        return Outcome(eid, "streamed", bytes=sent.size, artefact=ArtefactFacts(cand.artefact_id, key, sent.size, sent.sha256, uploaded_at), source=src)
    local = ctx.content / key
    cache = fetch.HashCache(ctx.content)
    if local.exists():
        sha = cache.sha256(local)
        if expected and sha != expected:
            ctx.log(f"  {local.name} on disk hashes to {sha[:12]}, expected {expected[:12]}; refetching")
            local.unlink()
    if not local.exists():
        fetch.download(cand.upstream.url, local, ctx.log)
        sha = cache.sha256(local)
        if expected and sha != expected:
            raise ConvergeError(f"{key}: downloaded bytes hash to {sha[:12]}, expected {expected[:12]} (meta4/LFS); kept the file for inspection")
    size = os.path.getsize(local)
    if not (info and info.sha256 == sha):
        store.put_file(key, local, sha)
    _confirm(store, key, sha)
    if size > EVICT_OVER_BYTES:
        local.unlink()
    return Outcome(eid, "uploaded", bytes=size, artefact=ArtefactFacts(cand.artefact_id, key, size, sha, uploaded_at), source=src)


def _converge_dated(cand: Candidate, previous: LockEntry | None, store: Store, ctx: BuildContext, stream: bool, uploaded_at: str | None, src: SourceFacts | None) -> Outcome:
    """Keys carry an edition, so changed bytes get the next free key of the month rather than a conflict."""
    eid = cand.entry.id
    builder = builder_for(cand)
    inputs = builder.inputs(cand, ctx)
    kept = previous.artefact if previous and previous.artefact and previous.inputs == inputs else None
    if kept and _holds(store.head(kept.path), kept.size, kept.sha256):
        return Outcome(eid, "unchanged", artefact=kept if kept.uploaded_at else replace(kept, uploaded_at=uploaded_at), source=src, inputs=inputs)
    if stream:
        assert cand.passthrough and cand.upstream is not None
        chosen, _ = _edition_for(cand, store, None)
        sent = store.put_stream(chosen.path, fetch.stream(cand.upstream.url), cand.upstream.sha256, cand.upstream.size)
        if cand.upstream.size is not None and sent.size != cand.upstream.size:
            store.delete(chosen.path)
            raise ConvergeError(f"{chosen.path}: streamed {sent.size} bytes, upstream Content-Length is {cand.upstream.size}; deleted the object")
        if cand.upstream.sha256 and sent.sha256 != cand.upstream.sha256:
            store.delete(chosen.path)
            raise ConvergeError(f"{chosen.path}: streamed bytes hash to {sent.sha256[:12]}, expected {cand.upstream.sha256[:12]}; deleted the object")
        _confirm(store, chosen.path, sent.sha256)
        return Outcome(eid, "streamed", bytes=sent.size, artefact=ArtefactFacts(chosen.artefact_id, chosen.path, sent.size, sent.sha256, uploaded_at), source=src, inputs=inputs)
    path = builder.build(cand, ctx)
    sha = fetch.HashCache(ctx.content).sha256(path)
    size = os.path.getsize(path)
    chosen, info = _edition_for(cand, store, sha)
    if info is None:
        store.put_file(chosen.path, Path(path), sha)
    _confirm(store, chosen.path, sha)
    if info and kept is None and previous and previous.artefact and previous.artefact.path == chosen.path:
        uploaded_at = previous.artefact.uploaded_at or uploaded_at
    return Outcome(eid, "unchanged" if info else "built", bytes=size, artefact=ArtefactFacts(chosen.artefact_id, chosen.path, size, sha, uploaded_at), source=src, inputs=inputs)


def _holds(info: ObjectInfo | None, size: int, sha: str) -> bool:
    """An object streamed without a sha has none stored; its immutable key and size still vouch for it."""
    return info is not None and info.size == size and (info.sha256 is None or info.sha256 == sha)


def _edition_for(cand: Candidate, store: Store, sha: str | None) -> tuple[Candidate, ObjectInfo | None]:
    """The first edition of the month whose key is free, or already holds these bytes when the sha is known.
    Every key an earlier run took stays where it is; the suffix moves past it."""
    try:
        month = Edition.parse(cand.edition or "").month
    except ValueError:
        month = now_month()
    c = cand.with_edition(Edition(month))
    while True:
        info = store.head(c.path)
        if info is None or (sha is not None and info.sha256 == sha):
            return c, info
        c = c.with_edition(Edition.parse(c.edition).bump())


def _confirm(store: Store, key: str, sha: str) -> None:
    info = store.head(key)
    if info is None:
        raise ConvergeError(f"{key}: not in the store after upload")
    if info.sha256 and info.sha256 != sha:
        raise ConvergeError(f"{key}: store reports sha {info.sha256[:12]} after upload, expected {sha[:12]}")
