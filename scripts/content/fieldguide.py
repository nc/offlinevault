#!/usr/bin/env python3
"""The OfflineVault Field Guide: articles in scripts/content/fieldguide/ -> fieldguide_en_<YYYY-MM>.zim.

    fieldguide.py build    [--out ZIM] [--date YYYY-MM-DD] [--articles SLUG..] [--offline] [--refresh] [--allow-partial] [--no-validate]
    fieldguide.py validate ZIM [--no-zimcheck]
    fieldguide.py snapshot --articles SLUG..           write offline snapshots for the fixture articles
    fieldguide.py lint                                 parse every article and the catalogue cross-references
    fieldguide.py find-pages --document ID PATTERN..   physical page numbers where a regex matches (for `pages:`)

The cache (Parsoid HTML, images) lives under <content>/cache/fieldguide; `--offline` reads only committed snapshots.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import date, datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from ovpub.fieldguide import build as build_mod  # noqa: E402
from ovpub.fieldguide.spec import GuideError, load_guide  # noqa: E402
from ovpub.fieldguide.validate import validate  # noqa: E402

GUIDE = HERE / "fieldguide"
ROOT = HERE.parents[1]


def content_dir(a) -> Path:
    return Path(a.content or os.environ.get("OFFLINEVAULT_CONTENT_DIR") or ROOT / "content")


def cmd_build(a) -> int:
    d = date.fromisoformat(a.date) if a.date else datetime.now(timezone.utc).date().replace(day=1)
    out = Path(a.out) if a.out else content_dir(a) / "zim" / f"fieldguide_en_{d.strftime('%Y-%m')}.zim"
    try:
        r = build_mod.build(GUIDE, out, d, cache=content_dir(a) / "cache" / "fieldguide", only=tuple(a.articles or ()), offline=a.offline,
                            refresh=a.refresh, allow_partial=a.allow_partial, content=content_dir(a))
    except GuideError as e:
        print("article data problems:\n  " + "\n  ".join(e.problems))
        return 2
    for slug, why in r.skipped:
        print(f"  skipped {slug}: {why}")
    if a.no_validate:
        return 0
    failures = validate(out, GUIDE, expected_articles=r.article_count, zimcheck=not a.no_zimcheck if a.no_zimcheck else None)
    for f in failures:
        print("  FAIL " + f)
    return 1 if failures else 0


def cmd_validate(a) -> int:
    failures = validate(Path(a.zim), GUIDE, zimcheck=False if a.no_zimcheck else None)
    for f in failures:
        print("  FAIL " + f)
    print("ok" if not failures else f"{len(failures)} failures")
    return 1 if failures else 0


def cmd_snapshot(a) -> int:
    n = build_mod.snapshot(GUIDE, tuple(a.articles), cache=content_dir(a) / "cache" / "fieldguide", content=content_dir(a))
    print(f"wrote {n} snapshots under {GUIDE / 'snapshots'}")
    return 0


def cmd_lint(a) -> int:
    try:
        g = load_guide(GUIDE, build_mod.catalogue_for(GUIDE))
    except GuideError as e:
        print("\n".join(e.problems))
        return 1
    per = {s.id: len(g.in_section(s.id)) for s in g.sections}
    print(f"{len(g.articles)} articles, {sum(1 for n in per.values() if n)} of {len(g.sections)} sections populated, {len(g.smoke_queries)} smoke queries")
    for s in g.sections:
        print(f"  {s.id:18s} {per[s.id]}")
    return 0


def cmd_find_pages(a) -> int:
    from pypdf import PdfReader
    catalogue = build_mod.catalogue_for(GUIDE)
    pdf = build_mod.pdf_location(GUIDE, content_dir(a), a.document, catalogue)
    if not pdf.exists():
        print(f"{pdf} is not downloaded; run publish.py publish --only <its pack> --store fake, or fieldguide.py build")
        return 1
    reader = PdfReader(str(pdf))
    texts = [(p.extract_text() or "") for p in reader.pages]
    print(f"{pdf.name}: {len(texts)} pages")
    for pat in a.patterns:
        rx = re.compile(pat, re.I)
        hits = [(i + 1, m.group(0)) for i, t in enumerate(texts) if (m := rx.search(t))]
        print(f"  {pat!r}: " + ", ".join(f"p{p} ({s[:40]!r})" for p, s in hits[:12]) + ("" if len(hits) <= 12 else f" … {len(hits)} pages"))
    if a.show:
        for p in a.show:
            print(f"\n----- page {p}\n{texts[p - 1][:3000]}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--content", help="content dir (default <repo>/content)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("build")
    p.add_argument("--out"); p.add_argument("--date"); p.add_argument("--articles", nargs="*")
    p.add_argument("--offline", action="store_true"); p.add_argument("--refresh", action="store_true")
    p.add_argument("--allow-partial", action="store_true"); p.add_argument("--no-validate", action="store_true"); p.add_argument("--no-zimcheck", action="store_true")
    p.set_defaults(fn=cmd_build)
    p = sub.add_parser("validate"); p.add_argument("zim"); p.add_argument("--no-zimcheck", action="store_true"); p.set_defaults(fn=cmd_validate)
    p = sub.add_parser("snapshot"); p.add_argument("--articles", nargs="+", required=True); p.set_defaults(fn=cmd_snapshot)
    sub.add_parser("lint").set_defaults(fn=cmd_lint)
    p = sub.add_parser("find-pages"); p.add_argument("--document", required=True); p.add_argument("patterns", nargs="+")
    p.add_argument("--show", nargs="*", type=int, help="print these pages in full"); p.set_defaults(fn=cmd_find_pages)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    raise SystemExit(main())
