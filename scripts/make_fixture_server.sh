#!/usr/bin/env bash
# Builds a tiny update-service fixture in fixture/out and (optionally) serves it on http://127.0.0.1:8787/.
#
#   scripts/make_fixture_server.sh                 # build fixture (downloads a small real GGUF the first time)
#   scripts/make_fixture_server.sh --mock-model    # build with a fake model file (no download; chat won't work)
#   scripts/make_fixture_server.sh --tiny-model    # use SmolLM2-135M (145 MB) instead of Qwen3-0.6B (400 MB)
#   scripts/make_fixture_server.sh --full-model    # use the real product default, Qwen3-4B-Instruct-2507 Q4_K_M (2.5 GB)
#   scripts/make_fixture_server.sh --serve         # build if needed, then serve manifest v1
#   scripts/make_fixture_server.sh --serve --version 2   # serve the "changed manifest" (v2) to demo an update
#   scripts/make_fixture_server.sh --serve --unsigned    # serve the plain manifest: the app refuses it on 8787
#
# Manifests are signed with scripts/dev-keys (key id dev-2026, offlinevault-manifest/1) so a DEBUG app shows
# "Verified OfflineVault catalogue"; the plain manifest.vN.json stays beside each manifest.vN.signed.json.
# Tiers mirror production: the catalogue, the Field Guide, the document pack and the overview map are free (no plan);
# the model, the video pack and the Florence map are core. The fixture contains: a catalogue, an original CC0 "field guide" ZIM with full-text index (v1 and a v2 that
# replaces it), a GGUF model, a video pack (ffmpeg-generated test clip + transcript) and a page pack. Manifest v2 also
# offers a book "from Kiwix": a third Field Guide build served under /kiwix/ with an absolute URL on port 8787, the way
# iFixit and MedlinePlus are offered from download.kiwix.org (an `external` artefact; docs/compete-plan.md item 6).
# Launch the app with --use-fixture-server (or toggle it in Settings › General) to use it.
# The server also answers POST /api/licence/activate with the dev-key licences in fixture/ (see fixture_server.py).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/fixture/out"; CACHE="$ROOT/fixture/cache"; VENV="$ROOT/fixture/.venv"
MODEL_MODE="qwen"; SERVE=0; VERSION=1; PORT=8787; UNSIGNED=""
while [[ $# -gt 0 ]]; do case "$1" in
  --mock-model) MODEL_MODE=mock;; --tiny-model) MODEL_MODE=tiny;; --full-model) MODEL_MODE=full;; --serve) SERVE=1;;
  --version) VERSION="$2"; shift;; --port) PORT="$2"; shift;; --rebuild) rm -rf "$OUT";; --unsigned) UNSIGNED="--unsigned";;
  *) echo "unknown flag $1"; exit 2;; esac; shift; done
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

FFMPEG="$ROOT/OfflineVault/Resources/bin/ffmpeg"; [[ -x "$FFMPEG" ]] || FFMPEG="$(command -v ffmpeg || true)"
# The Field Guide builder needs the pinned content toolchain (python-libzim, lxml, requests, pypdf), not the fixture venv.
CVENV="$ROOT/scripts/content/.venv"
content_venv() {
  if [[ ! -x "$CVENV/bin/python" ]]; then
    log "creating scripts/content/.venv from requirements.txt"
    python3 -m venv "$CVENV" && "$CVENV/bin/pip" -q install -r "$ROOT/scripts/content/requirements.txt"
  fi
}
# Ten articles from committed snapshots (no network): the same code path as production.
FG_ARTICLES="boil-bleach-filter finding-water storing-water bleeding-control cpr-and-choking shock burns safe-canning-principles staying-warm-indoors go-bag"
EXTERNAL_ZIM="kiwix/zimit/kiwix-fixture_en_2026-11.zim"

if [[ ! -f "$OUT/manifest.v2.json" ]]; then
  mkdir -p "$OUT/zim" "$OUT/models" "$OUT/packs" "$CACHE"

  # --- ZIM (python libzim) --------------------------------------------------------------------------
  if [[ ! -x "$VENV/bin/python" ]]; then log "creating venv with libzim"; python3 -m venv "$VENV"; "$VENV/bin/pip" -q install libzim >/dev/null; fi
  log "building fixture ZIMs"
  content_venv
  # Two editions of the real Field Guide builder.
  "$CVENV/bin/python" "$ROOT/scripts/content/fieldguide.py" build --offline --no-zimcheck --articles $FG_ARTICLES --date 2026-09-01 --out "$OUT/zim/fieldguide_en_2026-09.zim"
  "$CVENV/bin/python" "$ROOT/scripts/content/fieldguide.py" build --offline --no-zimcheck --articles $FG_ARTICLES --date 2026-10-01 --out "$OUT/zim/fieldguide_en_2026-10.zim"

  # --- Model -------------------------------------------------------------------------------------
  case "$MODEL_MODE" in
    qwen) MODEL_FILE="Qwen3-0.6B-Q4_K_M.gguf"; MODEL_URL="https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"; MODEL_ID="model-fixture";;
    full) MODEL_FILE="Qwen3-4B-Instruct-2507-Q4_K_M.gguf"; MODEL_URL="https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"; MODEL_ID="model-qwen3-4b-q4_k_m";;
    tiny) MODEL_FILE="SmolLM2-135M-Instruct-Q8_0.gguf"; MODEL_URL="https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q8_0.gguf"; MODEL_ID="model-fixture";;
    mock) MODEL_FILE="mock-model.gguf"; MODEL_URL=""; MODEL_ID="model-fixture";;
  esac
  if [[ -n "$MODEL_URL" ]]; then
    if [[ ! -f "$CACHE/$MODEL_FILE" ]]; then log "downloading $MODEL_FILE (one-time, cached in fixture/cache)"; curl -fL --retry 3 --progress-bar -o "$CACHE/$MODEL_FILE.tmp" "$MODEL_URL" && mv "$CACHE/$MODEL_FILE.tmp" "$CACHE/$MODEL_FILE"; fi
    cp "$CACHE/$MODEL_FILE" "$OUT/models/$MODEL_FILE"
  else
    printf 'GGUF' > "$OUT/models/$MODEL_FILE"; head -c 65536 /dev/urandom >> "$OUT/models/$MODEL_FILE"
  fi

  # --- Video pack ------------------------------------------------------------------------------------
  log "generating fixture video"
  VP="$CACHE/videopack"; rm -rf "$VP"; mkdir -p "$VP"
  [[ -n "$FFMPEG" ]] || die "ffmpeg not found; run scripts/fetch_binaries.sh first"
  "$FFMPEG" -y -loglevel error -f lavfi -i "testsrc2=size=640x360:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 30 \
     -c:v libx264 -pix_fmt yuv420p -preset veryfast -c:a aac -shortest -movflags +faststart "$VP/fixture-water-talk.mp4"
  "$FFMPEG" -y -loglevel error -ss 2 -i "$VP/fixture-water-talk.mp4" -frames:v 1 -vf scale=480:-2 "$VP/fixture-water-talk.jpg"
  cat > "$VP/fixture-water-talk.en.vtt" <<'VTT'
WEBVTT

00:00:00.500 --> 00:00:05.000
Welcome to the fixture field talk. Today we cover making water safe to drink in the field.

00:00:05.000 --> 00:00:11.000
The most reliable method is boiling: bring water to a rolling boil for one full minute, three minutes above two thousand metres.

00:00:11.000 --> 00:00:18.000
If you cannot boil, use unscented bleach: two drops per litre of clear water, wait thirty minutes before drinking.

00:00:18.000 --> 00:00:25.000
A filter rated to point two microns removes bacteria and protozoa, but not viruses, so combine it with chemical treatment.

00:00:25.000 --> 00:00:29.500
That's it for this short clip. Stay safe and keep your water clean.
VTT
  cat > "$VP/fixture-water-talk.json" <<JSON
{
  "id": "fixture-water-talk", "title": "Fixture: making water safe to drink", "channel": "OfflineVault fixtures",
  "durationSeconds": 30, "uploadDate": "20260901", "description": "A generated public-domain test clip with a spoken-style transcript about water purification. Not real footage.",
  "webpageURL": null, "quality": "360p", "fileName": "fixture-water-talk.mp4", "thumbnailFile": "fixture-water-talk.jpg",
  "subtitleFile": "fixture-water-talk.en.vtt", "downloadedAt": "2026-09-01T12:00:00Z", "sourceURL": null
}
JSON
  tar -czf "$OUT/packs/video-starter.tar.gz" -C "$VP" .

  # --- Page pack ---------------------------------------------------------------------------------------
  log "generating fixture page pack"
  PP="$CACHE/pagepack"; rm -rf "$PP"; mkdir -p "$PP"
  cat > "$PP/fixture-knots.html" <<'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
<meta name="offlinevault-source" content="https://fixture.offlinevault.example/knots">
<meta name="offlinevault-captured" content="2026-09-01T12:00:00Z">
<title>Three knots every camp needs – Fixture Pages</title>
<style>body{font-family:-apple-system,sans-serif;max-width:40em;margin:2em auto;line-height:1.5}</style></head>
<body><article><h1>Three knots every camp needs</h1>
<p>The <b>bowline</b> makes a fixed loop that will not slip or jam under load; use it to tie a line around a tree or through a tarp grommet. Form a small loop, pass the working end up through it, around the standing part and back down.</p>
<p>The <b>trucker's hitch</b> gives a 3:1 mechanical advantage for tensioning a ridgeline. Tie a slipped loop in the standing part, pass the working end around the anchor and back through the loop, pull tight and finish with two half hitches.</p>
<p>The <b>taut-line hitch</b> is an adjustable loop for guy lines: it holds under tension but slides when you push the knot by hand.</p>
<p>Inspect rope for cuts and glazing before trusting it with a load; retire any rope that has held a shock load.</p>
</article></body></html>
HTML
  PAGE_ID="$(printf 'https://fixture.offlinevault.example/knots' | shasum -a 256 | cut -c1-16)"
  mv "$PP/fixture-knots.html" "$PP/$PAGE_ID.html"
  cat > "$PP/$PAGE_ID.json" <<JSON
{ "id": "$PAGE_ID", "url": "https://fixture.offlinevault.example/knots", "title": "Three knots every camp needs – Fixture Pages", "capturedAt": "2026-09-01T12:00:00Z", "assetCount": 0 }
JSON
  tar -czf "$OUT/packs/pages-starter.tar.gz" -C "$PP" .

  # --- Tiny "website" for the page-capture demo (served at /site/index.html) ------------------------------
  log "generating fixture website"
  mkdir -p "$OUT/site"
  python3 - "$OUT/site" <<'PY'
import sys, struct, zlib, os
out = sys.argv[1]
raw = b"".join(b"\x00" + bytes([200, 120, 40]) * 32 for _ in range(32))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(os.path.join(out, "logo.png"), "wb").write(png)
open(os.path.join(out, "style.css"), "w").write("body{font-family:-apple-system,sans-serif;max-width:40em;margin:2em auto;line-height:1.5} h1{background:url(logo.png) no-repeat left center;padding-left:40px}")
open(os.path.join(out, "index.html"), "w").write("""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Fixture site &ndash; shelter basics</title>
<link rel="stylesheet" href="style.css"><script src="tracker.js"></script><link rel="preload" href="font.woff2" as="font"></head>
<body onload="track()"><nav><a href="/">Home</a></nav>
<main><article><h1>Shelter basics</h1><img src="logo.png" alt="logo">
<p>A <b>lean-to</b> is the fastest emergency shelter: a ridgepole lashed between two trees at chest height, with poles leaned against it on the windward side and covered with boughs or a tarp.</p>
<p>Insulate from the ground with at least a hand's depth of dry leaves or boughs; most heat is lost downward.</p>
<p>Keep the opening away from the wind and build a reflector wall for a fire two to three metres from the entrance.</p>
</article></main><footer>Fixture content, CC0.</footer></body></html>""")
open(os.path.join(out, "tracker.js"), "w").write("window.track=function(){fetch('https://tracker.invalid/pixel')}")
PY

  # --- Document pack (PDF manuals) ---------------------------------------------------------------------------
  log "generating fixture document pack"
  DP="$CACHE/docpack"; rm -rf "$DP"; mkdir -p "$DP"
  cp "$ROOT/Core/Tests/OfflineVaultCoreTests/Fixtures/sample_guide.pdf" "$DP/field-water-treatment-guide.pdf"
  cat > "$DP/field-water-treatment-guide.json" <<'JSON'
{ "title": "Field Water Treatment Guide (fixture)", "publisher": "OfflineVault fixtures", "licence": "CC0-1.0", "role": "procedural",
  "summary": "Two-page CC0 test document: boiling and chemical disinfection." }
JSON
  # One real public-domain manual when reachable (FEMA "Are You Ready?", 4 MB). Skipped silently offline.
  if [[ ! -f "$CACHE/fema-are-you-ready.pdf" ]]; then
    curl -fsL --max-time 120 -A "Mozilla/5.0" -o "$CACHE/fema-are-you-ready.pdf.tmp" "https://www.ready.gov/sites/default/files/2021-11/are-you-ready-guide.pdf" && head -c 4 "$CACHE/fema-are-you-ready.pdf.tmp" | grep -q PDF && mv "$CACHE/fema-are-you-ready.pdf.tmp" "$CACHE/fema-are-you-ready.pdf" || rm -f "$CACHE/fema-are-you-ready.pdf.tmp"
  fi
  if [[ -f "$CACHE/fema-are-you-ready.pdf" ]]; then
    cp "$CACHE/fema-are-you-ready.pdf" "$DP/fema-are-you-ready.pdf"
    cat > "$DP/fema-are-you-ready.json" <<'JSON'
{ "title": "Are You Ready? An In-depth Guide to Citizen Preparedness (FEMA)", "publisher": "FEMA", "licence": "Public domain (US Government)", "role": "procedural",
  "sourceURL": "https://www.ready.gov/sites/default/files/2021-11/are-you-ready-guide.pdf",
  "summary": "FEMA's comprehensive preparedness guide: kits, plans and hazard-specific actions." }
JSON
  fi
  tar -czf "$OUT/packs/docs-starter.tar.gz" -C "$DP" .

  # --- Offline map sample (Protomaps' public Florence extract, ODbL, 6.6 MB) -----------------------------------
  mkdir -p "$OUT/maps"
  if [[ ! -f "$CACHE/firenze.pmtiles" ]]; then
    log "downloading sample map region (Florence)"
    curl -fsL -o "$CACHE/firenze.pmtiles.tmp" "https://pmtiles.io/protomaps(vector)ODbL_firenze.pmtiles" && mv "$CACHE/firenze.pmtiles.tmp" "$CACHE/firenze.pmtiles" || rm -f "$CACHE/firenze.pmtiles.tmp"
  fi
  if [[ -f "$CACHE/firenze.pmtiles" ]]; then
    echo "7190f3d807a62f4f012b574007c96b809f6842f45a6b0c508639331fc68fd30a  $CACHE/firenze.pmtiles" | shasum -a 256 -c - >/dev/null && cp "$CACHE/firenze.pmtiles" "$OUT/maps/firenze.pmtiles" || warn "firenze.pmtiles checksum mismatch; skipping map sample"
  fi

  # World overview (zoom 0–5, ~14 MB) built from the Protomaps planet with the bundled pmtiles tool; skipped offline.
  PMT="$ROOT/OfflineVault/Resources/bin/pmtiles"
  if [[ ! -f "$CACHE/world-overview.pmtiles" && -x "$PMT" ]]; then
    log "extracting world overview (zoom 0–5) from the Protomaps planet build"
    "$PMT" extract "https://build.protomaps.com/$(date -u -v-1d +%Y%m%d 2>/dev/null || date -u -d yesterday +%Y%m%d).pmtiles" "$CACHE/world-overview.pmtiles" --maxzoom=5 >/dev/null 2>&1 || rm -f "$CACHE/world-overview.pmtiles"
  fi
  [[ -f "$CACHE/world-overview.pmtiles" ]] && cp "$CACHE/world-overview.pmtiles" "$OUT/maps/world-overview.pmtiles"
  log "fixture content ready in $OUT"
else
  log "fixture already built in $OUT (use --rebuild to regenerate)"
fi

# --- A book "from Kiwix" ---------------------------------------------------------------------------------------
# A third Field Guide build (different date, so a distinct ZIM uuid) outside the catalogue's folders. Manifest v2
# points at it with an absolute URL, so the app and ovsync exercise the external download path against this server.
if [[ ! -f "$OUT/$EXTERNAL_ZIM" ]]; then
  log "building the external (from Kiwix) fixture ZIM"
  content_venv
  mkdir -p "$(dirname "$OUT/$EXTERNAL_ZIM")"
  "$CVENV/bin/python" "$ROOT/scripts/content/fieldguide.py" build --offline --no-zimcheck --articles $FG_ARTICLES --date 2026-11-01 --out "$OUT/$EXTERNAL_ZIM"
fi

# --- Catalogue + manifests -----------------------------------------------------------------------------
# Rewritten on every run (a second of hashing): the external book's URL carries the serve port, and an edit here is
# then enough to change what the fixture serves. The model file is whichever build put in models/ (one file), so a
# rerun never has to repeat the mode flag. Ed25519 signatures are deterministic, so unchanged input re-signs to the same bytes.
MODEL_FILE="$(ls "$OUT/models" | head -1)"
[[ "$MODEL_FILE" == Qwen3-4B* ]] && MODEL_ID="model-qwen3-4b-q4_k_m" || MODEL_ID="model-fixture"
log "writing catalogue and manifests (external book on port $PORT)"
MODEL_FILE_ENV="$MODEL_FILE" MODEL_ID_ENV="$MODEL_ID" EXTERNAL_ZIM_ENV="$EXTERNAL_ZIM" PORT_ENV="$PORT" python3 - "$OUT" <<'PY'
import json, hashlib, os, sys
out = sys.argv[1]; model = os.environ["MODEL_FILE_ENV"]; model_id = os.environ["MODEL_ID_ENV"]; external_zim = os.environ["EXTERNAL_ZIM_ENV"]
# The URL the manifest signs. It names this server's port, which is what makes the download "external": an absolute
# URL under a path the catalogue never uses, rather than a path relative to the updates base.
external_url = f"http://127.0.0.1:{os.environ['PORT_ENV']}/" + external_zim
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    return h.hexdigest()
def art(id_, kind, path, title=None, summary=None, replaces=(), min_app="1.0.0", tier="core", external_file=None):
    full = os.path.join(out, external_file or path)
    a = {"id": id_, "kind": kind, "path": path, "sizeBytes": os.path.getsize(full), "sha256": sha(full), "minAppVersion": min_app, "tier": tier}
    if replaces: a["replaces"] = list(replaces)
    if title: a["title"] = title
    if summary: a["summary"] = summary
    if external_file: a["external"] = {"url": external_url, "shaSource": "kiwix-meta4", "licence": "CC BY-NC-SA 3.0", "attribution": "OfflineVault fixtures, standing in for a Kiwix book"}
    return a
cat_v1 = {"catalogueVersion": "1", "entries": [
    {"artefactId": "zim-fieldguide-2026-09", "title": "Field Guide (fixture)", "description": "Ten articles from the OfflineVault Field Guide: water, bleeding, CPR, shock, burns, canning, warmth, go-bag.", "language": "eng", "licence": "CC-BY-SA-4.0", "attribution": "OfflineVault; Wikipedia and Wikibooks contributors (CC BY-SA 4.0); US Government works (public domain)", "articleCount": 10, "fileName": "fieldguide_en_2026-09", "role": "procedural", "tier": "core"},
    {"artefactId": "docs-starter", "title": "Starter document pack", "description": "PDF manuals: fixture water guide" + (" and FEMA Are You Ready?" if os.path.exists(os.path.join(out, "..", "cache", "fema-are-you-ready.pdf")) else ""), "licence": "CC0 / Public domain", "role": "procedural", "tier": "core"},
    {"artefactId": model_id, "title": model.replace('.gguf',''), "description": "Instruct model (Apache-2.0). Qwen3-4B-Instruct-2507 is the production default; the 0.6B build is a development stand-in.", "licence": "Apache-2.0", "fileName": model}]}
cat_v2 = json.loads(json.dumps(cat_v1)); cat_v2["catalogueVersion"] = "2"
cat_v2["entries"][0].update({"artefactId": "zim-fieldguide-2026-10", "title": "Field Guide (fixture, Nov)", "fileName": "fieldguide_en_2026-10"})
cat_v2["entries"].append({"artefactId": "zim-kiwix-fixture-2026-11", "title": "Field Guide from Kiwix (fixture)", "description": "The ten fixture articles offered the way iFixit and MedlinePlus are: downloaded from Kiwix's own server, not from the catalogue.", "language": "eng", "licence": "CC BY-NC-SA 3.0", "attribution": "OfflineVault fixtures, standing in for a Kiwix book", "articleCount": 10, "fileName": "kiwix-fixture_en_2026-11", "role": "procedural", "tier": "free", "sourceURL": external_url})
os.makedirs(os.path.join(out, "catalogue"), exist_ok=True)
json.dump(cat_v1, open(os.path.join(out, "catalogue", "catalogue-2026.10.01.json"), "w"), indent=2)
json.dump(cat_v2, open(os.path.join(out, "catalogue", "catalogue-2026.10.08.json"), "w"), indent=2)
m1 = {"version": "2026.10.01", "publishedAt": "2026-10-01T12:00:00Z", "catalogueVersion": "1", "artefacts": [
    art("catalogue", "catalogue", "catalogue/catalogue-2026.10.01.json", "Catalogue", tier="free"),
    art("zim-fieldguide-2026-09", "zim", "zim/fieldguide_en_2026-09.zim", "Field Guide (fixture)", "Ten Field Guide articles with full-text search.", tier="free"),
    art(model_id, "model", f"models/{model}", "AI model", "Instruct model so chat works against the fixture."),
    art("video-starter", "video-pack", "packs/video-starter.tar.gz", "Starter video pack", "One generated test clip with a transcript."),
    art("docs-starter", "document-pack", "packs/docs-starter.tar.gz", "Starter document pack", "PDF manuals, indexed page by page.", tier="free"),
] + ([art("map-firenze", "map", "maps/firenze.pmtiles", "Sample map region (Florence)", "Offline street map, OpenStreetMap data, zoom 0–15.")] if os.path.exists(os.path.join(out, "maps", "firenze.pmtiles")) else [])
  + ([art("map-world-overview", "map", "maps/world-overview.pmtiles", "World overview map", "Whole-planet base map (zoom 0–5) so the map pans everywhere; regions add street detail.", tier="free")] if os.path.exists(os.path.join(out, "maps", "world-overview.pmtiles")) else [])}
m2 = {"version": "2026.10.08", "publishedAt": "2026-10-08T12:00:00Z", "catalogueVersion": "2", "artefacts": [
    art("catalogue", "catalogue", "catalogue/catalogue-2026.10.08.json", "Catalogue", tier="free"),
    art("zim-fieldguide-2026-10", "zim", "zim/fieldguide_en_2026-10.zim", "Field Guide (fixture, Nov)", "October edition, replaces the September file.", replaces=["zim-fieldguide-2026-09"], tier="free"),
    art(model_id, "model", f"models/{model}", "AI model"),
    art("video-starter", "video-pack", "packs/video-starter.tar.gz", "Starter video pack"),
    art("docs-starter", "document-pack", "packs/docs-starter.tar.gz", "Starter document pack", "PDF manuals, indexed page by page.", tier="free"),
    art("pages-starter", "page-pack", "packs/pages-starter.tar.gz", "Starter page pack", "One captured page about knots."),
] + ([art("map-firenze", "map", "maps/firenze.pmtiles", "Sample map region (Florence)", "Offline street map, OpenStreetMap data, zoom 0–15.")] if os.path.exists(os.path.join(out, "maps", "firenze.pmtiles")) else [])
  + ([art("map-world-overview", "map", "maps/world-overview.pmtiles", "World overview map", "Whole-planet base map (zoom 0–5).", tier="free")] if os.path.exists(os.path.join(out, "maps", "world-overview.pmtiles")) else []) + [
    art("zim-fieldguide-full", "zim", "zim/fieldguide_en_2026-10.zim", "Field Guide – full edition (fixture)", "Stands in for a large tier-2 download.", tier="full"),
    art("zim-future", "zim", "zim/fieldguide_en_2026-10.zim", "Needs a newer app", min_app="9.0.0"),
    art("zim-kiwix-fixture-2026-11", "zim", "zim/kiwix-fixture_en_2026-11.zim", "Field Guide from Kiwix (fixture)", "Offered from Kiwix's server, the way iFixit and MedlinePlus are.", tier="free", external_file=external_zim),
]}
json.dump(m1, open(os.path.join(out, "manifest.v1.json"), "w"), indent=2)
json.dump(m2, open(os.path.join(out, "manifest.v2.json"), "w"), indent=2)
print("manifest v1:", [a["id"] for a in m1["artefacts"]]); print("manifest v2:", [a["id"] for a in m2["artefacts"]])
PY

# Sign each manifest with the dev key whenever the plain file is newer than its envelope. The payload is the file
# byte for byte, which is what the app verifies and parses.
for v in 1 2; do
  if [[ ! -f "$OUT/manifest.v$v.signed.json" || "$OUT/manifest.v$v.json" -nt "$OUT/manifest.v$v.signed.json" ]]; then
    log "signing manifest v$v with scripts/dev-keys (dev-2026)"
    (cd "$ROOT/Core" && swift run licencetool sign-envelope --format offlinevault-manifest/1 --key "$ROOT/scripts/dev-keys/licence-private.key" --key-id dev-2026 --payload "$OUT/manifest.v$v.json" --out "$OUT/manifest.v$v.signed.json" >/dev/null)
  fi
done

# Dev licences for POST /api/licence/activate are committed; regenerate them only if one is missing.
if ! ls "$ROOT"/fixture/dev-licence-*.json >/dev/null 2>&1; then
  log "signing dev licences with scripts/dev-keys"
  (cd "$ROOT/Core" && swift run licencetool fixtures --out ..)
fi

if [[ $SERVE == 1 ]]; then
  exec python3 "$ROOT/scripts/fixture_server.py" --root "$OUT" --port "$PORT" --version "$VERSION" $UNSIGNED
fi
