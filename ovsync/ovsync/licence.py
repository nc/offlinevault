"""Must match Core/Sources/OfflineVaultCore/Entitlement/Licence.swift (`Plan.level`, `Grant.forLevel`) and the key
normalisation in LicenceActivationClient.swift."""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime

from .errors import LicenceNeeded
from .manifest import parse_iso

KEY_ALPHABET = set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

GRANTS: dict[str, frozenset[str]] = {
    "free": frozenset({"free"}),
    "core": frozenset({"free", "core"}),
    "household": frozenset({"free", "core", "full", "complete"}),
}

PLAN_TITLES = {"core": "Core", "household": "Household", "drive": "Vault Drive", "founder": "Founder"}


def normalise_key(raw: str) -> str | None:
    symbols = "".join(c for c in raw.upper() if not c.isspace() and c not in "-–")
    if symbols.startswith("OV"):
        symbols = symbols[2:]
    if len(symbols) != 16 or any(c not in KEY_ALPHABET for c in symbols):
        return None
    return "OV-" + "-".join(symbols[i:i + 4] for i in range(0, 16, 4))


@dataclass(frozen=True)
class Licence:
    licence_id: str
    subscriber: str
    plan: str
    seats: int
    issued_at: datetime
    expires_at: datetime | None
    household_until: datetime | None

    def is_expired(self, now: datetime) -> bool:
        return self.expires_at is not None and self.expires_at < now

    def level(self, now: datetime) -> str:
        if self.is_expired(now):
            return "free"
        if self.plan == "core":
            return "core"
        if self.plan in ("household", "drive"):
            return "household"
        if self.plan == "founder":
            return "household" if self.household_until and now < self.household_until else "core"
        raise ValueError(f"unknown plan {self.plan}")

    @property
    def plan_title(self) -> str:
        return PLAN_TITLES.get(self.plan, self.plan)

    def summary(self, now: datetime) -> str:
        label = f"{self.plan_title} plan for {self.subscriber}"
        if self.expires_at is None:
            return f"{label}, no expiry"
        when = day_string(self.expires_at)
        return f"{label}, expired on {when}" if self.is_expired(now) else f"{label}, until {when}"


def day_string(d: datetime) -> str:
    return f"{d.day} {d:%b %Y}"


def parse_licence(payload: bytes) -> Licence:
    try:
        p = json.loads(payload)
        licence = Licence(
            licence_id=str(p["licenceId"]),
            subscriber=str(p["subscriber"]),
            plan=str(p["plan"]),
            seats=int(p["seats"]),
            issued_at=parse_iso(p["issuedAt"]),
            expires_at=parse_iso(p["expiresAt"]) if p.get("expiresAt") else None,
            household_until=parse_iso(p["householdUntil"]) if p.get("householdUntil") else None,
        )
    except (KeyError, TypeError, ValueError):
        raise LicenceNeeded("the licence payload is not a licence")
    if licence.plan not in PLAN_TITLES:
        raise LicenceNeeded(f"plan '{licence.plan}' needs a newer ovsync")
    return licence


def allowed_tiers(licence: Licence | None, now: datetime) -> frozenset[str]:
    return GRANTS[licence.level(now) if licence else "free"]
