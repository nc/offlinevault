from __future__ import annotations

import argparse
import os
import platform
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from . import __version__
from .client import Service
from .errors import LicenceNeeded, OvsyncError, VerificationFailed
from .licence import Licence, allowed_tiers, day_string, normalise_key, parse_licence
from .manifest import TIERS, Manifest, parse_manifest, tier_rank
from .signing import CATALOGUE_KEYS, LICENCE_FORMAT, LICENCE_KEYS, MANIFEST_FORMAT, Envelope, Keyring
from .store import State, config_dir
from .sync import EXTERNAL_NOTE, INCLUDES, gate, human, run_sync, run_verify, select

DEFAULT_ORIGIN = "https://offlinevault.dev/"


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write(f"ovsync: {message}\n")
        sys.exit(1)


def build_parser() -> Parser:
    p = Parser(prog="ovsync", description="Download the signed OfflineVault catalogue into a folder Kiwix can serve.")
    p.add_argument("--version", action="version", version=f"ovsync {__version__}")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--origin", default=os.environ.get("OVSYNC_ORIGIN", DEFAULT_ORIGIN),
                        help=f"the service root: catalogue under /updates/, licences under /api/licence/ (default {DEFAULT_ORIGIN})")
    sub = p.add_subparsers(dest="command", required=True, metavar="command")

    a = sub.add_parser("activate", parents=[common], help="register this computer against a licence key")
    a.add_argument("key", help="OV-XXXX-XXXX-XXXX-XXXX from your receipt")
    sub.add_parser("deactivate", parents=[common], help="free this computer's seat and forget the key")
    sub.add_parser("status", help="show the stored licence and device id")

    ls = sub.add_parser("list", parents=[common], help="verify the catalogue and list what it offers")
    ls.add_argument("--tier", choices=TIERS, help="show only this tier and below")

    s = sub.add_parser("sync", parents=[common], help="download the catalogue into DIR and write library.xml")
    s.add_argument("dir", type=Path)
    s.add_argument("--tier", choices=TIERS, default="core", help="highest tier to download (default core)")
    s.add_argument("--only", nargs="+", metavar="ID", help="download just these artefact ids")
    s.add_argument("--include", default="", help="comma-separated extras: " + ",".join(INCLUDES) + " (external = books served by Kiwix, not the catalogue)")

    v = sub.add_parser("verify", help="rehash every file in DIR against what was downloaded")
    v.add_argument("dir", type=Path)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return COMMANDS[args.command](args)
    except OvsyncError as e:
        print(f"ovsync: {e}", file=sys.stderr)
        return e.exit_code
    except KeyboardInterrupt:
        print("ovsync: interrupted; rerun to resume", file=sys.stderr)
        return 130


def cmd_activate(args) -> int:
    key = normalise_key(args.key)
    if key is None:
        raise LicenceNeeded("that is not a licence key; expected OV-XXXX-XXXX-XXXX-XXXX (no 0, O, 1 or I)")
    directory = config_dir()
    state = State.load(directory)
    response = service(args).activate(key, state.device_id, platform.node())
    try:
        licence, envelope = open_licence(response.get("licence"))
    except LicenceNeeded as e:
        raise VerificationFailed(f"the licence service answered with a licence ovsync cannot trust: {e}")
    state.key = key
    state.licence = envelope.to_object()
    state.save(directory)
    now = datetime.now(timezone.utc)
    print(f"Activated: {licence.summary(now)}.")
    print(f"Seats: {len(response.get('seats', []))} of {response.get('seatLimit', licence.seats)} in use. Device id {state.device_id}.")
    print(f"Covers tiers: {', '.join(sorted(allowed_tiers(licence, now), key=tier_rank))}.")
    return 0


def cmd_deactivate(args) -> int:
    directory = config_dir()
    state = State.load(directory)
    if not state.key:
        print("No licence is stored on this computer.")
        return 0
    response = service(args).deactivate(state.key, state.device_id)
    state.key = None
    state.licence = None
    state.save(directory)
    print(f"Deactivated. Seats now in use: {len(response.get('seats', []))} of {response.get('seatLimit', '?')}.")
    return 0


def cmd_status(args) -> int:
    directory = config_dir()
    state = State.load(directory)
    now = datetime.now(timezone.utc)
    print(f"Config: {directory / 'state.json'}")
    print(f"Device id: {state.device_id}")
    if not state.licence:
        print("Licence: none. Free-tier content only; 'ovsync activate OV-...' adds a plan.")
        return 0
    try:
        licence, _ = open_licence(state.licence)
    except LicenceNeeded as e:
        print(f"Licence: rejected ({e}). Run 'ovsync activate' again.")
        return 2
    print(f"Licence: {licence.summary(now)}; covers {', '.join(sorted(allowed_tiers(licence, now), key=tier_rank))}.")
    return 0


def cmd_list(args) -> int:
    directory = config_dir()
    state = State.load(directory)
    manifest, key_id = load_manifest(args, state, directory)
    now = datetime.now(timezone.utc)
    licence = current_licence(state)
    allowed = allowed_tiers(licence, now)
    print(f"Catalogue {manifest.version} ({len(manifest.artefacts)} artefacts), published {day_string(manifest.published_at)}, verified with key {key_id}.")
    print(f"Licence: {licence.summary(now) if licence else 'none'}; covers {', '.join(sorted(allowed, key=tier_rank))}.")
    tiers = sorted({a.tier for a in manifest.artefacts if a.kind != "catalogue"}, key=tier_rank)
    for tier in tiers:
        if args.tier and tier_rank(tier) > tier_rank(args.tier):
            continue
        rows = [a for a in manifest.artefacts if a.tier == tier and a.kind != "catalogue"]
        total = sum(a.size_bytes for a in rows)
        print(f"\n{tier} ({len(rows)} artefacts, {human(total)}){'' if tier in allowed else ', not in your plan'}")
        for a in rows:
            mark = "*" if tier in allowed else " "
            note = f"  [{EXTERNAL_NOTE}]" if a.external else ""
            print(f"  {mark} {a.id:<40} {a.kind:<14} {human(a.size_bytes):>9}  {a.display_title}{note}")
    print("\n* = your licence covers it")
    if any(a.external for a in manifest.artefacts):
        print(f"[{EXTERNAL_NOTE}] = downloads from Kiwix's own servers; 'ovsync sync DIR --include external' fetches them")
    return 0


def cmd_sync(args) -> int:
    directory = config_dir()
    state = State.load(directory)
    manifest, key_id = load_manifest(args, state, directory)
    now = datetime.now(timezone.utc)
    licence = current_licence(state)
    include = frozenset(filter(None, args.include.split(",")))
    unknown = include - set(INCLUDES)
    if unknown:
        raise OvsyncError(f"--include accepts {', '.join(INCLUDES)}; got {', '.join(sorted(unknown))}")
    wanted = select(manifest, args.tier, tuple(args.only or ()), include)
    gate(wanted, allowed_tiers(licence, now), licence is not None)
    print(f"Catalogue {manifest.version} verified with key {key_id}. {len(wanted)} artefacts, {human(sum(a.size_bytes for a in wanted))}, into {args.dir}.")
    summary = run_sync(service(args), manifest, args.dir, wanted, print, progress_printer())
    print(f"Done: {summary.downloaded} downloaded, {summary.skipped} already complete, {summary.removed} removed. "
          f"library.xml lists {summary.books} ZIM file{'s' if summary.books != 1 else ''}.")
    return 0


def cmd_verify(args) -> int:
    failed = run_verify(args.dir, print)
    if failed:
        raise VerificationFailed(f"{len(failed)} file{'s' if len(failed) != 1 else ''} failed verification; rerun 'ovsync sync' to repair")
    print("All recorded files verified.")
    return 0


COMMANDS = {"activate": cmd_activate, "deactivate": cmd_deactivate, "status": cmd_status, "list": cmd_list, "sync": cmd_sync, "verify": cmd_verify}


def service(args) -> Service:
    return Service(args.origin)


def catalogue_keyring() -> Keyring:
    return Keyring.from_env(CATALOGUE_KEYS, "OVSYNC_CATALOGUE_KEYS")


def licence_keyring() -> Keyring:
    return Keyring.from_env(LICENCE_KEYS, "OVSYNC_LICENCE_KEYS")


def load_manifest(args, state: State, directory: Path) -> tuple[Manifest, str]:
    svc = service(args)
    body = svc.fetch_manifest()
    try:
        payload, key_id = catalogue_keyring().open(Envelope.from_json(body), MANIFEST_FORMAT)
    except VerificationFailed as e:
        raise VerificationFailed(f"catalogue not trusted: {e}")
    manifest = parse_manifest(payload)
    seen = state.newest_published_at.get(svc.origin)
    if seen and manifest.published_at.isoformat() < seen:
        raise VerificationFailed(f"the service offered a catalogue published {day_string(manifest.published_at)}, older than the one already accepted ({seen[:10]})")
    state.newest_published_at[svc.origin] = manifest.published_at.isoformat()
    state.save(directory)
    return manifest, key_id


def open_licence(obj) -> tuple[Licence, Envelope]:
    if obj is None:
        raise LicenceNeeded("no licence")
    try:
        envelope = Envelope.from_object(obj)
        payload, _ = licence_keyring().open(envelope, LICENCE_FORMAT)
    except VerificationFailed as e:
        raise LicenceNeeded(str(e))
    return parse_licence(payload), envelope


def current_licence(state: State) -> Licence | None:
    if not state.licence:
        return None
    try:
        return open_licence(state.licence)[0]
    except LicenceNeeded:
        return None


def progress_printer():
    if not sys.stderr.isatty():
        return lambda done, total: None
    last = 0.0

    def show(done: int, total: int) -> None:
        nonlocal last
        now = time.monotonic()
        if done >= total or now - last > 0.5:
            last = now
            pct = 100 * done // total if total else 100
            sys.stderr.write(f"\r     {pct:3d}%  {human(done)} / {human(total)}" + ("\n" if done >= total else ""))
            sys.stderr.flush()
    return show


if __name__ == "__main__":
    sys.exit(main())
