import json
from pathlib import Path

import pytest

from ovpub.spec import (ArchiveSource, DocumentsSource, KiwixSource, SpecError, load_spec, parse_spec)

HERE = Path(__file__).resolve().parent
SPEC = HERE.parent / "catalogue-spec.json"


def entry(**over):
    e = {"id": "zim-a", "kind": "zim", "tier": "core", "title": "A", "description": "a", "licence": "CC-BY-SA-4.0",
         "attribution": "People", "source": {"kind": "kiwix", "category": "other", "base": "a_en_all"}}
    e.update(over)
    return e


def spec(*entries, excluded=()):
    return {"version": "2026.10", "entries": list(entries), "excluded": list(excluded)}


def problems(data):
    with pytest.raises(SpecError) as ei:
        parse_spec(data)
    return "\n".join(ei.value.problems)


def test_committed_spec_parses_and_covers_every_tier():
    s = load_spec(SPEC)
    tiers = {e.tier for e in s.entries}
    assert tiers == {"free", "core", "full", "complete"}
    assert {e.id for e in s.within("free")} == {"zim-fieldguide", "zim-cdc-emergency", "zim-ready-gov", "docs-us-gov-preparedness", "map-world-low", "zim-ifixit", "zim-medlineplus"}
    assert "epa-emergency-disinfection-drinking-water" in s.documents()
    assert {x.id for x in s.excluded} >= {"zim-wikihow", "zim-cd3wd", "zim-lowtech", "zim-knots"}
    external = {e.id: e for e in s.entries if e.external}
    assert set(external) == {"zim-ifixit", "zim-medlineplus"} and {e.tier for e in external.values()} == {"free"}
    assert len(s.within("free")) < len(s.within("core")) < len(s.within("full")) < len(s.within("complete")) == len(s.entries)


def test_committed_spec_matches_migration_output():
    import migrate_spec
    old = json.loads((HERE / "fixtures/catalogue-spec.v1.json").read_text())
    assert json.loads(SPEC.read_text()) == migrate_spec.migrate(old)


def test_unknown_licence_is_refused():
    assert "not an allowed licence" in problems(spec(entry(licence="CC-BY-NC-SA-3.0")))
    assert "not an allowed licence" in problems(spec(entry(licence="WTFPL")))


EXTERNAL = {"kind": "kiwix_external", "category": "ifixit", "base": "ifixit_en_all"}


def test_external_source_takes_only_non_redistributable_licences():
    e = parse_spec(spec(entry(licence="CC-BY-NC-SA-3.0", source=EXTERNAL))).entries[0]
    assert e.external and e.licence_label == "CC BY-NC-SA 3.0"
    assert "use source kind kiwix" in problems(spec(entry(licence="CC-BY-SA-4.0", source=EXTERNAL)))
    assert "attribution: required" in problems(spec(entry(licence="CC-BY-NC-SA-3.0", attribution=None, source=EXTERNAL)))
    text = problems(spec(entry(licence="CC-BY-NC-SA-3.0")))
    assert "not an allowed licence" in text and "kiwix_external" in text
    assert "CC-BY-NC-SA-3.0" not in text.split("kiwix_external")[0].split("(")[1], "the allowed list for a stored entry never names an NC licence"
    assert not parse_spec(spec(entry())).entries[0].external


def test_attribution_required_for_by_sa_and_ogl_but_not_pd():
    assert "attribution: required" in problems(spec(entry(attribution=None)))
    assert "attribution: required" in problems(spec(entry(licence="OGL-3.0", attribution="  ")))
    parse_spec(spec(entry(licence="PD-USGov", attribution=None)))


def test_prefix_colliding_and_duplicate_ids_fail():
    assert "prefix" in problems(spec(entry(id="zim-ready-gov"), entry(id="zim-ready-gov-es")))
    assert "duplicate id" in problems(spec(entry(), entry()))


def test_id_in_both_entries_and_excluded_fails():
    assert "both entries and excluded" in problems(spec(entry(), excluded=[{"id": "zim-a", "reason": "x"}]))


def test_replaces_entry_must_exist():
    assert "replacesEntry" in problems(spec(entry(replacesEntry="zim-nope")))


def test_document_without_verified_url_fails():
    docs = {"kind": "documents", "documents": [{"id": "d", "title": "D", "licence": "PD-USGov", "url": "MANUAL: open the page"}]}
    assert "not a verified URL" in problems(spec(entry(kind="document-pack", licence="PD-USGov", source=docs)))
    docs["documents"][0] = {"id": "d", "title": "D", "licence": "PD-USGov"}
    assert "needs url or archive" in problems(spec(entry(kind="document-pack", licence="PD-USGov", source=docs)))


def test_document_licence_gate_applies_per_document():
    docs = {"kind": "documents", "documents": [{"id": "d", "title": "D", "licence": "CC-BY-NC-SA-3.0", "url": "https://x/y.pdf"}]}
    assert "documents.d.licence" in problems(spec(entry(kind="document-pack", licence="PD-USGov", source=docs)))


def test_every_problem_is_reported_at_once():
    text = problems(spec(entry(licence="Mixed", kind="video", tier="gold", source={"kind": "ftp"})))
    assert all(k in text for k in ("licence", "kind", "tier", "source.kind"))


def test_sources_parse_to_their_types():
    s = parse_spec(spec(
        entry(),
        entry(id="docs-b", kind="document-pack", licence="PD-USGov", attribution=None,
              source={"kind": "documents", "documents": [{"id": "d", "title": "D", "licence": "PD-USGov", "archive": {"item": "I", "file": "A B.pdf"}}]})))
    a, b = s.entries
    assert isinstance(a.source, KiwixSource) and a.dated
    assert isinstance(b.source, DocumentsSource) and not b.dated
    assert isinstance(b.source.documents[0].source, ArchiveSource)
    assert b.source.documents[0].source.url == "https://archive.org/download/I/A%20B.pdf"
