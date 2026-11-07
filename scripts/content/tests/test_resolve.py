from datetime import date
from pathlib import Path

import pytest

from ovpub import resolve
from ovpub.spec import parse_spec

FIX = Path(__file__).resolve().parent / "fixtures"


class FakeHttp:
    def __init__(self, texts=None, heads=None, jsons=None):
        self.texts, self.heads, self.jsons = texts or {}, heads or {}, jsons or {}
        self.calls = []

    def get_text(self, url):
        self.calls.append(("GET", url))
        if url in self.texts:
            return self.texts[url]
        raise ConnectionError(url)

    def get_json(self, url):
        self.calls.append(("GET", url))
        if url in self.jsons:
            return self.jsons[url]
        raise ConnectionError(url)

    def head(self, url):
        self.calls.append(("HEAD", url))
        if url in self.heads:
            return self.heads[url]
        return None


def spec_with(*entries):
    return parse_spec({"version": "2026.10", "excluded": [], "entries": list(entries)})


WIKEM = {"id": "zim-wikem", "kind": "zim", "tier": "core", "title": "WikEM", "description": "d", "licence": "CC-BY-SA-4.0",
         "attribution": "x", "source": {"kind": "kiwix", "category": "other", "base": "wikem_en_all_maxi"}}
LISTING = "https://download.kiwix.org/zim/other/"


def test_newest_edition_prefers_suffix_and_ignores_other_flavours():
    names = ["nhs.uk_en_medicines_2025-12.zim", "nhs.uk_en_medicines_2026-09b.zim", "nhs.uk_en_medicines_2026-09.zim", "nhs.uk_en_medicines_nopic_2026-10.zim"]
    assert resolve.newest_edition(names, "nhs.uk_en_medicines") == ("nhs.uk_en_medicines_2026-09b.zim", "2026-09b")
    assert resolve.newest_edition(names, "wikem_en_all_maxi") is None


def test_kiwix_from_saved_listing_and_meta4():
    http = FakeHttp(texts={LISTING: (FIX / "kiwix-listing-other.html").read_text(),
                           LISTING + "wikem_en_all_maxi_2026-07.zim.meta4": (FIX / "wikem_en_all_maxi_2026-07.zim.meta4").read_text()})
    c = resolve.resolve(spec_with(WIKEM).entries[0], http, date(2026, 10, 19))
    assert c.artefact_id == "zim-wikem-2026-07" and c.path == "zim/wikem_en_all_maxi_2026-07.zim" and c.edition == "2026-07"
    assert c.upstream.url == LISTING + "wikem_en_all_maxi_2026-07.zim"
    assert c.upstream.size == 374632362
    assert c.upstream.sha256 == "7bbdd705544616df1ff37f8b4e0e5382e7b4d92532feecea42227af4169fbd7f" and c.upstream.sha_source == "meta4"
    assert c.passthrough


def test_kiwix_falls_back_to_opds_then_head_when_listing_is_down():
    opds = ('<feed><entry><link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" '
            'href="https://lb.download.kiwix.org/zim/other/wikem_en_all_maxi_2026-07.zim.meta4" length="1"/></entry>'
            '<entry><link href="https://lb.download.kiwix.org/zim/other/wikem_en_all_nopic_2026-07.zim.meta4"/></entry></feed>')
    http = FakeHttp(texts={resolve.KIWIX_OPDS.format(name="wikem_en_all"): opds},
                    heads={LISTING + "wikem_en_all_maxi_2026-07.zim": {"content-length": "42"}})
    c = resolve.resolve(spec_with(WIKEM).entries[0], http)
    assert c.artefact_id == "zim-wikem-2026-07" and c.upstream.size == 42 and c.upstream.sha256 is None


def test_kiwix_unreachable_everywhere_raises():
    with pytest.raises(resolve.ResolveError, match="listing failed"):
        resolve.resolve(spec_with(WIKEM).entries[0], FakeHttp())


def test_huggingface_url_gets_sha_from_lfs_oid():
    url = "https://huggingface.co/unsloth/Q-GGUF/resolve/main/Q4.gguf"
    http = FakeHttp(heads={url: {"content-length": "10"}},
                    jsons={resolve.HF_TREE.format(repo="unsloth/Q-GGUF"): [{"path": "Q4.gguf", "size": 10, "lfs": {"oid": "AB" * 32}}]})
    e = {"id": "model-q", "kind": "model", "tier": "core", "title": "Q", "description": "d", "licence": "Apache-2.0", "source": {"kind": "url", "url": url}}
    c = resolve.resolve(spec_with(e).entries[0], http)
    assert c.path == "models/Q4.gguf" and c.artefact_id == "model-q" and c.edition is None
    assert c.upstream.sha256 == "ab" * 32 and c.upstream.sha_source == "hf" and c.passthrough


def test_built_zimit_and_documents_are_dated_by_month_without_network():
    fg = {"id": "zim-fieldguide", "kind": "zim", "tier": "core", "title": "FG", "description": "d", "licence": "CC-BY-SA-4.0", "attribution": "x",
          "source": {"kind": "built", "builder": "fieldguide"}}
    zt = {"id": "zim-cdc", "kind": "zim", "tier": "core", "title": "C", "description": "d", "licence": "PD-USGov",
          "source": {"kind": "zimit", "name": "cdc_en", "seeds": ["https://cdc.gov/"]}}
    dp = {"id": "docs-x", "kind": "document-pack", "tier": "core", "title": "X", "description": "d", "licence": "PD-USGov",
          "source": {"kind": "documents", "documents": [{"id": "a", "title": "A", "licence": "PD-USGov", "url": "https://x/a.pdf"}]}}
    http = FakeHttp()
    a, b, c = (resolve.resolve(e, http, date(2026, 10, 19)) for e in spec_with(fg, zt, dp).entries)
    assert (a.artefact_id, a.path) == ("zim-fieldguide-2026-10", "zim/fieldguide_en_2026-10.zim")
    assert (b.artefact_id, b.path) == ("zim-cdc-2026-10", "zim/cdc_en_2026-10.zim")
    assert (c.artefact_id, c.path, c.edition) == ("docs-x-2026-10", "packs/docs-x_2026-10.tar.gz", "2026-10")
    assert http.calls == [] and not any(x.passthrough or x.mirror for x in (a, b, c))
    bumped = c.with_edition(resolve.Edition.parse(c.edition).bump())
    assert (bumped.artefact_id, bumped.path, bumped.edition) == ("docs-x-2026-10b", "packs/docs-x_2026-10b.tar.gz", "2026-10b")


def test_edition_bumps_kiwix_style_and_mirrors_keep_upstream_names():
    e = resolve.Edition.parse("2026-10")
    assert str(e.bump()) == "2026-10b" and str(e.bump().bump()) == "2026-10c" and e.bump().month == "2026-10"
    assert resolve.Edition.parse("2026-10b") == resolve.Edition("2026-10", "b")
    with pytest.raises(ValueError):
        resolve.Edition.parse("20261019")
    with pytest.raises(ValueError):
        resolve.Edition("2026-10", "z").bump()
    http = FakeHttp(texts={LISTING: '<a href="wikem_en_all_maxi_2026-07.zim">x</a>'}, heads={LISTING + "wikem_en_all_maxi_2026-07.zim": {"content-length": "1"}})
    c = resolve.resolve(spec_with(WIKEM).entries[0], http)
    assert c.mirror
    with pytest.raises(resolve.ResolveError):
        c.with_edition("2026-10")


def test_protomaps_build_is_the_newest_that_answers_and_extracts_are_not_passthrough():
    http = FakeHttp(heads={resolve.PROTOMAPS_BUILD.format(date="20261018"): {"content-length": "138980000000"}})
    low = {"id": "map-world-low", "kind": "map", "tier": "core", "title": "L", "description": "d", "licence": "ODbL-1.0", "attribution": "OSM",
           "source": {"kind": "map_extract", "maxzoom": 7}}
    full = dict(low, id="map-world-full", tier="complete", stream=True, source={"kind": "map_extract", "maxzoom": 15})
    a, b = (resolve.resolve(e, http, date(2026, 10, 19)) for e in spec_with(low, full).entries)
    assert a.path == "maps/world-low_2026-10.pmtiles" and a.artefact_id == "map-world-low-2026-10" and not a.passthrough
    assert b.path == "maps/world-full_2026-10.pmtiles" and b.passthrough and not b.mirror and b.upstream.size == 138980000000
    assert a.upstream.url == b.upstream.url == resolve.PROTOMAPS_BUILD.format(date="20261018")


def test_archive_source_resolves_through_metadata_api():
    http = FakeHttp(jsons={resolve.ARCHIVE_METADATA.format(item="FM4-25.11"): {"files": [{"name": "FM4-25.11.pdf", "size": "2455031", "sha1": "x"}]}})
    from ovpub.spec import ArchiveSource
    up = resolve.resolve_archive(ArchiveSource("FM4-25.11", "FM4-25.11.pdf"), http)
    assert up.size == 2455031 and up.url == "https://archive.org/download/FM4-25.11/FM4-25.11.pdf" and up.sha256 is None
    with pytest.raises(resolve.ResolveError, match="no file"):
        resolve.resolve_archive(ArchiveSource("FM4-25.11", "other.pdf"), http)


def test_kiwix_download_url_can_come_from_a_mirror(monkeypatch):
    """Resolution and the checksum stay on download.kiwix.org; only the bytes come from the mirror."""
    import importlib
    from ovpub import resolve as r
    monkeypatch.setenv("OV_KIWIX_MIRROR", "https://mirror.example.org/kiwix/zim")
    importlib.reload(r)
    try:
        class H:
            def get_text(self, url):
                if url.endswith("/"): return '<a href="wikem_en_all_maxi_2026-07.zim">x</a>'
                if url.endswith(".meta4"):
                    assert url.startswith("https://download.kiwix.org/"), url
                    return ('<metalink xmlns="urn:ietf:params:xml:ns:metalink"><file name="x"><size>10</size>'
                            '<hash type="sha-256">' + "a" * 64 + '</hash></file></metalink>')
                raise AssertionError(url)
            def head(self, url): return {"content-length": "10"}
        name, edition, up = r.resolve_kiwix(r.KiwixSource(category="other", base="wikem_en_all_maxi"), H())
        assert name == "wikem_en_all_maxi_2026-07.zim" and edition == "2026-07"
        assert up.url == "https://mirror.example.org/kiwix/zim/other/wikem_en_all_maxi_2026-07.zim"
        assert up.sha256 == "a" * 64
    finally:
        monkeypatch.delenv("OV_KIWIX_MIRROR")
        importlib.reload(r)


def test_kiwix_falls_back_to_the_canonical_host_when_the_mirror_lacks_the_file(monkeypatch):
    import importlib
    from ovpub import resolve as r
    monkeypatch.setenv("OV_KIWIX_MIRROR", "https://mirror.example.org/kiwix/zim")
    importlib.reload(r)
    try:
        class H:
            def get_text(self, url):
                if url.endswith("/"): return '<a href="wikem_en_all_maxi_2026-07.zim">x</a>'
                return ('<metalink xmlns="urn:ietf:params:xml:ns:metalink"><file name="x"><size>10</size>'
                        '<hash type="sha-256">' + "a" * 64 + '</hash></file></metalink>')
            def head(self, url):
                return None if url.startswith("https://mirror.example.org/") else {"content-length": "10"}
        _, _, up = r.resolve_kiwix(r.KiwixSource(category="other", base="wikem_en_all_maxi"), H())
        assert up.url == "https://download.kiwix.org/zim/other/wikem_en_all_maxi_2026-07.zim"
    finally:
        monkeypatch.delenv("OV_KIWIX_MIRROR")
        importlib.reload(r)


def test_external_kiwix_entry_resolves_like_kiwix_but_keeps_the_canonical_url(monkeypatch):
    import importlib
    from ovpub import resolve as r
    monkeypatch.setenv("OV_KIWIX_MIRROR", "https://mirror.example.org/kiwix/zim")
    importlib.reload(r)
    try:
        ext = dict(WIKEM, id="zim-ifixit", tier="free", licence="CC-BY-NC-SA-3.0", source={"kind": "kiwix_external", "category": "other", "base": "wikem_en_all_maxi"})
        http = FakeHttp(texts={LISTING: (FIX / "kiwix-listing-other.html").read_text(),
                               LISTING + "wikem_en_all_maxi_2026-07.zim.meta4": (FIX / "wikem_en_all_maxi_2026-07.zim.meta4").read_text()})
        c = r.resolve(spec_with(ext).entries[0], http, date(2026, 10, 19))
        assert c.external and not c.mirror and c.passthrough
        assert c.artefact_id == "zim-ifixit-2026-07" and c.path == "zim/wikem_en_all_maxi_2026-07.zim" and c.edition == "2026-07"
        assert c.upstream.url == LISTING + "wikem_en_all_maxi_2026-07.zim", "never a mirror: the app downloads this months later"
        assert c.upstream.sha256 == "7bbdd705544616df1ff37f8b4e0e5382e7b4d92532feecea42227af4169fbd7f" and c.upstream.size == 374632362
        assert not any(m == "HEAD" and u.startswith("https://mirror.example.org/") for m, u in http.calls)
    finally:
        monkeypatch.delenv("OV_KIWIX_MIRROR")
        importlib.reload(r)
