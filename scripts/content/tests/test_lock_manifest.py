import json

from ovpub import manifest
from ovpub.lock import ArtefactFacts, Lock, SourceFacts
from ovpub.spec import parse_spec

NOW = "2026-10-20T02:00:00Z"


def kiwix_entry(id_, tier="core", **over):
    e = {"id": id_, "kind": "zim", "tier": tier, "title": id_.title(), "description": "d", "licence": "CC-BY-SA-4.0",
         "attribution": "People", "role": "procedural", "language": "eng",
         "source": {"kind": "kiwix", "category": "other", "base": id_.replace("-", "_")}}
    e.update(over)
    return e


def art(id_, path, sha="a" * 64, size=10):
    return ArtefactFacts(id_, path, size, sha, NOW)


SPEC = parse_spec({"version": "2026.10", "excluded": [], "entries": [
    kiwix_entry("zim-wikem"),
    kiwix_entry("zim-nopic", "full"),
    kiwix_entry("zim-maxi", "complete", replacesEntry="zim-nopic", stream=True),
    {"id": "model-q", "kind": "model", "tier": "core", "title": "Q", "description": "d", "licence": "Apache-2.0",
     "source": {"kind": "url", "url": "https://hf/q.gguf"}},
    {"id": "zim-ifixit", "kind": "zim", "tier": "free", "title": "iFixit", "description": "Repair guides.", "licence": "CC-BY-NC-SA-3.0",
     "attribution": "iFixit; ZIM by Kiwix", "role": "procedural", "source": {"kind": "kiwix_external", "category": "ifixit", "base": "ifixit_en_all"}},
]})
KIWIX = "https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim"


def test_record_pushes_history_newest_first_and_is_idempotent(tmp_path):
    lock = Lock()
    lock.record("zim-wikem", art("zim-wikem-2026-03", "zim/w_2026-03.zim"))
    lock.record("zim-wikem", art("zim-wikem-2026-03", "zim/w_2026-03.zim"))
    assert lock.entries["zim-wikem"].history == ()
    lock.record("zim-wikem", art("zim-wikem-2026-07", "zim/w_2026-07.zim", sha="b" * 64))
    lock.record("zim-wikem", art("zim-wikem-2026-10", "zim/w_2026-10.zim", sha="c" * 64))
    assert lock.entries["zim-wikem"].history == ("zim-wikem-2026-07", "zim-wikem-2026-03")
    p = tmp_path / "lock.json"
    lock.save(p)
    again = Lock.load(p)
    assert again.entries == lock.entries
    assert not (tmp_path / "lock.json.tmp").exists()


def test_history_is_capped():
    lock = Lock()
    for i in range(20):
        lock.record("zim-wikem", art(f"zim-wikem-{i:02d}", f"zim/w_{i}.zim", sha=f"{i:064d}"))
    assert len(lock.entries["zim-wikem"].history) == 12
    assert lock.entries["zim-wikem"].history[0] == "zim-wikem-18"


def test_manifest_is_deterministic_and_covers_every_locked_tier():
    lock = Lock()
    lock.record("zim-wikem", art("zim-wikem-2026-07", "zim/wikem_2026-07.zim"), SourceFacts("https://k/wikem_2026-07.zim", 10, "a" * 64, "2026-07", NOW, "meta4"))
    lock.record("zim-nopic", art("zim-nopic-2026-06", "zim/nopic_2026-06.zim", sha="b" * 64))
    lock.record("model-q", art("model-q", "models/q.gguf", sha="c" * 64))
    one, cat1 = manifest.build_manifest(SPEC, lock, "2026.10.20", NOW)
    two, cat2 = manifest.build_manifest(SPEC, lock, "2026.10.20", NOW)
    assert one == two and cat1 == cat2
    ids = [a["id"] for a in one["artefacts"]]
    assert ids == ["catalogue", "model-q", "zim-nopic-2026-06", "zim-wikem-2026-07"]
    assert [a["tier"] for a in one["artefacts"]] == ["free", "core", "full", "core"], "the catalogue itself is free; the rest carry their spec tier"
    cat = json.loads(cat1)
    wikem = next(e for e in cat["entries"] if e["artefactId"] == "zim-wikem-2026-07")
    assert wikem["licence"] == "CC BY-SA 4.0" and wikem["fileName"] == "wikem_2026-07" and wikem["sourceURL"].endswith("wikem_2026-07.zim")
    assert one["artefacts"][0]["path"] == "catalogue/catalogue-2026.10.20.json"
    assert all("replacesId" not in a for a in one["artefacts"])


def test_replaces_lists_own_history_then_replaced_entry_and_its_history():
    lock = Lock()
    lock.record("zim-nopic", art("zim-nopic-2026-03", "zim/n_03.zim"))
    lock.record("zim-nopic", art("zim-nopic-2026-06", "zim/n_06.zim", sha="b" * 64))
    lock.record("zim-maxi", art("zim-maxi-2026-05", "zim/m_05.zim", sha="c" * 64))
    lock.record("zim-maxi", art("zim-maxi-2026-08", "zim/m_08.zim", sha="d" * 64))
    payload, _ = manifest.build_manifest(SPEC, lock, "v", NOW)
    by = {a["id"]: a for a in payload["artefacts"]}
    assert by["zim-maxi-2026-08"]["replaces"] == ["zim-maxi-2026-05", "zim-nopic-2026-06", "zim-nopic-2026-03"]
    assert by["zim-nopic-2026-06"]["replaces"] == ["zim-nopic-2026-03"]


def test_entries_dropped_from_spec_leave_the_manifest():
    lock = Lock()
    lock.record("zim-gone", art("zim-gone-2026-01", "zim/g.zim"))
    lock.record("zim-wikem", art("zim-wikem-2026-07", "zim/w.zim", sha="b" * 64))
    payload, _ = manifest.build_manifest(SPEC, lock, "v", NOW)
    assert [a["id"] for a in payload["artefacts"]] == ["catalogue", "zim-wikem-2026-07"]


def test_is_noop_ignores_version_and_catalogue_artefact_but_not_content():
    lock = Lock()
    lock.record("zim-wikem", art("zim-wikem-2026-07", "zim/w.zim"))
    a, ca = manifest.build_manifest(SPEC, lock, "2026.10.20", NOW)
    b, cb = manifest.build_manifest(SPEC, lock, "2026.10.21", "2026-10-21T02:00:00Z")
    assert manifest.is_noop(b, a, cb, ca)
    assert not manifest.is_noop(b, None)
    lock.record("zim-wikem", art("zim-wikem-2026-10", "zim/w10.zim", sha="e" * 64))
    c, cc = manifest.build_manifest(SPEC, lock, "2026.10.21", NOW)
    assert not manifest.is_noop(c, a, cc, ca)
    retitled = parse_spec({"version": "2026.10", "excluded": [], "entries": [kiwix_entry("zim-wikem", title="Renamed")]})
    lock2 = Lock()
    lock2.record("zim-wikem", art("zim-wikem-2026-07", "zim/w.zim"))
    d, cd = manifest.build_manifest(retitled, lock2, "v", NOW)
    assert not manifest.is_noop(d, a, cd, ca)


def test_external_artefact_carries_the_kiwix_block_and_the_catalogue_names_the_licence():
    lock = Lock()
    lock.record("zim-ifixit", ArtefactFacts("zim-ifixit-2025-12", "zim/ifixit_en_all_2025-12.zim", 3570696192, "f" * 64, None, KIWIX),
                SourceFacts(KIWIX, 3570696192, "f" * 64, "2025-12", NOW, "meta4"))
    lock.record("zim-wikem", art("zim-wikem-2026-07", "zim/wikem_2026-07.zim"))
    payload, cat = manifest.build_manifest(SPEC, lock, "v", NOW)
    by = {a["id"]: a for a in payload["artefacts"]}
    ifixit = by["zim-ifixit-2025-12"]
    assert ifixit["external"] == {"url": KIWIX, "shaSource": "kiwix-meta4", "licence": "CC BY-NC-SA 3.0", "attribution": "iFixit; ZIM by Kiwix"}
    assert ifixit["path"] == "zim/ifixit_en_all_2025-12.zim" and ifixit["sizeBytes"] == 3570696192 and ifixit["sha256"] == "f" * 64 and ifixit["tier"] == "free"
    assert "external" not in by["zim-wikem-2026-07"]
    row = next(e for e in json.loads(cat)["entries"] if e["artefactId"] == "zim-ifixit-2025-12")
    assert row["licence"] == "CC BY-NC-SA 3.0" and row["sourceURL"] == KIWIX and row["fileName"] == "ifixit_en_all_2025-12"


def test_lock_and_spec_must_agree_on_what_is_external():
    import pytest
    stored = Lock()
    stored.record("zim-ifixit", art("zim-ifixit-2025-12", "zim/ifixit_en_all_2025-12.zim"))
    with pytest.raises(ValueError, match="zim-ifixit"):
        manifest.build_manifest(SPEC, stored, "v", NOW)
    external = Lock()
    external.record("zim-wikem", ArtefactFacts("zim-wikem-2026-07", "zim/w.zim", 1, "a" * 64, None, KIWIX))
    with pytest.raises(ValueError, match="zim-wikem"):
        manifest.build_manifest(SPEC, external, "v", NOW)
