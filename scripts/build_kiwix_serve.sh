#!/usr/bin/env bash
# Builds a static arm64 kiwix-serve from source. kiwix-tools publishes macOS binaries for x86_64 only, so this
# runs Kiwix's own build tool (kiwix-build, pinned to a commit) with its macos_arm64_static config: every
# dependency (libkiwix, libzim, xapian, icu, libmicrohttpd, libcurl, zlib, zstd, lzma, pugixml) is fetched from
# the archive kiwix-build pins, checksum-verified by it, and linked statically. About three minutes on an M-series
# Mac. The result links only system frameworks (check with otool -L).
#
#   scripts/build_kiwix_serve.sh [destination]        default OfflineVault/Resources/bin/kiwix-serve
#
# Needs: brew install meson ninja cmake automake autoconf libtool pkg-config
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/OfflineVault/Resources/bin/kiwix-serve}"
WORK="${OFFLINEVAULT_BIN_CACHE:-$ROOT/fixture/cache/bin}/kiwix-build"
KIWIX_BUILD_REPO="https://github.com/kiwix/kiwix-build"
KIWIX_BUILD_COMMIT="e7343a1640de5379c212eac2aec6ba32c9fd2d31"   # builds kiwix-tools 3.8.2 on libkiwix 14.3.0 / libzim 9.8.2
KIWIX_TOOLS_VERSION="3.8.2"
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/libtool/libexec/gnubin:$PATH"

die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || die "this builds the arm64 kiwix-serve and must run on an Apple Silicon Mac"
missing=()
for t in meson ninja cmake automake autoconf glibtoolize pkg-config python3; do command -v "$t" >/dev/null || missing+=("$t"); done
[[ ${#missing[@]} -eq 0 ]] || die "missing build tools: ${missing[*]} (brew install meson ninja cmake automake autoconf libtool pkg-config)"

mkdir -p "$WORK"
if [[ ! -x "$WORK/venv/bin/kiwix-build" ]] || ! grep -q "$KIWIX_BUILD_COMMIT" "$WORK/venv/.commit" 2>/dev/null; then
  # Whichever interpreter can make a venv with pip; brew's newest python3 has shipped without a working ensurepip.
  for py in python3.13 python3.12 python3.11 python3; do
    rm -rf "$WORK/venv"
    command -v "$py" >/dev/null && "$py" -m venv "$WORK/venv" 2>/dev/null && [[ -x "$WORK/venv/bin/pip" ]] && break
  done
  [[ -x "$WORK/venv/bin/pip" ]] || die "no python3 (3.11 to 3.13) could create a venv with pip"
  "$WORK/venv/bin/pip" install -q "git+${KIWIX_BUILD_REPO}@${KIWIX_BUILD_COMMIT}"
  echo "$KIWIX_BUILD_COMMIT" > "$WORK/venv/.commit"
fi
(cd "$WORK" && "$WORK/venv/bin/kiwix-build" --config macos_arm64_static kiwix-tools)

BUILT="$WORK/BUILD_macos_arm64_static/INSTALL/bin/kiwix-serve"
[[ -x "$BUILT" ]] || die "kiwix-build finished but $BUILT is missing"
[[ "$(lipo -archs "$BUILT")" == "arm64" ]] || die "built kiwix-serve is not arm64"
[[ "$("$BUILT" --version | head -1)" == "kiwix-tools $KIWIX_TOOLS_VERSION" ]] || die "built kiwix-serve reports $("$BUILT" --version | head -1), expected kiwix-tools $KIWIX_TOOLS_VERSION"
if otool -L "$BUILT" | grep -vE '^\S|/System/Library/|/usr/lib/' | grep -q .; then die "built kiwix-serve links non-system libraries:"$'\n'"$(otool -L "$BUILT")"; fi
mkdir -p "$(dirname "$DEST")"
cp "$BUILT" "$DEST" && chmod +x "$DEST"
echo "kiwix-serve (arm64, kiwix-tools $KIWIX_TOOLS_VERSION, kiwix-build $KIWIX_BUILD_COMMIT) -> $DEST"
