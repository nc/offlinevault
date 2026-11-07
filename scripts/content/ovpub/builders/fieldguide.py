"""The Field Guide ZIM, built from scripts/content/fieldguide/ by ovpub.fieldguide."""
from __future__ import annotations

from datetime import date
from pathlib import Path

from ..resolve import Candidate, Edition
from ..spec import BuiltSource
from . import BuildContext


def guide_dir(cand: Candidate, ctx: BuildContext) -> Path:
    src = cand.entry.source
    assert isinstance(src, BuiltSource)
    return ctx.repo_root / src.params.get("guide", "scripts/content/fieldguide")


def build_month(cand: Candidate) -> str:
    assert cand.edition
    return Edition.parse(cand.edition).month


class FieldGuideBuilder:
    def inputs(self, cand: Candidate, ctx: BuildContext) -> dict:
        from ..fieldguide.build import inputs_digest
        return {"month": build_month(cand), **inputs_digest(guide_dir(cand, ctx))}

    def build(self, cand: Candidate, ctx: BuildContext) -> Path:
        from ..fieldguide.build import build
        from ..fieldguide.validate import validate
        month = build_month(cand)
        out = ctx.content / "zim" / f"fieldguide_en_{month}.zim"
        out.parent.mkdir(parents=True, exist_ok=True)
        y, m = month.split("-")
        result = build(guide_dir(cand, ctx), out, build_date=date(int(y), int(m), 1), cache=ctx.content / "cache" / "fieldguide",
                       offline=ctx.offline, log=ctx.log)
        failures = validate(out, guide_dir(cand, ctx), log=ctx.log)
        if failures:
            raise RuntimeError("Field Guide failed validation:\n  " + "\n  ".join(failures))
        ctx.log(f"  field guide: {result.article_count} articles, {result.image_count} images, {result.pdf_count} PDFs")
        return out
