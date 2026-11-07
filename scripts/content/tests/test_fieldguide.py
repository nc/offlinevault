from datetime import date
from pathlib import Path

import pytest

from ovpub.fieldguide import build as build_mod
from ovpub.fieldguide import mediawiki, pdf, render
from ovpub.fieldguide.spec import GuideError, MediaWikiRef, PdfRef, load_guide
from ovpub.fieldguide.validate import validate
from ovpub.spec import load_spec

CONTENT = Path(__file__).resolve().parents[1]
GUIDE = CONTENT / "fieldguide"
FIXTURE_SLUGS = ("boil-bleach-filter", "finding-water", "storing-water", "bleeding-control", "cpr-and-choking", "shock", "burns",
                 "safe-canning-principles", "staying-warm-indoors", "go-bag")

PARSOID = """<html about="//en.wikipedia.org/wiki/Special:Redirect/revision/123"><head><title>Tourniquet</title></head><body>
<section data-mw-section-id="0"><p>Lead <span class="shortdescription">x</span><sup class="reference"><a href="#cite_note-1">[1]</a></sup></p>
<table class="infobox"><tr><td>drop me</td></tr></table></section>
<section data-mw-section-id="1"><h2 id="Risks">Risks</h2><div role="note" class="hatnote">Main article: Pain</div>
<p>A <a rel="mw:WikiLink" href="./Shock_(circulatory)">shock</a> link and <a rel="mw:WikiLink" href="./Nerve">nerve</a> and <a rel="mw:ExtLink" href="https://x">ext</a>.</p>
<figure typeof="mw:File/Thumb"><a href="./File:Tq.jpg"><img resource="./File:Tq.jpg" src="//upload/x.jpg" width="220"/></a><figcaption>Caption</figcaption></figure>
<section data-mw-section-id="2"><h3 id="Sub">Sub</h3><p style="color:red" class="x">Sub text</p></section></section>
<section data-mw-section-id="3"><h2 id="History">History</h2><p>Old</p></section>
<section data-mw-section-id="4"><h2 id="See_also">See also</h2><ul><li>x</li></ul></section>
<section data-mw-section-id="5"><h2 id="References">References</h2><ol class="mw-references"><li>r</li></ol></section>
</body></html>"""


def test_sanitise_keeps_named_sections_demotes_headings_and_rewrites_links():
    html, files = mediawiki.sanitise(PARSOID, ("Risks",), {"Shock (circulatory)": "shock"}, own_slug="bleeding-control")
    assert "<h3>Risks</h3>" in html and "<h4>Sub</h4>" in html and "History" not in html
    assert 'href="shock.html">shock</a>' in html and "nerve" in html and 'href="./Nerve"' not in html and 'href="https://x"' not in html
    assert "infobox" not in html and "hatnote" not in html and "Main article" not in html and "cite_note" not in html
    assert 'style=' not in html and 'class="x"' not in html and "shortdescription" not in html
    assert files == ["Tq.jpg"] and '<img alt="" src="Tq.jpg"/>' in html and "<figcaption>Caption</figcaption>" in html


def test_sanitise_without_section_list_drops_boilerplate_sections_and_own_link():
    html, _ = mediawiki.sanitise(PARSOID, (), {"Shock (circulatory)": "shock"}, own_slug="shock")
    assert "Lead" in html and "<h3>History</h3>" in html and "See also" not in html and "References" not in html
    assert "shock.html" not in html and ">shock<" not in html and "shock" in html


def test_image_licence_policy():
    assert mediawiki.licence_allowed("Public domain") and mediawiki.licence_allowed("CC0") and mediawiki.licence_allowed("CC BY-SA 3.0")
    assert mediawiki.licence_allowed("CC BY 4.0") and mediawiki.licence_allowed("PD-USGov")
    assert not mediawiki.licence_allowed("CC BY-NC-SA 2.0") and not mediawiki.licence_allowed("Fair use") and not mediawiki.licence_allowed("")
    assert not mediawiki.licence_allowed("GFDL")


def test_markdown_subset():
    out = render.markdown_subset("### Boil\n1. First **hard**\n   more\n2. Second\n\n- a\n- b\n> careful\nPlain *em* text\n")
    assert out == ("<h3>Boil</h3>\n<ol>\n<li>First <strong>hard</strong> more</li>\n<li>Second</li>\n</ol>\n<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"
                   '<p class="warn">careful</p>\n<p>Plain <em>em</em> text</p>')


def test_pdf_pages_to_html_drops_running_headers_and_builds_lists_and_headings():
    pages = ["FM 1-1 HEADER\n2-18\nSection II. STOP THE BLEEDING\n2-13. General\nBlood loss is seri-\nous.\n• First bullet\n• Second bullet\nFigure 2-1. Something\n",
             "FM 1-1 HEADER\n2-19\nMore text on the\nnext page.\n"]
    html = pdf.pages_to_html(pages)
    assert "HEADER" not in html and "2-18" not in html and "Figure 2-1" not in html
    assert "<h3>Section II. STOP THE BLEEDING</h3>" in html
    assert "<h4>2-13. General</h4>" in html and "<p>Blood loss is serious.</p>" in html
    assert "<ul>\n<li>First bullet</li>\n<li>Second bullet</li>\n</ul>" in html and "<p>More text on the next page.</p>" in html


def test_guide_loads_and_refuses_bad_references(tmp_path):
    catalogue = load_spec(CONTENT / "catalogue-spec.json")
    g = load_guide(GUIDE, catalogue)
    assert len(g.articles) >= 20 and len(g.sections) == 16 and len(g.smoke_queries) == len(g.articles)
    assert all(isinstance(s, (MediaWikiRef, PdfRef)) for a in g.articles for s in a.sources)
    assert g.wiki_titles()["Tourniquet"] == "bleeding-control"
    bad = tmp_path / "guide"
    (bad / "articles" / "water").mkdir(parents=True)
    (bad / "sections.yaml").write_text("sections:\n  - {id: water, title: Water}\nsmoke_queries: {x: nope}\n")
    (bad / "articles/water/a.yaml").write_text("title: A\nsummary: s\nprocedure: p\nsources:\n  - {kind: pdf, document: not-a-doc, pages: 9-3}\n  - {kind: video}\n")
    (bad / "articles/water/b.yaml").write_text("title: B\nsummary: s\nprocedure: p\nsources:\n  - {kind: pdf, document: cdc-make-water-safe-during-emergency, pages: 1}\nrelated: [missing]\n")
    with pytest.raises(GuideError) as ei:
        load_guide(bad, catalogue)
    text = "\n".join(ei.value.problems)
    assert "not in catalogue-spec.json" in text and "pages" in text and "kind 'video'" in text and "missing is not an article" in text and "nope is not an article" in text


def test_every_pdf_page_range_is_within_the_document():
    catalogue = load_spec(CONTENT / "catalogue-spec.json")
    g = load_guide(GUIDE, catalogue)
    from pypdf import PdfReader
    content = CONTENT.parents[1] / "content"
    for a in g.articles:
        for s in a.sources:
            if isinstance(s, PdfRef):
                p = build_mod.pdf_location(GUIDE, content, s.document, catalogue)
                if not p.exists():
                    pytest.skip(f"{p} not downloaded")
                assert s.pages[1] <= len(PdfReader(str(p)).pages), f"{a.slug}: {s.key} beyond the end of the PDF"


@pytest.mark.skipif(not (GUIDE / "snapshots").exists(), reason="snapshots not committed")
def test_offline_fixture_build_from_snapshots_validates(tmp_path):
    out = tmp_path / "fieldguide_en_2026-09.zim"
    r = build_mod.build(GUIDE, out, date(2026, 9, 1), cache=tmp_path / "cache", only=FIXTURE_SLUGS, offline=True, log=lambda s: None)
    assert r.article_count == 10 and r.pdf_count == 0 and r.image_count > 0 and not r.skipped
    failures = validate(out, GUIDE, log=lambda s: None, zimcheck=False, expected_articles=10)
    assert failures == []
    from libzim.reader import Archive
    a = Archive(str(out))
    assert a.get_metadata("Name").decode() == "fieldguide_en" and a.get_metadata("Date").decode() == "2026-09-01"
    html = bytes(a.get_entry_by_path("A/boil-bleach-filter.html").get_item().content).decode()
    assert "P/cdc-make-water-safe" not in html and "Open the original PDF" not in html
    again = tmp_path / "again.zim"
    build_mod.build(GUIDE, again, date(2026, 9, 1), cache=tmp_path / "cache", only=FIXTURE_SLUGS, offline=True, log=lambda s: None)
    b = Archive(str(again))
    assert bytes(a.get_entry_by_path("A/shock.html").get_item().content) == bytes(b.get_entry_by_path("A/shock.html").get_item().content)


def test_inputs_digest_changes_with_article_text(tmp_path):
    d1 = build_mod.inputs_digest(GUIDE)
    assert set(d1) == {"articles", "articlesLock"} and len(d1["articles"]) == 64
    import shutil
    copy = tmp_path / "g"
    shutil.copytree(GUIDE, copy, ignore=shutil.ignore_patterns("snapshots"))
    assert build_mod.inputs_digest(copy)["articles"] == d1["articles"]
    (copy / "articles/water/distillation.yaml").write_text((copy / "articles/water/distillation.yaml").read_text() + "\n# edited\n")
    assert build_mod.inputs_digest(copy)["articles"] != d1["articles"]
