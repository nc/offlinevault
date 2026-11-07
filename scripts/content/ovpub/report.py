"""One JSON report per run, plus the per-tier table the operator reads."""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .converge import Outcome, now_iso
from .spec import TIER_RANK, Spec


@dataclass
class Run:
    command: str
    tier: str
    version: str | None = None
    started_at: str = field(default_factory=now_iso)
    finished_at: str | None = None
    result: str = "running"
    outcomes: list[Outcome] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    manifest: dict = field(default_factory=dict)

    def finish(self, result: str) -> "Run":
        self.result = result
        self.finished_at = now_iso()
        return self

    def to_json(self) -> dict:
        d = asdict(self)
        return d

    def write(self, reports_dir: Path) -> Path:
        reports_dir.mkdir(parents=True, exist_ok=True)
        name = f"{self.command}-{self.version or self.started_at.replace(':', '')}.json"
        body = json.dumps(self.to_json(), indent=2, ensure_ascii=False) + "\n"
        (reports_dir / name).write_text(body)
        summary = {k: v for k, v in self.to_json().items() if k != "outcomes"}
        summary["counts"] = {a: sum(1 for o in self.outcomes if o.action == a) for a in sorted({o.action for o in self.outcomes})}
        summary["failed"] = [o.entry_id for o in self.outcomes if o.action == "failed"]
        (reports_dir / "latest.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
        return reports_dir / name


def tier_table(spec: Spec, sizes: dict[str, int | None]) -> str:
    """Per-tier incremental and cumulative GB from the sizes known per entry id (None = unknown)."""
    lines = []
    cumulative = 0.0
    unknown_total = 0
    for tier in TIER_RANK:
        entries = [e for e in spec.entries if e.tier == tier]
        known = [sizes.get(e.id) for e in entries if sizes.get(e.id)]
        unknown = [e.id for e in entries if not sizes.get(e.id)]
        gb = sum(known) / 1e9
        cumulative += gb
        unknown_total += len(unknown)
        lines.append(f"  {tier:9s} {len(entries):3d} entries  {gb:7.1f} GB  (cumulative {cumulative:7.1f} GB)" + (f"  {len(unknown)} without a size" if unknown else ""))
    if unknown_total:
        lines.append("  sizes come from .meta4/HEAD; built entries and unresolved sources count as 0")
    return "\n".join(lines)


def outcome_table(outcomes: list[Outcome], spec: Spec) -> str:
    by_id = spec.by_id()
    rows = sorted(outcomes, key=lambda o: (TIER_RANK.get(by_id[o.entry_id].tier, 9) if o.entry_id in by_id else 9, o.entry_id))
    out = []
    for o in rows:
        e = by_id.get(o.entry_id)
        tier = e.tier if e else "?"
        size = f"{o.bytes / 1e9:6.2f} GB" if o.bytes else "         "
        detail = (o.detail or (o.artefact.id if o.artefact else ""))[:100]
        out.append(f"  {tier:8s} {o.entry_id:34s} {o.action:9s} {size} {o.seconds:7.1f}s  {detail}")
    return "\n".join(out)
