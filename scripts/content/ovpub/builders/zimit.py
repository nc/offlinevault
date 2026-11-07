"""Crawl a public-domain site into a ZIM with Kiwix's zimit (Docker). Hours per site; the output name carries the month."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from ..resolve import Candidate, Edition
from ..spec import LICENCES, ZimitSource
from . import BuildContext

IMAGE = "ghcr.io/openzim/zimit"


def crawl_month(cand: Candidate) -> str:
    assert cand.edition
    return Edition.parse(cand.edition).month


PAGE_LIMIT = 20_000
SIZE_SOFT_LIMIT = 3_000_000_000   # bytes of WARC before zimit stops gracefully
TIME_SOFT_LIMIT = 4 * 3600          # seconds


class ZimitBuilder:
    def inputs(self, cand: Candidate, ctx: BuildContext) -> dict:
        src = cand.entry.source
        assert isinstance(src, ZimitSource)
        return {"seeds": list(src.seeds), "scope": src.scope, "month": crawl_month(cand), "image": IMAGE}

    def build(self, cand: Candidate, ctx: BuildContext) -> Path:
        src = cand.entry.source
        assert isinstance(src, ZimitSource)
        if not shutil.which("docker"):
            raise RuntimeError("docker is required for zimit (https://github.com/openzim/zimit)")
        out_dir = ctx.content / "zim"
        out_dir.mkdir(parents=True, exist_ok=True)
        out = out_dir / f"{src.name}_{crawl_month(cand)}.zim"
        if out.exists():
            return out
        cmd = ["docker", "run", "--rm", "-v", f"{out_dir}:/output", IMAGE, "zimit",
               "--seeds", ",".join(src.seeds), "--name", src.name, "--title", cand.entry.title[:30],
               "--description", cand.entry.description[:80], "--creator", LICENCES[cand.entry.licence].label,
               "--publisher", "OfflineVault", "--lang", "en", "--zim-lang", "eng",
               # prefix scope: only pages under the seed paths. Host scope on cdc.gov queued 127,490 pages and hit
               # the crawler's disk limit after 18 hours; the guides we want live under a few sections.
               "--scopeType", "prefix", "--pageLimit", str(PAGE_LIMIT), "--sizeSoftLimit", str(SIZE_SOFT_LIMIT),
               "--timeSoftLimit", str(TIME_SOFT_LIMIT), "--workers", "4", "--zim-file", out.name]
        ctx.log(f"  zimit {src.name} -> {out.name} (this takes hours)")
        subprocess.run(cmd, check=True)
        if not out.exists():
            raise RuntimeError(f"zimit finished but {out} is missing")
        return out
