"""A PMTiles region cut from the Protomaps daily planet build with the bundled pmtiles CLI. At maxzoom 15 the
region is the planet itself, so the build is a download (or, when disk is short, converge streams it instead)."""
from __future__ import annotations

import subprocess
from pathlib import Path
from urllib.parse import urlparse

from .. import fetch
from ..resolve import Candidate
from ..spec import MapExtractSource
from . import BuildContext


def planet_build(cand: Candidate) -> str:
    """`20261019` from https://build.protomaps.com/20261019.pmtiles."""
    assert cand.upstream is not None
    return Path(urlparse(cand.upstream.url).path).stem


def pmtiles_binary(repo_root: Path) -> Path:
    p = repo_root / "OfflineVault/Resources/bin/pmtiles"
    if not p.exists():
        raise RuntimeError("pmtiles CLI missing: run scripts/fetch_web_assets.sh")
    return p


class MapExtractBuilder:
    def inputs(self, cand: Candidate, ctx: BuildContext) -> dict:
        src = cand.entry.source
        assert isinstance(src, MapExtractSource)
        return {"build": planet_build(cand), "maxzoom": src.maxzoom, "bbox": src.bbox, "source": cand.upstream.url if cand.upstream else None}

    def build(self, cand: Candidate, ctx: BuildContext) -> Path:
        src = cand.entry.source
        assert isinstance(src, MapExtractSource) and cand.upstream is not None
        name = cand.entry.id[4:] if cand.entry.id.startswith("map-") else cand.entry.id
        out = ctx.content / "maps" / f"{name}_{planet_build(cand)}.pmtiles"
        if out.exists():
            return out
        if cand.passthrough:
            return fetch.download(cand.upstream.url, out, ctx.log)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".tmp.pmtiles")
        cmd = [str(pmtiles_binary(ctx.repo_root)), "extract", cand.upstream.url, str(tmp), f"--maxzoom={src.maxzoom}"]
        if src.bbox:
            cmd.append(f"--bbox={src.bbox}")
        ctx.log(f"  pmtiles extract maxzoom={src.maxzoom} from {cand.upstream.url}")
        subprocess.run(cmd, check=True)
        tmp.replace(out)
        return out
