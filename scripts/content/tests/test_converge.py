import hashlib
import json
import os
import tarfile
from pathlib import Path

import pytest

from ovpub import converge as cv
from ovpub import fetch, manifest
from ovpub.builders import BuildContext, docpack, zimit
from ovpub.lock import Lock
from ovpub.resolve import PROTOMAPS_BUILD, Candidate, Upstream, dated
from ovpub.spec import parse_spec
from ovpub.store import FakeStore, ObjectInfo
from tests.test_resolve import FakeHttp


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


SPEC = parse_spec({"version": "v", "excluded": [], "entries": [
    {"id": "zim-wikem", "kind": "zim", "tier": "core", "title": "W", "description": "d", "licence": "CC-BY-SA-4.0", "attribution": "x",
     "source": {"kind": "kiwix", "category": "other", "base": "wikem_en_all_maxi"}},
    {"id": "docs-x", "kind": "document-pack", "tier": "core", "title": "X", "description": "d", "licence": "PD-USGov", "role": "procedural",
     "source": {"kind": "documents", "documents": [{"id": "a", "title": "A", "licence": "PD-USGov", "url": "https://x/a.pdf", "publisher": "EPA"},
                                                   {"id": "b", "title": "B", "licence": "PD-USGov", "archive": {"item": "I", "file": "b.pdf"}}]}},
    {"id": "map-world-full", "kind": "map", "tier": "complete", "title": "M", "description": "d", "licence": "ODbL-1.0", "attribution": "OSM", "stream": True,
     "source": {"kind": "map_extract", "maxzoom": 15}},
    {"id": "zim-cdc", "kind": "zim", "tier": "core", "title": "CDC emergency", "description": "d", "licence": "PD-USGov",
     "source": {"kind": "zimit", "name": "cdc_en", "seeds": ["https://www.cdc.gov/disasters/"], "scope": "https://www.cdc.gov/"}},
    {"id": "zim-ifixit", "kind": "zim", "tier": "free", "title": "iFixit", "description": "d", "licence": "CC-BY-NC-SA-3.0", "attribution": "iFixit",
     "source": {"kind": "kiwix_external", "category": "ifixit", "base": "ifixit_en_all"}},
]})
ENTRY = SPEC.by_id()

DATA = b"%PDF-1.4 fake zim bytes"
PLANET = PROTOMAPS_BUILD.format(date="20261019")


def cand(upstream_sha=sha(DATA), size=len(DATA)):
    return Candidate(ENTRY["zim-wikem"], "zim-wikem-2026-07", "zim/wikem_en_all_maxi_2026-07.zim", "2026-07", Upstream("https://k/w.zim", size, upstream_sha, "meta4"))


def pack(edition="2026-10"):
    return dated(ENTRY["docs-x"], edition, None)


def planet(size=len(DATA), build="20261019"):
    return dated(ENTRY["map-world-full"], "2026-10", Upstream(PROTOMAPS_BUILD.format(date=build), size, None, None))


@pytest.fixture
def ctx(tmp_path, monkeypatch):
    def fake_download(url, dest, log=print):
        Path(dest).parent.mkdir(parents=True, exist_ok=True)
        Path(dest).write_bytes(DATA)
        return dest
    monkeypatch.setattr(fetch, "download", fake_download)
    monkeypatch.setattr(fetch, "stream", lambda url: iter([DATA[:7], DATA[7:]]))
    monkeypatch.setattr(fetch, "download_pdf", fake_download)
    return BuildContext(content=tmp_path / "content", http=FakeHttp(), repo_root=tmp_path, log=lambda s: None)


def change_document(ctx, monkeypatch, doc_id: str, data: bytes):
    """A different upstream PDF next time the pack's inputs are read."""
    (docpack.documents_dir(ctx, "docs-x") / f"{doc_id}.pdf").unlink()

    def fake_download(url, dest, log=print):
        Path(dest).write_bytes(data)
        return dest
    monkeypatch.setattr(fetch, "download_pdf", fake_download)


def test_hash_cache_rehashes_only_when_size_or_mtime_change(tmp_path):
    f = tmp_path / "a.bin"
    f.write_bytes(b"one")
    cache = fetch.HashCache(tmp_path)
    assert cache.sha256(f) == sha(b"one")
    cache.data[os.path.relpath(f, tmp_path)]["sha256"] = "cached"
    assert cache.sha256(f) == "cached"
    f.write_bytes(b"three")
    assert cache.sha256(f) == sha(b"three")
    assert fetch.HashCache(tmp_path).sha256(f) == sha(b"three")


def test_passthrough_present_with_matching_sha_is_unchanged(ctx):
    store = FakeStore()
    store.put_stream(cand().path, iter([DATA]), sha(DATA), None)
    o = cv.converge(cand(), None, store, ctx, stream=False)
    assert o.action == "unchanged" and o.artefact.sha256 == sha(DATA) and o.artefact.id == "zim-wikem-2026-07"
    assert store.log == [("put_stream", cand().path)]


def test_passthrough_pretend_counts_as_present_and_records_without_upload_time(ctx):
    store = FakeStore(pretend={cand().path: ObjectInfo(cand().path, len(DATA), sha(DATA))})
    o = cv.converge(cand(), None, store, ctx, stream=False, store_is_real=False)
    assert o.action == "unchanged" and o.artefact.uploaded_at is None and o.source.url == "https://k/w.zim"


def test_passthrough_fetches_uploads_and_reuses_local_file_next_time(ctx):
    store = FakeStore()
    o = cv.converge(cand(), None, store, ctx, stream=False)
    assert o.action == "uploaded" and o.bytes == len(DATA) and store.get(cand().path) == DATA
    assert (ctx.content / cand().path).exists()
    again = cv.converge(cand(), None, FakeStore(), ctx, stream=False)
    assert again.action == "uploaded" and again.artefact.sha256 == sha(DATA)


def test_downloaded_sha_mismatch_fails_without_uploading(ctx):
    store = FakeStore()
    o = cv.converge(cand(upstream_sha="0" * 64), None, store, ctx, stream=False)
    assert o.action == "failed" and "expected 000000000000" in o.detail and store.log == []


def test_streamed_sha_mismatch_deletes_the_key(ctx):
    store = FakeStore()
    o = cv.converge(cand(upstream_sha="0" * 64), None, store, ctx, stream=True)
    assert o.action == "failed" and ("delete", cand().path) in store.log and store.head(cand().path) is None


def test_stream_uploads_hash_in_flight(ctx):
    store = FakeStore()
    o = cv.converge(cand(), None, store, ctx, stream=True)
    assert o.action == "streamed" and o.bytes == len(DATA) and store.get(cand().path) == DATA


def test_mirror_key_holding_different_bytes_is_a_failure_not_an_edition(ctx):
    store = FakeStore()
    store.put_stream(cand().path, iter([b"older bytes"]), sha(b"older bytes"), None)
    o = cv.converge(cand(), None, store, ctx, stream=False)
    assert o.action == "failed" and "already in the store" in o.detail and store.get(cand().path) == b"older bytes"
    assert store.list("zim/") == [store.head(cand().path)]


def test_stream_decision_is_by_size_and_flag():
    big = cand(size=10 ** 12)
    assert cv.stream_decision(big, free_bytes=300 * 10 ** 9)
    assert not cv.stream_decision(cand(size=10 ** 9), free_bytes=300 * 10 ** 9)
    assert cv.stream_decision(cand(size=10 ** 9), free_bytes=40 * 10 ** 9 + 10 ** 9 - 1)
    forced = Candidate(ENTRY["zim-wikem"].__class__(**{**ENTRY["zim-wikem"].__dict__, "stream": True}), "i", "p", None, Upstream("u", 1, None, None))
    assert cv.stream_decision(forced, free_bytes=10 ** 15)


def test_docpack_builds_deterministic_tar_with_sidecars_and_is_unchanged_on_rerun(ctx):
    c = pack()
    store = FakeStore()
    o = cv.converge(c, None, store, ctx, stream=False)
    assert o.action == "built" and set(o.inputs) == {"a", "b"} and o.inputs["b"]["url"] == "https://archive.org/download/I/b.pdf"
    assert (o.artefact.id, o.artefact.path) == ("docs-x-2026-10", "packs/docs-x_2026-10.tar.gz")
    with tarfile.open(ctx.content / "packs/docs-x.tar.gz") as tar:
        names = sorted(tar.getnames())
        side = json.loads(tar.extractfile("a.json").read())
    assert names == ["a.json", "a.pdf", "b.json", "b.pdf"]
    assert side == {"title": "A", "publisher": "EPA", "licence": "Public domain (US Government, 17 USC §105)", "role": "procedural", "sourceURL": "https://x/a.pdf"}
    lock = Lock()
    lock.record("docs-x", o.artefact, None, o.inputs)
    (ctx.content / "packs/docs-x.tar.gz").unlink()
    again = cv.converge(c, lock.entries["docs-x"], store, ctx, stream=False)
    assert again.action == "unchanged" and again.artefact == o.artefact and store.log == [("put_file", c.path)]
    assert not (ctx.content / "packs/docs-x.tar.gz").exists(), "unchanged inputs do not rebuild"
    rebuilt = cv.converge(c, None, FakeStore(), ctx, stream=False)
    assert rebuilt.artefact.sha256 == o.artefact.sha256


def test_changed_inputs_in_the_same_month_take_the_next_letter_and_replace_the_old_id(ctx, monkeypatch):
    store = FakeStore()
    lock = Lock()
    first = cv.converge(pack(), None, store, ctx, stream=False)
    lock.record("docs-x", first.artefact, None, first.inputs)
    change_document(ctx, monkeypatch, "a", b"%PDF-1.4 revised")
    second = cv.converge(pack(), lock.entries["docs-x"], store, ctx, stream=False)
    assert second.action == "built" and (second.artefact.id, second.artefact.path) == ("docs-x-2026-10b", "packs/docs-x_2026-10b.tar.gz")
    assert second.artefact.sha256 != first.artefact.sha256 and store.get(first.artefact.path) is not None
    lock.record("docs-x", second.artefact, None, second.inputs)
    assert lock.entries["docs-x"].history == ("docs-x-2026-10",)
    payload, _ = manifest.build_manifest(SPEC, lock, "v", "2026-10-20T00:00:00Z")
    assert next(a for a in payload["artefacts"] if a["id"] == "docs-x-2026-10b")["replaces"] == ["docs-x-2026-10"]
    change_document(ctx, monkeypatch, "b", b"%PDF-1.4 revised again")
    third = cv.converge(pack(), lock.entries["docs-x"], store, ctx, stream=False)
    assert third.artefact.id == "docs-x-2026-10c"
    lock.record("docs-x", third.artefact, None, third.inputs)
    assert lock.entries["docs-x"].history == ("docs-x-2026-10b", "docs-x-2026-10")


def test_a_rebuild_whose_bytes_match_the_stored_edition_keeps_it(ctx):
    store = FakeStore()
    first = cv.converge(pack(), None, store, ctx, stream=False)
    lock = Lock()
    lock.record("docs-x", first.artefact, None, {"stale": "pins from an older lock format"})
    again = cv.converge(pack(), lock.entries["docs-x"], store, ctx, stream=False)
    assert again.action == "unchanged" and again.artefact.id == "docs-x-2026-10" and again.artefact.uploaded_at == first.artefact.uploaded_at
    assert store.log == [("put_file", "packs/docs-x_2026-10.tar.gz")]


def test_a_run_that_died_between_upload_and_lock_write_converges_on_the_bumped_key(ctx, monkeypatch):
    store = FakeStore()
    lock = Lock()
    first = cv.converge(pack(), None, store, ctx, stream=False)
    lock.record("docs-x", first.artefact, None, first.inputs)
    change_document(ctx, monkeypatch, "a", b"%PDF-1.4 revised")
    cv.converge(pack(), lock.entries["docs-x"], store, ctx, stream=False)
    rerun = cv.converge(pack(), lock.entries["docs-x"], store, ctx, stream=False)
    assert rerun.action == "unchanged" and rerun.artefact.id == "docs-x-2026-10b"
    assert [k for op, k in store.log if op == "put_file"] == ["packs/docs-x_2026-10.tar.gz", "packs/docs-x_2026-10b.tar.gz"]


def test_planet_streams_without_a_sha_and_the_lock_records_what_was_sent(ctx):
    store = FakeStore()
    o = cv.converge(planet(), None, store, ctx, stream=True)
    assert o.action == "streamed" and (o.artefact.id, o.artefact.path) == ("map-world-full-2026-10", "maps/world-full_2026-10.pmtiles")
    assert (o.artefact.size, o.artefact.sha256) == (len(DATA), sha(DATA)) and store.head(o.artefact.path).sha256 is None
    assert o.inputs == {"build": "20261019", "maxzoom": 15, "bbox": None, "source": PLANET}
    lock = Lock()
    lock.record("map-world-full", o.artefact, o.source, o.inputs)
    again = cv.converge(planet(), lock.entries["map-world-full"], store, ctx, stream=True)
    assert again.action == "unchanged" and again.artefact == o.artefact
    newer = cv.converge(planet(build="20261025"), lock.entries["map-world-full"], store, ctx, stream=True)
    assert newer.action == "streamed" and newer.artefact.id == "map-world-full-2026-10b"
    short = cv.converge(planet(size=len(DATA) + 1), None, FakeStore(), ctx, stream=True)
    assert short.action == "failed" and "Content-Length" in short.detail


def test_zimit_crawls_with_a_browser_lang_code_and_a_zim_lang_code(ctx, monkeypatch):
    """browsertrix wants ISO-639-1 for --lang and exits 17 on `eng`; the ZIM metadata takes ISO-639-3 via --zim-lang."""
    calls = []

    def fake_run(cmd, check):
        calls.append(cmd)
        (ctx.content / "zim" / "cdc_en_2026-10.zim").write_bytes(b"zim")

    monkeypatch.setattr(zimit.shutil, "which", lambda name: "/usr/local/bin/docker")
    monkeypatch.setattr(zimit.subprocess, "run", fake_run)
    out = zimit.ZimitBuilder().build(dated(ENTRY["zim-cdc"], "2026-10b", None), ctx)
    assert out == ctx.content / "zim" / "cdc_en_2026-10.zim"
    [cmd] = calls
    flags = dict(zip(cmd, cmd[1:]))
    assert flags["--lang"] == "en" and flags["--zim-lang"] == "eng"
    assert flags["--zim-file"] == "cdc_en_2026-10.zim" and flags["--name"] == "cdc_en" and flags["--seeds"] == "https://www.cdc.gov/disasters/"


def external(sha=sha(DATA), size=len(DATA)):
    return Candidate(ENTRY["zim-ifixit"], "zim-ifixit-2025-12", "zim/ifixit_en_all_2025-12.zim", "2025-12",
                     Upstream("https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim", size, sha, "meta4"))


def test_external_entry_touches_no_store_and_locks_kiwix_facts(ctx):
    store = FakeStore()
    o = cv.converge(external(), None, store, ctx, stream=False)
    assert o.action == "external" and store.log == [] and store.list("") == []
    assert not (ctx.content / "zim").exists(), "nothing downloaded either"
    assert o.artefact.external_url == "https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim"
    assert (o.artefact.id, o.artefact.path, o.artefact.size, o.artefact.sha256, o.artefact.uploaded_at) == ("zim-ifixit-2025-12", "zim/ifixit_en_all_2025-12.zim", len(DATA), sha(DATA), None)
    assert not cv.stream_decision(external(size=10 ** 13), free_bytes=1), "claims no disk"
    lock = Lock()
    lock.record("zim-ifixit", o.artefact, o.source)
    lock_path = ctx.content.parent / "lock.json"
    lock.save(lock_path)
    row = json.loads(lock_path.read_text())["entries"]["zim-ifixit"]["artefact"]
    assert row["externalURL"] == o.artefact.external_url and row["uploadedAt"] is None
    assert Lock.load(lock_path).entries["zim-ifixit"].artefact == o.artefact


def test_external_entry_without_a_published_sha_fails(ctx):
    o = cv.converge(external(sha=None), None, FakeStore(), ctx, stream=False)
    assert o.action == "failed" and "meta4" in o.detail
