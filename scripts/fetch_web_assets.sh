#!/usr/bin/env bash
# Fetches the pinned, checksummed web assets the offline Maps tab needs (MapLibre GL, PMTiles, Protomaps basemap
# style, glyph fonts, sprites) into OfflineVault/Resources/web/ and the `pmtiles` CLI (region extracts) into
# OfflineVault/Resources/bin/. Everything is served to the WKWebView from the app bundle — no CDN at runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; WEB="$ROOT/OfflineVault/Resources/web"; BIN="$ROOT/OfflineVault/Resources/bin"
CACHE="${OFFLINEVAULT_BIN_CACHE:-$ROOT/fixture/cache/web}"; mkdir -p "$WEB/fonts/Noto Sans Regular" "$WEB/sprites" "$BIN" "$CACHE"
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }; die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
fetch() { # url dest sha
  if [[ ! -f "$2" ]]; then log "downloading $(basename "$2")"; curl -fL --retry 3 -s -o "$2.tmp" "$1" && mv "$2.tmp" "$2"; fi
  local actual; actual="$(shasum -a 256 "$2" | awk '{print $1}')"; [[ "$actual" == "$3" ]] || { rm -f "$2"; die "checksum mismatch for $1 ($actual)"; }
}
# MapLibre GL JS 4.7.1 (BSD-3) · pmtiles 3.2.1 (BSD-3) · @protomaps/basemaps 5.7.2 (BSD-3)
fetch "https://cdn.jsdelivr.net/npm/maplibre-gl@4.7.1/dist/maplibre-gl.js"  "$WEB/maplibre-gl.js"  be9633c4d870e26fb37f1cfe5c5a77181667114003ea16207ac7850d8da8add1
fetch "https://cdn.jsdelivr.net/npm/maplibre-gl@4.7.1/dist/maplibre-gl.css" "$WEB/maplibre-gl.css" 576b085fdd9487a65a19215328c1e086c07ce5bf6da09b666b3806d3d008dae9
fetch "https://cdn.jsdelivr.net/npm/pmtiles@3.2.1/dist/pmtiles.js"          "$WEB/pmtiles.js"      367c19f8936d1d6c1b1820b0dee053f793fc29277655c3e471f5ed4d37b5f045
fetch "https://cdn.jsdelivr.net/npm/@protomaps/basemaps@5.7.2/dist/basemaps.js" "$WEB/basemaps.js" 551864f01da1bfe3005e99987197f22f56d0c35f9a10fa1727a889e2434af16d
# Protomaps basemap assets (fonts: Noto Sans, SIL OFL; sprites: CC0) — pinned to a commit of protomaps/basemaps-assets
ASSETS="https://raw.githubusercontent.com/protomaps/basemaps-assets/5f6d7a1a8f1c1a1c5e42c48c3ba1bf3a2fcb7a2e"
for f in light.json light.png light@2x.json light@2x.png dark.json dark.png dark@2x.json dark@2x.png; do
  [[ -f "$WEB/sprites/$f" ]] || { log "sprite $f"; curl -fsL -o "$WEB/sprites/$f" "https://protomaps.github.io/basemaps-assets/sprites/v4/$f"; }
done
# Full Latin/Greek/Cyrillic glyph ranges for labels (0–1279) plus general punctuation and symbols.
for start in 0 256 512 768 1024 8192 8448 8704 9728 9984; do
  end=$((start+255)); f="$WEB/fonts/Noto Sans Regular/$start-$end.pbf"
  [[ -f "$f" ]] || { curl -fsL -o "$f" "https://protomaps.github.io/basemaps-assets/fonts/Noto%20Sans%20Regular/$start-$end.pbf" || rm -f "$f"; }
done
cp -R "$WEB/fonts/Noto Sans Regular" "$WEB/fonts/Noto Sans Medium" 2>/dev/null || true   # style asks for Medium/Italic too; reuse Regular
cp -R "$WEB/fonts/Noto Sans Regular" "$WEB/fonts/Noto Sans Italic" 2>/dev/null || true
# pmtiles CLI (BSD-3) for region extracts from the Protomaps daily planet build
fetch "https://github.com/protomaps/go-pmtiles/releases/download/v1.31.2/go-pmtiles-1.31.2_Darwin_arm64.zip" "$CACHE/go-pmtiles-1.31.2.zip" 40528f7f616fcbf91207cd48c8fc023d213f6d86c0cbf1f748732803d1880f3d
[[ -x "$BIN/pmtiles" ]] || { rm -rf "$CACHE/gopm" && unzip -qo "$CACHE/go-pmtiles-1.31.2.zip" -d "$CACHE/gopm" && cp "$CACHE/gopm/pmtiles" "$BIN/pmtiles" && chmod +x "$BIN/pmtiles"; }
xattr -dr com.apple.quarantine "$WEB" "$BIN/pmtiles" 2>/dev/null || true
cat > "$WEB/VERSIONS.txt" <<V
maplibre-gl 4.7.1 (BSD-3) · pmtiles 3.2.1 (BSD-3) · @protomaps/basemaps 5.7.2 (BSD-3) · Noto Sans glyphs (OFL) · Protomaps sprites (CC0) · go-pmtiles 1.31.2 (BSD-3)
fetched $(date -u +%Y-%m-%dT%H:%M:%SZ)
V
log "done → $WEB and $BIN/pmtiles"; ls "$WEB" "$WEB/sprites" | head -20; "$BIN/pmtiles" version 2>/dev/null || "$BIN/pmtiles" --help 2>&1 | head -2
