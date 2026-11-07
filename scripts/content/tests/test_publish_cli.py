"""publish.py end to end against the fake store: resolve (fake http), converge, lock, manifest, sign."""
import json
from pathlib import Path

import publish
from ovpub import fetch, sign
from ovpub.lock import ArtefactFacts, Lock, SourceFacts
from tests.test_resolve import FakeHttp

ROOT = Path(__file__).resolve().parents[3]
FIX = Path(__file__).resolve().parent / "fixtures"
DEV_KEY = ROOT / "scripts/dev-keys/licence-private.key"
DEV_PUB = (ROOT / "scripts/dev-keys/licence-public.key").read_text().strip()
LISTING = "https://download.kiwix.org/zim/other/"

SPEC = {"version": "2026.10", "excluded": [], "entries": [
    {"id": "zim-wikem", "kind": "zim", "tier": "core", "title": "WikEM", "description": "d", "licence": "CC-BY-SA-4.0", "attribution": "x", "role": "procedural",
     "source": {"kind": "kiwix", "category": "other", "base": "wikem_en_all_maxi"}},
    {"id": "zim-nopic", "kind": "zim", "tier": "full", "title": "Nopic", "description": "d", "licence": "CC-BY-SA-4.0", "attribution": "x",
     "source": {"kind": "kiwix", "category": "wikipedia", "base": "wikipedia_en_all_nopic"}},
]}
CRAWL = {"id": "zim-crawl", "kind": "zim", "tier": "free", "title": "Crawl", "description": "d", "licence": "PD-USGov", "attribution": "x",
         "source": {"kind": "zimit", "name": "crawl_en", "seeds": ["https://example.gov/a"], "scope": "https://example.gov/a"}}


def setup(tmp_path, monkeypatch):
    spec = tmp_path / "spec.json"
    spec.write_text(json.dumps(SPEC))
    lock_path = tmp_path / "lock.json"
    lock = Lock()
    lock.record("zim-nopic", ArtefactFacts("zim-nopic-2026-06", "zim/wikipedia_en_all_nopic_2026-06.zim", 5, "b" * 64, "2026-07-01T00:00:00Z"),
                SourceFacts("https://k/n.zim", 5, "b" * 64, "2026-06", "2026-07-01T00:00:00Z", "meta4"))
    lock.save(lock_path)
    http = FakeHttp(texts={LISTING: (FIX / "kiwix-listing-other.html").read_text(),
                           LISTING + "wikem_en_all_maxi_2026-07.zim.meta4": (FIX / "wikem_en_all_maxi_2026-07.zim.meta4").read_text()})
    monkeypatch.setattr(publish, "SPEC_PATH", spec)
    monkeypatch.setattr(publish, "LOCK_PATH", lock_path)
    monkeypatch.setattr(publish, "REPORTS", tmp_path / "reports")
    monkeypatch.setattr(publish, "RequestsHttp", lambda: http)
    return lock_path


def run(tmp_path, *args):
    return publish.main(["--content", str(tmp_path / "content"), "--key", str(DEV_KEY), "--key-id", "dev-2026", *args])


def test_publish_core_with_fake_store_signs_manifest_keeps_other_tiers_and_is_noop_second_time(tmp_path, monkeypatch):
    lock_path = setup(tmp_path, monkeypatch)
    out = tmp_path / "out"
    assert run(tmp_path, "publish", "--tier", "core", "--store", "fake", "--out", str(out), "--version", "2026.10.20") == 0

    env = json.loads((out / "manifest.json").read_text())
    payload = json.loads(sign.verify(env, DEV_PUB, key_id="dev-2026"))
    ids = [a["id"] for a in payload["artefacts"]]
    assert ids == ["catalogue", "zim-nopic-2026-06", "zim-wikem-2026-07"]
    wikem = payload["artefacts"][2]
    assert wikem["sha256"] == "7bbdd705544616df1ff37f8b4e0e5382e7b4d92532feecea42227af4169fbd7f" and wikem["sizeBytes"] == 374632362
    assert wikem["tier"] == "core" and payload["artefacts"][1]["tier"] == "full" and wikem["replaces"] == []
    assert (out / "manifests/manifest-2026.10.20.json").read_bytes() == (out / "manifest.json").read_bytes()
    catalogue = json.loads((out / payload["artefacts"][0]["path"]).read_text())
    assert [e["artefactId"] for e in catalogue["entries"]] == ["zim-nopic-2026-06", "zim-wikem-2026-07"]

    lock = Lock.load(lock_path)
    assert lock.entries["zim-wikem"].artefact.id == "zim-wikem-2026-07" and lock.entries["zim-wikem"].artefact.uploaded_at is None
    assert lock.entries["zim-nopic"].artefact.id == "zim-nopic-2026-06"
    assert lock.spec_version == "2026.10"
    latest = json.loads((tmp_path / "reports/latest.json").read_text())
    assert latest["result"] == "published" and latest["counts"] == {"unchanged": 1}

    assert run(tmp_path, "publish", "--tier", "core", "--store", "fake", "--out", str(out), "--version", "2026.10.21") == 0
    assert not (out / "manifests/manifest-2026.10.21.json").exists()
    assert json.loads((tmp_path / "reports/latest.json").read_text())["result"] == "unchanged"


def test_frozen_publish_uses_lock_without_resolving(tmp_path, monkeypatch):
    lock_path = setup(tmp_path, monkeypatch)
    # A built artefact records no source in the lock; frozen mode must still keep it, edition and all, without building.
    from ovpub.builders import zimit
    (tmp_path / "spec.json").write_text(json.dumps({**SPEC, "entries": SPEC["entries"] + [CRAWL]}))
    lock = Lock.load(lock_path)
    lock.record("zim-crawl", ArtefactFacts("zim-crawl-2026-10b", "zim/crawl_en_2026-10b.zim", 7, "c" * 64, "2026-10-20T00:00:00Z"), None,
                inputs={"seeds": CRAWL["source"]["seeds"], "scope": CRAWL["source"]["scope"], "month": "2026-10", "image": zimit.IMAGE})
    lock.save(lock_path)
    monkeypatch.setattr(publish, "RequestsHttp", lambda: FakeHttp())
    out = tmp_path / "out"
    assert run(tmp_path, "publish", "--tier", "complete", "--store", "fake", "--out", str(out), "--version", "v", "--frozen") == 0
    payload = json.loads(sign.verify(json.loads((out / "manifest.json").read_text()), DEV_PUB))
    assert [a["id"] for a in payload["artefacts"]] == ["catalogue", "zim-crawl-2026-10b", "zim-nopic-2026-06"]
    assert [a["tier"] for a in payload["artefacts"]] == ["free", "free", "full"]
    assert Lock.load(lock_path).entries["zim-nopic"].artefact.uploaded_at == "2026-07-01T00:00:00Z"
    assert Lock.load(lock_path).entries["zim-crawl"].artefact.id == "zim-crawl-2026-10b"


def test_publish_dates_a_document_pack_and_bumps_its_edition_when_a_document_changes(tmp_path, monkeypatch):
    lock_path = setup(tmp_path, monkeypatch)
    spec = dict(SPEC, entries=SPEC["entries"] + [
        {"id": "docs-x", "kind": "document-pack", "tier": "core", "title": "X", "description": "d", "licence": "PD-USGov", "role": "procedural",
         "source": {"kind": "documents", "documents": [{"id": "a", "title": "A", "licence": "PD-USGov", "url": "https://x/a.pdf"}]}}])
    publish.SPEC_PATH.write_text(json.dumps(spec))
    pdf = {"bytes": b"%PDF-1.4 one"}

    def fake_download(url, dest, log=print):
        Path(dest).parent.mkdir(parents=True, exist_ok=True)
        Path(dest).write_bytes(pdf["bytes"])
        return dest
    monkeypatch.setattr(fetch, "download_pdf", fake_download)
    out = tmp_path / "out"
    month = publish.datetime.now(publish.timezone.utc).strftime("%Y-%m")
    assert run(tmp_path, "publish", "--tier", "core", "--store", "fake", "--out", str(out), "--version", "1") == 0
    first = json.loads(sign.verify(json.loads((out / "manifest.json").read_text()), DEV_PUB, key_id="dev-2026"))
    by = {a["id"]: a for a in first["artefacts"]}
    assert by[f"docs-x-{month}"]["path"] == f"packs/docs-x_{month}.tar.gz" and by[f"docs-x-{month}"]["replaces"] == []

    pdf["bytes"] = b"%PDF-1.4 two"
    (tmp_path / "content/documents/docs-x/a.pdf").unlink()
    assert run(tmp_path, "publish", "--tier", "core", "--store", "fake", "--out", str(out), "--version", "2") == 0
    second = json.loads(sign.verify(json.loads((out / "manifest.json").read_text()), DEV_PUB, key_id="dev-2026"))
    by = {a["id"]: a for a in second["artefacts"]}
    assert f"docs-x-{month}" not in by
    assert by[f"docs-x-{month}b"]["path"] == f"packs/docs-x_{month}b.tar.gz" and by[f"docs-x-{month}b"]["replaces"] == [f"docs-x-{month}"]
    assert (out / f"packs/docs-x_{month}.tar.gz").exists() and (out / f"packs/docs-x_{month}b.tar.gz").exists()
    assert Lock.load(lock_path).entries["docs-x"].history == (f"docs-x-{month}",)
