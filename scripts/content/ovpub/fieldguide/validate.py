"""Open the built ZIM the way the app will and refuse to ship a broken one."""
from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path
from urllib.parse import unquote

from libzim.reader import Archive
from libzim.search import Query, Searcher

from .spec import load_guide

ZIMCHECK_IMAGE = "ghcr.io/openzim/zim-tools:latest"


def validate(zim: Path, guide_dir: Path, log=print, zimcheck: bool | None = None, expected_articles: int | None = None) -> list[str]:
    """Returns the list of failures (empty = pass). Checks: metadata, main entry, full-text index, every article
    present, every internal href/src resolves, smoke queries rank their article in the top 3, zimcheck when Docker is here."""
    from .build import catalogue_for
    failures: list[str] = []
    zim = Path(zim)
    archive = Archive(str(zim))
    guide = load_guide(Path(guide_dir), catalogue_for(Path(guide_dir)))
    meta = {k: archive.get_metadata(k).decode() for k in archive.metadata_keys if k != "Illustration_48x48@1"}
    for k in ("Name", "Title", "Date", "License", "Language", "Creator", "Publisher"):
        if not meta.get(k):
            failures.append(f"metadata {k} missing")
    if meta.get("Name") != "fieldguide_en":
        failures.append(f"Name is {meta.get('Name')!r}, expected fieldguide_en")
    if not archive.has_fulltext_index:
        failures.append("no full-text index")
    if "Illustration_48x48@1" not in archive.metadata_keys:
        failures.append("no 48x48 illustration")
    if not archive.has_main_entry or archive.main_entry.get_item().path != "index.html":
        failures.append("main entry is not index.html")

    present = {a.slug for a in guide.articles if archive.has_entry_by_path(a.path)}
    html_paths = [a.path for a in guide.articles if a.slug in present] + [s.path for s in guide.sections if archive.has_entry_by_path(s.path)] + ["index.html", "about.html"]
    if expected_articles is not None and len(present) != expected_articles:
        failures.append(f"{len(present)} articles present, expected {expected_articles}")
    for path in html_paths:
        if not archive.has_entry_by_path(path):
            failures.append(f"{path}: missing")
            continue
        html = bytes(archive.get_entry_by_path(path).get_item().content).decode()
        base = path.rsplit("/", 1)[0] + "/" if "/" in path else ""
        for ref in re.findall(r'(?:href|src)="([^"#]+)(?:#[^"]*)?"', html):
            if "://" in ref or ref.startswith("mailto:"):
                continue
            target = _resolve(base, unquote(ref))
            if not archive.has_entry_by_path(target):
                failures.append(f"{path}: broken link {ref} -> {target}")
    searcher = Searcher(archive)
    for query, slug in guide.smoke_queries.items():
        if slug not in present:
            continue
        search = searcher.search(Query().set_query(query))
        top = list(search.getResults(0, 3))
        if f"A/{slug}.html" not in top:
            failures.append(f"search {query!r}: expected A/{slug}.html in the top 3, got {top}")
    log(f"  validate: {len(present)} articles, {archive.entry_count} entries, {len(guide.smoke_queries)} smoke queries, {len(failures)} failures")
    if zimcheck or (zimcheck is None and shutil.which("docker")):
        failures.extend(run_zimcheck(zim, log))
    return failures


def _resolve(base: str, ref: str) -> str:
    parts = (base + ref).split("/")
    out: list[str] = []
    for p in parts:
        if p == "..":
            if out:
                out.pop()
        elif p and p != ".":
            out.append(p)
    return "/".join(out)


def run_zimcheck(zim: Path, log=print) -> list[str]:
    cmd = ["docker", "run", "--rm", "--platform", "linux/amd64", "-v", f"{zim.resolve().parent}:/z", ZIMCHECK_IMAGE, "zimcheck", "-A", f"/z/{zim.name}"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().splitlines()[-12:]
    log("  zimcheck: " + (tail[-1] if tail else f"exit {r.returncode}"))
    if r.returncode != 0:
        return ["zimcheck failed:\n    " + "\n    ".join(tail)]
    return []
