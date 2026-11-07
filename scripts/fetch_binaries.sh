#!/usr/bin/env bash
# Downloads pinned helper binaries for OfflineVault (macOS, Apple Silicon), verifies SHA-256 checksums
# recorded below, and places them in OfflineVault/Resources/bin/ (git-ignored).
#
# Usage: scripts/fetch_binaries.sh [--allow-rosetta] [--force]
#
#   --allow-rosetta   kiwix-tools publishes NO macOS arm64 build (only x86_64). On Apple Silicon the default is
#                     to build a static arm64 kiwix-serve from source (scripts/build_kiwix_serve.sh, needs the
#                     brew tools it names). With this flag the x86_64 download is installed instead and the app
#                     runs it under Rosetta 2 (/usr/bin/arch -x86_64). On Intel the download is the only path.
#   --force           re-download even if the binary is already present.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/OfflineVault/Resources/bin"
CACHE="${OFFLINEVAULT_BIN_CACHE:-$ROOT/fixture/cache/bin}"
ALLOW_ROSETTA=0; FORCE=0
for a in "$@"; do case "$a" in --allow-rosetta) ALLOW_ROSETTA=1;; --force) FORCE=1;; *) echo "unknown flag $a"; exit 2;; esac; done
mkdir -p "$BIN" "$CACHE"

# ---- Pinned versions and checksums (SHA-256 of the downloaded archive/binary) ---------------------
LLAMA_TAG="b11552"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-bin-macos-arm64.tar.gz"
LLAMA_SHA="f4b33fe40d098033fb1a19a8a4a84383c4ca84c37b6a60d9f9a253f349b48c07"

YTDLP_VERSION="2026.08.19"
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos"   # universal2 (x86_64 + arm64)
YTDLP_SHA="0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"                    # matches upstream SHA2-256SUMS

FFMPEG_VERSION="9.0.2"
FFMPEG_BUILD="1789931890_9.0.2"
FFMPEG_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/${FFMPEG_BUILD}/ffmpeg.zip"   # static arm64 build, GPL
FFMPEG_SHA="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"                   # matches upstream ffmpeg.zip.sha256

KIWIX_VERSION="3.8.2"
KIWIX_URL="https://download.kiwix.org/release/kiwix-tools/kiwix-tools_macos-x86_64-${KIWIX_VERSION}.tar.gz"   # x86_64 only; arm64 is built by scripts/build_kiwix_serve.sh
KIWIX_SHA="ae341280e97ad5902e7a4282a24340eac7d7061c267661c0ef2a88a34547f247"
# -------------------------------------------------------------------------------------------------

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # url dest sha
  local url="$1" dest="$2" sha="$3"
  if [[ ! -f "$dest" || $FORCE == 1 ]]; then
    log "downloading $(basename "$dest")"
    curl -fL --retry 3 --progress-bar -o "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
  fi
  local actual; actual="$(shasum -a 256 "$dest" | awk '{print $1}')"
  [[ "$actual" == "$sha" ]] || { rm -f "$dest"; die "checksum mismatch for $url\n  expected $sha\n  actual   $actual"; }
  log "verified $(basename "$dest") ($sha)"
}

# llama-server (+ dylibs it links against)
if [[ ! -x "$BIN/llama/llama-server" || $FORCE == 1 ]]; then
  fetch "$LLAMA_URL" "$CACHE/llama-${LLAMA_TAG}.tar.gz" "$LLAMA_SHA"
  rm -rf "$BIN/llama" "$CACHE/llama-x" && mkdir -p "$CACHE/llama-x" "$BIN/llama"
  tar -xzf "$CACHE/llama-${LLAMA_TAG}.tar.gz" -C "$CACHE/llama-x"
  SRC="$(find "$CACHE/llama-x" -mindepth 1 -maxdepth 1 -type d -name 'llama-*' | head -1)"
  cp "$SRC/llama-server" "$BIN/llama/"
  cp "$SRC"/*.dylib "$BIN/llama/"
  cp "$SRC/LICENSE" "$BIN/llama/LICENSE.llama.cpp" 2>/dev/null || true
  chmod +x "$BIN/llama/llama-server"
  rm -rf "$CACHE/llama-x"
fi

# yt-dlp
if [[ ! -x "$BIN/yt-dlp" || $FORCE == 1 ]]; then
  fetch "$YTDLP_URL" "$CACHE/yt-dlp_macos-${YTDLP_VERSION}" "$YTDLP_SHA"
  cp "$CACHE/yt-dlp_macos-${YTDLP_VERSION}" "$BIN/yt-dlp" && chmod +x "$BIN/yt-dlp"
fi

# ffmpeg
if [[ ! -x "$BIN/ffmpeg" || $FORCE == 1 ]]; then
  fetch "$FFMPEG_URL" "$CACHE/ffmpeg-${FFMPEG_VERSION}-arm64.zip" "$FFMPEG_SHA"
  rm -rf "$CACHE/ff-x" && mkdir -p "$CACHE/ff-x" && unzip -qo "$CACHE/ffmpeg-${FFMPEG_VERSION}-arm64.zip" -d "$CACHE/ff-x"
  cp "$CACHE/ff-x/ffmpeg" "$BIN/ffmpeg" && chmod +x "$BIN/ffmpeg" && rm -rf "$CACHE/ff-x"
fi

# kiwix-serve
if [[ ! -x "$BIN/kiwix-serve" || $FORCE == 1 ]]; then
  if [[ "$(uname -m)" == "arm64" && $ALLOW_ROSETTA != 1 ]]; then
    log "building kiwix-serve for arm64 from source (kiwix-tools ${KIWIX_VERSION} ships x86_64 only; --allow-rosetta takes the download instead)"
    "$ROOT/scripts/build_kiwix_serve.sh" "$BIN/kiwix-serve"
  else
    [[ "$(uname -m)" != "arm64" ]] || arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta 2 is not installed: softwareupdate --install-rosetta --agree-to-license"
    fetch "$KIWIX_URL" "$CACHE/kiwix-tools-${KIWIX_VERSION}-x86_64.tar.gz" "$KIWIX_SHA"
    rm -rf "$CACHE/kw-x" && mkdir -p "$CACHE/kw-x" && tar -xzf "$CACHE/kiwix-tools-${KIWIX_VERSION}-x86_64.tar.gz" -C "$CACHE/kw-x"
    cp "$(find "$CACHE/kw-x" -name kiwix-serve -type f | head -1)" "$BIN/kiwix-serve" && chmod +x "$BIN/kiwix-serve" && rm -rf "$CACHE/kw-x"
  fi
fi
if [[ "$(lipo -archs "$BIN/kiwix-serve")" == "arm64" ]]; then
  KIWIX_LINE="kiwix-tools   ${KIWIX_VERSION}  built from source by scripts/build_kiwix_serve.sh (kiwix-build macos_arm64_static)  sha256=$(shasum -a 256 "$BIN/kiwix-serve" | awk '{print $1}')  (arm64, static)"
  KIWIX_RUN=("$BIN/kiwix-serve")
else
  KIWIX_LINE="kiwix-tools   ${KIWIX_VERSION}  ${KIWIX_URL}  sha256=${KIWIX_SHA}  (x86_64, Rosetta 2)"
  KIWIX_RUN=(arch -x86_64 "$BIN/kiwix-serve")
fi

# Remove quarantine flags that would otherwise block execution when the folder is copied around.
xattr -dr com.apple.quarantine "$BIN" 2>/dev/null || true

cat > "$BIN/VERSIONS.txt" <<V
llama.cpp     ${LLAMA_TAG}      ${LLAMA_URL}  sha256=${LLAMA_SHA}
yt-dlp        ${YTDLP_VERSION}  ${YTDLP_URL}  sha256=${YTDLP_SHA}
ffmpeg        ${FFMPEG_VERSION} ${FFMPEG_URL}  sha256=${FFMPEG_SHA}
${KIWIX_LINE}
fetched       $(date -u +%Y-%m-%dT%H:%M:%SZ)
V

log "smoke tests"
"$BIN/llama/llama-server" --version 2>&1 | head -1
"$BIN/yt-dlp" --version
"$BIN/ffmpeg" -version | head -1
"${KIWIX_RUN[@]}" --version | head -1
log "done → $BIN"
