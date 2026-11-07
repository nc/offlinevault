"""Builders make the bytes for entries that have no upstream file: document packs, zimit crawls, map extracts and
the Field Guide. Each answers `inputs()` (what the output depends on, cheap, never the edition itself) and `build()`
(a local path converge uploads under whichever edition key is free)."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from ..http import Http
from ..resolve import Candidate
from ..spec import BuiltSource, DocumentsSource, MapExtractSource, ZimitSource


@dataclass
class BuildContext:
    content: Path
    http: Http
    repo_root: Path
    log: Callable[[str], None] = print
    offline: bool = False


class Builder(Protocol):
    def inputs(self, cand: Candidate, ctx: BuildContext) -> dict: ...
    def build(self, cand: Candidate, ctx: BuildContext) -> Path: ...


def builder_for(cand: Candidate) -> Builder:
    from . import docpack, fieldguide, mapextract, zimit
    src = cand.entry.source
    if isinstance(src, DocumentsSource):
        return docpack.DocpackBuilder()
    if isinstance(src, ZimitSource):
        return zimit.ZimitBuilder()
    if isinstance(src, MapExtractSource):
        return mapextract.MapExtractBuilder()
    if isinstance(src, BuiltSource) and src.builder == "fieldguide":
        return fieldguide.FieldGuideBuilder()
    raise ValueError(f"{cand.entry.id}: no builder for {type(src).__name__}")
