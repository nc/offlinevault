#!/usr/bin/env bash
# Builds, signs, packages and publishes one OfflineVault release.
#
#   scripts/release.sh [--version X.Y.Z] [--build N] [--skip-upload] [--skip-gate]
#
# Output lands in build/release/: the Release archive, the signed app, the DMG, appcast.xml and latest.json.
# Every step derives from what is on disk and in the Keychain, so rerunning converges on the same files.
#
# The eval gate (scripts/eval/gate.sh) must have passed on the code being released: a gate-<sha>.json with
# "passed": true in build/eval or scripts/eval/results/gates, for HEAD or for a commit that differs from HEAD only
# under scripts/eval/results, docs, or the content lock, reports and Field Guide sources (publishing moves HEAD
# without changing the app). --skip-gate releases without it.
#
# Signing picks the strongest identity the machine has:
#   - a "Developer ID Application" certificate plus a notarytool profile named "offlinevault"
#     -> Developer ID, timestamped, notarized and stapled (what the public should get);
#   - otherwise ad-hoc with hardened runtime, and a loud warning. Gatekeeper refuses an ad-hoc download until
#     the user allows it in System Settings > Privacy & Security > Open Anyway (or removes com.apple.quarantine).
#     README > Releasing has the prerequisites.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORIGIN="https://offlinevault.dev"
FEED_PREFIX="$ORIGIN/updates/app/"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/OfflineVault.xcarchive"
APP="$OUT/OfflineVault.app"
FEED_DIR="$OUT/appcast"
PYTHON="$ROOT/scripts/content/.venv/bin/python"
SECRET_FILE="$HOME/.offlinevault-keys/upload-secret"
HELPERS=(ffmpeg kiwix-serve llama/llama-server pmtiles yt-dlp)

setting() { sed -nE "s/^ *$1: *\"?([^\"]*)\"?\$/\1/p" "$ROOT/project.yml" | head -1; }
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
SKIP_UPLOAD=0
SKIP_GATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2;;
    --build) BUILD="$2"; shift 2;;
    --skip-upload) SKIP_UPLOAD=1; shift;;
    --skip-gate) SKIP_GATE=1; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "--version must look like 1.0.0 (got '$VERSION')" >&2; exit 2; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "--build must be an integer (got '$BUILD')" >&2; exit 2; }
DMG_NAME="OfflineVault-$VERSION.dmg"
DMG="$FEED_DIR/$DMG_NAME"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\n\033[1;33m%s\033[0m\n' "$*"; }

# --- Preflight -----------------------------------------------------------------------------------------------------
log "Preflight ($VERSION build $BUILD)"
command -v xcodegen >/dev/null || die "xcodegen not installed (brew install xcodegen)"
SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
# The newest gate file whose commit is HEAD, or differs from HEAD only under eval results and docs.
gate_file() {
  local f sha
  for f in $(ls -t "$ROOT"/build/eval/gate-*.json "$ROOT"/scripts/eval/results/gates/gate-*.json 2>/dev/null | grep -v -- '-retrieval.json$'); do
    sha="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("commit", ""))' "$f")"
    [[ -n "$sha" ]] && git -C "$ROOT" cat-file -e "$sha^{commit}" 2>/dev/null || continue
    # Publishing content moves the lock and the report but not the app, so those may differ too.
    if git -C "$ROOT" diff --quiet "$sha" HEAD -- . ':(exclude)scripts/eval/results' ':(exclude)docs' ':(exclude)scripts/content/catalogue.lock.json' ':(exclude)scripts/content/reports' ':(exclude)scripts/content/fieldguide' ':(exclude)scripts/release.sh' ':(exclude)scripts/upload_release.py' 2>/dev/null; then echo "$f"; return; fi
  done
}
if [[ $SKIP_GATE == 1 ]]; then
  warn "Eval gate skipped (--skip-gate): this release was not checked against scripts/eval/gate.yaml on $SHA."
else
  GATE_FILE="$(gate_file)"
  if [[ -z "$GATE_FILE" ]]; then
    die "no eval gate result for the code at $SHA (looked for build/eval/gate-*.json and scripts/eval/results/gates/gate-*.json from a commit with the same code). Run scripts/eval/gate.sh on this commit (retrieval harness plus the safety-critical questions through the app), or pass --skip-gate."
  elif ! python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("passed") else 1)' "$GATE_FILE"; then
    python3 -c 'import json, sys; [print("  " + f) for f in json.load(open(sys.argv[1]))["failures"]]' "$GATE_FILE"
    die "the eval gate failed for the code at $SHA (reasons above, from $GATE_FILE). Fix them and rerun scripts/eval/gate.sh, or pass --skip-gate."
  else
    echo "eval gate: passed ($GATE_FILE)"
  fi
fi
for h in "${HELPERS[@]}"; do
  [[ -x "$ROOT/OfflineVault/Resources/bin/$h" ]] || die "helper missing: OfflineVault/Resources/bin/$h (scripts/fetch_binaries.sh --allow-rosetta, scripts/fetch_web_assets.sh)"
done
SPARKLE_BIN="$(dirname "$(find "$ROOT/build/DerivedData/SourcePackages/artifacts" -type f -path '*/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)")"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || die "Sparkle tools not found under build/DerivedData; build the app once (see README > Quick start)"
PUBLIC_KEY="$(setting SUPublicEDKey)"
[[ -n "$PUBLIC_KEY" ]] || die "project.yml has no SUPublicEDKey; run scripts/sparkle_keys.sh and paste the key"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
[[ "$KEYCHAIN_KEY" == "$PUBLIC_KEY" ]] || die "the Sparkle private key in this login Keychain ($KEYCHAIN_KEY) does not match project.yml's SUPublicEDKey ($PUBLIC_KEY); releases must be signed by the key the app trusts"
if [[ $SKIP_UPLOAD == 0 ]]; then
  [[ -x "$PYTHON" ]] || die "no publisher venv at scripts/content/.venv (see README > Publishing real content)"
  [[ -r "$SECRET_FILE" ]] || die "no upload secret at $SECRET_FILE"
fi

SIGN_ID="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]*)".*/\1/p' | head -1)"
NOTARIZE=0
if [[ -n "$SIGN_ID" ]]; then
  if xcrun notarytool history --keychain-profile offlinevault >/dev/null 2>&1; then NOTARIZE=1
  else warn "Developer ID found but no notarytool profile 'offlinevault': signing with Developer ID, NOT notarizing. Run: xcrun notarytool store-credentials offlinevault"; fi
  TIMESTAMP=(--timestamp)
else
  SIGN_ID="-"
  TIMESTAMP=()
  warn "WARNING: no 'Developer ID Application' certificate in the keychain. This release is AD-HOC signed.
         Gatekeeper will refuse it on other Macs until the user clicks Open Anyway in System Settings > Privacy & Security.
         Join the Apple Developer Program, install the certificate, store a notarytool profile named
         'offlinevault', and rerun this script unchanged for a notarized build."
fi
echo "identity: $SIGN_ID   notarize: $NOTARIZE   upload: $(( 1 - SKIP_UPLOAD ))"

# --- Build ---------------------------------------------------------------------------------------------------------
log "xcodegen generate"
(cd "$ROOT" && xcodegen generate --quiet)

log "xcodebuild archive (Release)"
mkdir -p "$OUT"
rm -rf "$ARCHIVE"
if ! xcodebuild -project "$ROOT/OfflineVault.xcodeproj" -scheme OfflineVault -configuration Release \
    -derivedDataPath "$ROOT/build/DerivedData" -archivePath "$ARCHIVE" archive \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    > "$OUT/xcodebuild.log" 2>&1; then
  tail -40 "$OUT/xcodebuild.log"; die "archive failed (full log: $OUT/xcodebuild.log)"
fi
rm -rf "$APP"
ditto "$ARCHIVE/Products/Applications/OfflineVault.app" "$APP"

# --- Sign inside-out -----------------------------------------------------------------------------------------------
# Xcode signs the app and Sparkle but leaves Resources/bin untouched, and notarization wants every Mach-O signed
# with hardened runtime, so everything is re-signed here from the leaves up: helper dylibs, helper executables,
# Sparkle's nested pieces, the framework, then the app, which seals the lot.
log "codesign ($SIGN_ID)"
sign() { # [--entitlements file] path
  local out
  out="$(codesign --force --sign "$SIGN_ID" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} "$@" 2>&1)" || { echo "$out" >&2; die "codesign failed: ${*: -1}"; }
}
# An ad-hoc signature has no team ID, and library validation admits only same-team or Apple code, so an ad-hoc
# process is refused every dylib or framework we ship with it: the app loses Sparkle.framework, llama-server its
# libllama/libggml dylibs (dyld: "mapping process and mapped file (non-platform) have different Team IDs").
# Those two opt out of library validation only in the ad-hoc fallback. A Developer ID build keeps it on.
# yt-dlp opts out under every identity: it dlopens a Python framework signed by the yt-dlp project.
APP_ENT="$ROOT/OfflineVault/OfflineVault.entitlements"
LLAMA_ENT=()
if [[ "$SIGN_ID" == "-" ]]; then
  cp "$APP_ENT" "$OUT/adhoc-app.entitlements"; APP_ENT="$OUT/adhoc-app.entitlements"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$OUT/adhoc-llama-server.entitlements"
  for f in "$APP_ENT" "$OUT/adhoc-llama-server.entitlements"; do plutil -replace 'com\.apple\.security\.cs\.disable-library-validation' -bool true "$f"; done
  LLAMA_ENT=(--entitlements "$OUT/adhoc-llama-server.entitlements")
fi
BIN="$APP/Contents/Resources/bin"
while IFS= read -r -d '' f; do
  file -b "$f" | grep 'Mach-O' >/dev/null || continue
  case "$(basename "$f")" in
    llama-server) sign ${LLAMA_ENT[@]+"${LLAMA_ENT[@]}"} "$f";;
    yt-dlp) sign --entitlements "$ROOT/scripts/entitlements/yt-dlp.plist" "$f";;
    *) sign "$f";;
  esac
done < <(find "$BIN" -type f \( -name '*.dylib' -o -perm +111 \) -print0 | sort -z)

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$APP_ENT" "$APP"

# --- Verify the app ------------------------------------------------------------------------------------------------
log "verify"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2 || true
codesign --verify --deep --strict "$APP" || die "codesign --verify --deep --strict failed"
for h in "${HELPERS[@]}"; do
  codesign -d -vv "$BIN/$h" 2>&1 | grep 'flags=.*runtime' >/dev/null || die "$h is not signed with hardened runtime"
done
# Gatekeeper accepts a Developer ID build only once it is notarized, so the decisive check runs after stapling below.
if spctl --assess --type execute -vv "$APP" 2>&1; then echo "spctl: accepted"
elif [[ "$SIGN_ID" == "-" ]]; then echo "spctl: rejected, expected for an ad-hoc signature (Gatekeeper needs Developer ID + notarization)"
elif [[ $NOTARIZE == 1 ]]; then echo "spctl: rejected before notarization, expected; re-checked after stapling"
else warn "spctl rejected this Developer ID build; without notarization Gatekeeper will refuse it on other Macs"; fi

PLIST="$APP/Contents/Info.plist"
[[ "$(plutil -extract SUFeedURL raw "$PLIST")" == "${FEED_PREFIX}appcast.xml" ]] || die "Info.plist SUFeedURL is not the live feed"
[[ "$(plutil -extract SUPublicEDKey raw "$PLIST")" == "$PUBLIC_KEY" ]] || die "Info.plist SUPublicEDKey mismatch"
[[ "$(plutil -extract CFBundleShortVersionString raw "$PLIST")" == "$VERSION" ]] || die "Info.plist version is not $VERSION"
[[ "$(plutil -extract CFBundleVersion raw "$PLIST")" == "$BUILD" ]] || die "Info.plist build is not $BUILD"
# Release builds must not trust the committed development key (Config.swift, #if DEBUG) or ship the placeholder feed.
if strings "$APP/Contents/MacOS/OfflineVault" | grep -E 'ORUshk9UHuNd8mebEbfEGTqbigEVYCaByVR8yyB8/TU=|offlinevault\.example' >/dev/null; then
  die "release binary contains the dev signing key or the placeholder feed URL"
fi
echo "binary: no dev key, no placeholder feed"

log "helpers launch from inside the signed bundle"
run_helper() { # path args...
  local exe="$1"; shift
  if lipo -archs "$exe" | grep -qw arm64; then "$exe" "$@"; else arch -x86_64 "$exe" "$@"; fi
}
smoke() { # helper args...
  local out
  out="$(run_helper "$BIN/$1" "${@:2}" 2>&1)" || die "$1 failed to launch under hardened runtime: $out"
  printf '  %-18s %s\n' "$1" "$(printf '%s\n' "$out" | grep -m1 .)"
}
smoke ffmpeg -version
smoke kiwix-serve --version
smoke llama/llama-server --version
smoke pmtiles version
smoke yt-dlp --version

# --- Notarize the app ----------------------------------------------------------------------------------------------
notarize() { # path
  log "notarize $(basename "$1")"
  local zip="$OUT/notarize-$(basename "$1").zip"
  if [[ "$1" == *.dmg ]]; then xcrun notarytool submit "$1" --keychain-profile offlinevault --wait | tee "$OUT/notarize-$(basename "$1").log"
  else ditto -c -k --keepParent "$1" "$zip"; xcrun notarytool submit "$zip" --keychain-profile offlinevault --wait | tee "$OUT/notarize-$(basename "$1").log"; rm -f "$zip"; fi
  grep -q 'status: Accepted' "$OUT/notarize-$(basename "$1").log" || die "notarization of $(basename "$1") was not accepted; xcrun notarytool log <id> --keychain-profile offlinevault"
  xcrun stapler staple "$1"
}
if [[ $NOTARIZE == 1 ]]; then
  notarize "$APP"
  spctl --assess --type execute -vv "$APP" 2>&1 | tail -2
  spctl --assess --type execute "$APP" || die "spctl rejected the notarized, stapled app"
fi

# --- DMG -----------------------------------------------------------------------------------------------------------
log "hdiutil $DMG_NAME"
STAGE="$OUT/dmg-root"
rm -rf "$STAGE" "$FEED_DIR"; mkdir -p "$STAGE" "$FEED_DIR"
ditto "$APP" "$STAGE/OfflineVault.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname OfflineVault -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"
if [[ "$SIGN_ID" != "-" ]]; then codesign --sign "$SIGN_ID" --timestamp "$DMG"; fi
if [[ $NOTARIZE == 1 ]]; then
  notarize "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG" || die "spctl rejected the notarized, stapled DMG"
fi
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(stat -f%z "$DMG")"
echo "$DMG_NAME  $SIZE bytes  sha256=$SHA"

# --- Appcast and latest.json ---------------------------------------------------------------------------------------
log "generate_appcast"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$FEED_PREFIX" --link "$ORIGIN/" "$FEED_DIR" 2>&1 | grep -v '^$' || true
grep -q "url=\"${FEED_PREFIX}${DMG_NAME}\"" "$FEED_DIR/appcast.xml" || die "appcast.xml does not point at $FEED_PREFIX$DMG_NAME"
grep -q 'sparkle:edSignature=' "$FEED_DIR/appcast.xml" || die "appcast.xml carries no EdDSA signature"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$FEED_DIR/appcast.xml" || die "appcast.xml does not list build $BUILD"

python3 - "$FEED_DIR/latest.json" "$VERSION" "$BUILD" "$DMG_NAME" "$SHA" "$SIZE" "$([[ "$SIGN_ID" != "-" ]] && echo true || echo false)" "$([[ $NOTARIZE == 1 ]] && echo true || echo false)" <<'PY'
import json, sys, datetime
out, version, build, dmg, sha, size, signed, notarized = sys.argv[1:]
json.dump({"version": version, "build": build, "dmg": dmg, "sha256": sha, "sizeBytes": int(size),
           "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "minimumSystemVersion": "14.0", "signed": signed == "true", "notarized": notarized == "true"},
          open(out, "w"), indent=2)
PY
cat "$FEED_DIR/latest.json"

# --- Upload --------------------------------------------------------------------------------------------------------
if [[ $SKIP_UPLOAD == 1 ]]; then
  log "upload skipped (--skip-upload). Artefacts: $FEED_DIR"
else
  log "upload to $ORIGIN"
  "$PYTHON" "$ROOT/scripts/upload_release.py" "$DMG" "$FEED_DIR/appcast.xml" "$FEED_DIR/latest.json" --origin "$ORIGIN" --secret-file "$SECRET_FILE"
fi

log "done"
echo "app:      $APP"
echo "dmg:      $DMG ($SIZE bytes, sha256 $SHA)"
echo "feed:     ${FEED_PREFIX}appcast.xml"
echo "download: ${FEED_PREFIX}${DMG_NAME}   ($ORIGIN/download follows app/latest.json)"
[[ "$SIGN_ID" == "-" ]] && warn "Reminder: this build is ad-hoc signed and not notarized."
exit 0
