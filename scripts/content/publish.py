#!/usr/bin/env python3
"""OfflineVault content publisher. One entry point; every command converges from the state it finds.

    publish.py doctor                                    tools, keys, network, disk
    publish.py plan    [--tier T] [--only ID..] [--skip ID..]      resolve and report, write nothing
    publish.py publish [--tier T] [--only ID..] [--skip ID..] [--version V] [--no-manifest] [--frozen]
                       [--store worker|fake] [--out DIR] [--key FILE] [--key-id ID] [--offline]
    publish.py verify  [--base URL]                      the client's view through the origin (catalogtool)
    publish.py rollback --to VERSION                     re-sign an archived manifest as the live one
    publish.py prune   [--older-than DAYS] [--dry-run | --yes]
    publish.py build fieldguide ...                      see fieldguide.py

Defaults: --tier complete, --store worker, --key ~/.offlinevault-keys/content/licence-private.key,
--key-id content-2026-10, origin https://offlinevault.dev, content dir <repo>/content.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from ovpub import manifest as manifest_mod  # noqa: E402
from ovpub import sign  # noqa: E402
from ovpub.builders import BuildContext  # noqa: E402
from ovpub.converge import Outcome, converge, now_iso, stream_decision  # noqa: E402
from ovpub.http import RequestsHttp  # noqa: E402
from ovpub.lock import Lock, LockEntry  # noqa: E402
from ovpub.report import Run, outcome_table, tier_table  # noqa: E402
from ovpub.resolve import Candidate, ResolveError, Upstream, document_upstreams, next_suffix, resolve  # noqa: E402
from ovpub.spec import TIER_RANK, DocumentsSource, Entry, Spec, load_spec  # noqa: E402
from ovpub.store import sha256_bytes, FakeStore, ObjectInfo, Printer, Store, WorkerStore  # noqa: E402

ROOT = HERE.parents[1]
SPEC_PATH = HERE / "catalogue-spec.json"
LOCK_PATH = HERE / "catalogue.lock.json"
REPORTS = HERE / "reports"
ORIGIN = "https://offlinevault.dev"
KEYS = Path.home() / ".offlinevault-keys"
DEFAULT_KEY = KEYS / "content/licence-private.key"
DEFAULT_KEY_ID = "content-2026-10"
UPLOAD_SECRET = KEYS / "upload-secret"


def log(msg: str) -> None:
    print(msg, flush=True)


def content_dir(a) -> Path:
    return Path(a.content or os.environ.get("OFFLINEVAULT_CONTENT_DIR") or ROOT / "content")


def selected(spec: Spec, a) -> list[Entry]:
    rows = [e for e in spec.entries if TIER_RANK[e.tier] <= TIER_RANK[a.tier]]
    if a.only:
        rows = [e for e in rows if e.id in set(a.only)]
    if a.skip:
        rows = [e for e in rows if e.id not in set(a.skip)]
    return rows


def resolve_all(entries: list[Entry], http, lock: Lock, log=log) -> tuple[dict[str, Candidate], dict[str, str]]:
    """Candidates by entry id, plus a message for each entry that kept its locked edition because its source failed."""
    cands: dict[str, Candidate] = {}
    failures: dict[str, str] = {}

    def one(e: Entry):
        return e, resolve(e, http)

    with ThreadPoolExecutor(8) as pool:
        futures = [pool.submit(one, e) for e in entries]
        for f in as_completed(futures):
            try:
                e, c = f.result()
                cands[e.id] = c
            except ResolveError as ex:
                eid = str(ex).split(":")[0] if ":" in str(ex) else "?"
                failures[eid] = str(ex)
            except Exception as ex:  # noqa: BLE001
                failures["?"] = f"{type(ex).__name__}: {ex}"
    for e in entries:
        if e.id in cands:
            continue
        prev = lock.entries.get(e.id)
        if prev and prev.artefact:
            cands[e.id] = candidate_from_lock(e, prev)
            failures[e.id] = failures.pop(e.id, "") or "source unreachable; kept the locked edition"
    return cands, failures


def candidate_from_lock(entry: Entry, prev: LockEntry) -> Candidate:
    assert prev.artefact is not None
    up = None
    if prev.source and prev.source.url:
        up = Upstream(prev.source.url, prev.source.size, prev.source.sha256, prev.source.sha_source)
    edition = prev.source.edition if prev.source else None
    # Built artefacts record no source; their edition is the suffix of the artefact id (`<entry>-<edition>`).
    if edition is None and prev.artefact.id.startswith(entry.id + "-"):
        edition = prev.artefact.id[len(entry.id) + 1:]
    return Candidate(entry, prev.artefact.id, prev.artefact.path, edition, up)


def worker_store(a) -> WorkerStore | None:
    if not UPLOAD_SECRET.exists():
        return None
    return WorkerStore(a.origin, UPLOAD_SECRET.read_text().strip())


def read_live(store: Store, public_b64: str, key_id: str, warn) -> tuple[dict | None, bytes | None]:
    raw = store.get("manifest.json")
    if raw is None:
        return None, None
    try:
        env = json.loads(raw)
        payload = json.loads(sign.verify(env, public_b64, key_id=key_id))
    except (ValueError, sign.BadSignature) as e:
        warn(f"live manifest.json is not an envelope this key verifies ({e}); treating as absent")
        return None, None
    cat_path = next((x["path"] for x in payload.get("artefacts", []) if x.get("kind") == "catalogue"), None)
    return payload, (store.get(cat_path) if cat_path else None)


# --- commands ---------------------------------------------------------------------------------------------------

def cmd_doctor(a) -> int:
    ok = True

    def check(name: str, good: bool, hint: str = "") -> None:
        nonlocal ok
        ok &= good
        log(f"  [{'ok' if good else 'MISSING'}] {name}" + (f"  ({hint})" if hint and not good else ""))

    for mod in ("libzim", "pypdf", "bs4", "lxml", "yaml", "requests", "cryptography"):
        try:
            __import__(mod)
            check(f"python: {mod}", True)
        except ImportError:
            check(f"python: {mod}", False, "pip install -r scripts/content/requirements.txt")
    for tool in ("curl", "docker", "swift"):
        check(f"tool: {tool}", shutil.which(tool) is not None)
    check("tool: pmtiles", (ROOT / "OfflineVault/Resources/bin/pmtiles").exists(), "scripts/fetch_web_assets.sh")
    check("tool: kiwix-serve", (ROOT / "OfflineVault/Resources/bin/kiwix-serve").exists(), "scripts/fetch_binaries.sh")
    check(f"key: {a.key}", Path(a.key).exists())
    check(f"upload secret: {UPLOAD_SECRET}", UPLOAD_SECRET.exists(), "copy from wrangler secret UPLOAD_SECRET")
    if Path(a.key).exists():
        pub = sign.public_key_b64(sign.read_key(Path(a.key)))
        log(f"  public key for {a.key_id}: {pub}")
    c = content_dir(a)
    c.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(c).free
    check(f"disk: {free / 1e9:.0f} GB free at {c}", free > 60e9, "publish streams anything larger than free minus 40 GB")
    try:
        import requests
        r = requests.head(f"{a.origin}/updates/manifest.json", timeout=20)
        check(f"origin {a.origin}/updates/manifest.json -> {r.status_code}", r.status_code in (200, 404))
    except Exception as e:  # noqa: BLE001
        check(f"origin {a.origin}", False, str(e))
    return 0 if ok else 1


def cmd_plan(a) -> int:
    spec = load_spec(SPEC_PATH)
    lock = Lock.load(LOCK_PATH)
    http = RequestsHttp()
    entries = selected(spec, a)
    store: Store = Printer(worker_store(a), out=log)
    content = content_dir(a)
    content.mkdir(parents=True, exist_ok=True)
    log(f"resolving {len(entries)} entries (tier {a.tier})")
    cands, failures = resolve_all(entries, http, lock)
    sizes: dict[str, int | None] = {}
    actions: list[Outcome] = []
    for e in entries:
        c = cands.get(e.id)
        if c is None:
            actions.append(Outcome(e.id, "unresolved", detail=failures.get(e.id, "no candidate")))
            continue
        locked = lock.entries[e.id].artefact.size if e.id in lock.entries and lock.entries[e.id].artefact else None
        size = c.upstream.size if c.passthrough and c.upstream else locked
        sizes[e.id] = size
        info = store.head(c.path)
        if c.external:
            action = "external"
        elif info and c.passthrough and c.upstream and c.upstream.sha256 and info.sha256 == c.upstream.sha256:
            action = "unchanged"
        elif c.passthrough:
            action = "stream" if stream_decision(c, shutil.disk_usage(content).free) else "upload"
        else:
            action = "build"
        detail = failures.get(e.id, "") or f"{c.artefact_id}  <- {c.upstream.url if c.upstream else 'builder'}"
        actions.append(Outcome(e.id, action, bytes=size or 0, detail=detail))
        if isinstance(e.source, DocumentsSource):
            for did, up in document_upstreams(e.source, http).items():
                if isinstance(up, Exception):
                    actions.append(Outcome(e.id, "unresolved", detail=f"document {did}: {up}"))
    log(outcome_table(actions, spec))
    log("")
    log(tier_table(spec, sizes))
    unresolved = [o for o in actions if o.action == "unresolved"]
    if unresolved:
        log(f"\n{len(unresolved)} unresolved: " + ", ".join(sorted({o.entry_id for o in unresolved})))
    run = Run("plan", a.tier, outcomes=actions, warnings=[f"{k}: {v}" for k, v in failures.items()]).finish("ok")
    run.manifest = {"sizes": sizes}
    log(f"report: {run.write(REPORTS)}")
    return 0


def pick_version(store: Store, today: str) -> str:
    suffix = ""
    while store.head(f"manifests/manifest-{today}{suffix}.json") is not None:
        suffix = next_suffix(suffix)
    return today + suffix


def cmd_publish(a) -> int:
    content = content_dir(a)
    content.mkdir(parents=True, exist_ok=True)
    lock_file = open(content / ".publish.lock", "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another publish is running (content/.publish.lock)")
        return 2
    spec = load_spec(SPEC_PATH)
    lock = Lock.load(LOCK_PATH)
    lock.spec_version = spec.version
    http = RequestsHttp()
    seed = sign.read_key(Path(a.key))
    public_b64 = sign.public_key_b64(seed)
    run = Run("publish", a.tier)
    entries = selected(spec, a)

    if a.frozen:
        cands = {e.id: candidate_from_lock(e, lock.entries[e.id]) for e in entries if e.id in lock.entries and lock.entries[e.id].artefact}
        failures = {e.id: "not in the lock" for e in entries if e.id not in cands}
    else:
        log(f"resolving {len(entries)} entries")
        cands, failures = resolve_all(entries, http, lock)
    run.warnings.extend(f"{k}: {v}" for k, v in failures.items())

    if a.store == "fake":
        out_dir = Path(a.out or content / "publish-dry")
        pretend = {c.path: ObjectInfo(c.path, c.upstream.size or 0, c.upstream.sha256) for c in cands.values() if c.passthrough and not c.external and c.upstream and c.upstream.sha256}
        if a.frozen:  # the lock is the truth, so the pretend store holds every locked artefact, built ones included
            pretend.update({e.artefact.path: ObjectInfo(e.artefact.path, e.artefact.size, e.artefact.sha256) for e in lock.entries.values() if e.artefact})
        store: Store = FakeStore(root=out_dir, pretend=pretend)
        store_is_real = False
        log(f"fake store at {out_dir}: pretending R2 holds {len(pretend)} passthrough artefacts at their upstream sha")
    else:
        ws = worker_store(a)
        if ws is None:
            log(f"no upload secret at {UPLOAD_SECRET}")
            return 2
        store, store_is_real = ws, True

    ctx = BuildContext(content=content, http=http, repo_root=ROOT, log=log, offline=a.offline)
    free = shutil.disk_usage(content).free
    todo = [cands[e.id] for e in entries if e.id in cands]
    todo.sort(key=lambda c: (c.upstream.size if c.upstream and c.upstream.size else (0 if not c.passthrough else 1 << 62)))
    streams = {c.entry.id: stream_decision(c, free) for c in todo}
    for c in todo:
        if streams[c.entry.id] or c.external:
            free_claim = 0
        else:
            free_claim = c.upstream.size if c.upstream and c.upstream.size else 0
        free -= free_claim

    def work(c: Candidate) -> Outcome:
        return converge(c, lock.entries.get(c.entry.id), store, ctx, streams[c.entry.id], store_is_real)

    with ThreadPoolExecutor(2) as pool:
        futures = {pool.submit(work, c): c for c in todo}
        for f in as_completed(futures):
            o = f.result()
            run.outcomes.append(o)
            log(f"  {o.entry_id}: {o.action} {o.detail}")
            if o.artefact:
                lock.record(o.entry_id, o.artefact, o.source, o.inputs or None)
                lock.save(LOCK_PATH)

    failed = [o for o in run.outcomes if o.action == "failed"]
    log("")
    log(outcome_table(run.outcomes, spec))
    if a.no_manifest:
        run.finish("staged" if not failed else "staged-with-failures").write(REPORTS)
        return 1 if failed else 0

    version = a.version or pick_version(store, datetime.now(timezone.utc).strftime("%Y.%m.%d"))
    run.version = version
    payload, cat_bytes = manifest_mod.build_manifest(spec, lock, version, now_iso())
    live, live_cat = read_live(store, public_b64, a.key_id, run.warnings.append)
    if manifest_mod.is_noop(payload, live, cat_bytes, live_cat):
        log(f"manifest unchanged against the live one (version {live.get('version')}); nothing written")
        run.finish("unchanged").write(REPORTS)
        return 1 if failed else 0
    cat_key = manifest_mod.catalogue_path(version)
    store.put_stream(cat_key, iter([cat_bytes]), payload["artefacts"][0]["sha256"], len(cat_bytes))
    env_bytes = sign.envelope_bytes(sign.sign(sign.canonical(payload), seed, a.key_id))
    env_sha = sha256_bytes(env_bytes)
    store.put_stream(f"manifests/manifest-{version}.json", iter([env_bytes]), env_sha, len(env_bytes))
    store.put_stream("manifest.json", iter([env_bytes]), env_sha, len(env_bytes))
    unconfirmed = sum(1 for e in lock.entries.values() if e.artefact and e.artefact.uploaded_at is None and not e.artefact.external_url)
    run.manifest = {"version": version, "artefacts": len(payload["artefacts"]), "catalogue": cat_key,
                    "bytes": sum(x["sizeBytes"] for x in payload["artefacts"]), "unconfirmedInStore": unconfirmed}
    log(f"\npublished manifest {version}: {len(payload['artefacts'])} artefacts, {run.manifest['bytes'] / 1e9:.1f} GB, signed with {a.key_id}")
    if unconfirmed:
        log(f"  {unconfirmed} lock entries were recorded by a fake store and are not confirmed in R2")
    run.finish("published" if not failed else "published-with-failures")
    log(f"report: {run.write(REPORTS)}")
    log(f"lock: {LOCK_PATH} (commit it)")
    return 1 if failed else 0


def catalogtool(*args: str) -> int:
    r = subprocess.run(["swift", "run", "--package-path", str(ROOT / "Core"), "catalogtool", *args])
    return r.returncode


def cmd_verify(a) -> int:
    base = (a.base or f"{a.origin}/updates/")
    log(f"catalogtool verify --base {base} --range-probe")
    return catalogtool("verify", "--base", base, "--range-probe")


def cmd_rollback(a) -> int:
    ws = worker_store(a)
    if ws is None:
        log(f"no upload secret at {UPLOAD_SECRET}")
        return 2
    raw = ws.get(f"manifests/manifest-{a.to}.json")
    if raw is None:
        log(f"no archived manifest for version {a.to}")
        return 1
    seed = sign.read_key(Path(a.key))
    payload = json.loads(sign.verify(json.loads(raw), sign.public_key_b64(seed), key_id=a.key_id))
    payload["publishedAt"] = now_iso()
    env = sign.envelope_bytes(sign.sign(sign.canonical(payload), seed, a.key_id))
    ws.put_stream("manifest.json", iter([env]), sha256_bytes(env), len(env))
    log(f"manifest.json now serves version {payload['version']} (re-signed, publishedAt {payload['publishedAt']})")
    return 0


def cmd_prune(a) -> int:
    ws = worker_store(a)
    if ws is None:
        log(f"no upload secret at {UPLOAD_SECRET}")
        return 2
    lock = Lock.load(LOCK_PATH)
    keep = set(lock.all_paths())
    seed = sign.read_key(Path(a.key))
    pub = sign.public_key_b64(seed)
    live, _ = read_live(ws, pub, a.key_id, log)
    if live:
        keep.update(x["path"] for x in live["artefacts"])
    cutoff = datetime.now(timezone.utc).timestamp() - a.older_than * 86400
    for m in ws.list("manifests/"):
        raw = ws.get(m.key)
        try:
            payload = json.loads(sign.verify(json.loads(raw), pub, key_id=a.key_id))
        except (ValueError, sign.BadSignature):
            continue
        published = datetime.fromisoformat(payload["publishedAt"].replace("Z", "+00:00")).timestamp()
        if published >= cutoff:
            keep.update(x["path"] for x in payload["artefacts"])
    victims = [o for prefix in ("zim/", "models/", "packs/", "maps/", "catalogue/") for o in ws.list(prefix) if o.key not in keep]
    total = sum(o.size for o in victims)
    for o in victims:
        log(f"  {'would delete' if not a.yes else 'deleting'} {o.key} ({o.size / 1e9:.2f} GB)")
    log(f"{len(victims)} objects, {total / 1e9:.1f} GB" + ("" if a.yes else "  (pass --yes to delete)"))
    if a.yes:
        for o in victims:
            ws.delete(o.key)
    return 0


def cmd_build(a) -> int:
    if a.what != "fieldguide":
        log("only `build fieldguide` exists")
        return 2
    return subprocess.run([sys.executable, str(HERE / "fieldguide.py"), *a.rest]).returncode


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--origin", default=ORIGIN)
    ap.add_argument("--content", help="content cache dir (default <repo>/content)")
    ap.add_argument("--key", default=str(DEFAULT_KEY))
    ap.add_argument("--key-id", default=DEFAULT_KEY_ID)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def scoped(p):
        p.add_argument("--tier", default="complete", choices=list(TIER_RANK))
        p.add_argument("--only", nargs="*")
        p.add_argument("--skip", nargs="*")

    sub.add_parser("doctor").set_defaults(fn=cmd_doctor)
    p = sub.add_parser("plan"); scoped(p); p.set_defaults(fn=cmd_plan)
    p = sub.add_parser("publish"); scoped(p)
    p.add_argument("--version")
    p.add_argument("--no-manifest", action="store_true")
    p.add_argument("--frozen", action="store_true", help="use the lock as is; resolve nothing")
    p.add_argument("--store", default="worker", choices=("worker", "fake"))
    p.add_argument("--out", help="with --store fake: where the fake store writes")
    p.add_argument("--offline", action="store_true", help="builders use caches and snapshots only")
    p.set_defaults(fn=cmd_publish)
    p = sub.add_parser("verify"); p.add_argument("--base"); p.set_defaults(fn=cmd_verify)
    p = sub.add_parser("rollback"); p.add_argument("--to", required=True); p.set_defaults(fn=cmd_rollback)
    p = sub.add_parser("prune"); p.add_argument("--older-than", type=int, default=60)
    g = p.add_mutually_exclusive_group(); g.add_argument("--dry-run", action="store_true"); g.add_argument("--yes", action="store_true")
    p.set_defaults(fn=cmd_prune)
    p = sub.add_parser("build"); p.add_argument("what"); p.add_argument("rest", nargs=argparse.REMAINDER); p.set_defaults(fn=cmd_build)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    raise SystemExit(main())
