#!/usr/bin/env bash
# Generates the Sparkle EdDSA signing key pair (private key in your login Keychain) and prints the public key to
# paste into project.yml → SUPublicEDKey. Needs the project built once so SwiftPM has fetched Sparkle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$(find "$ROOT/build/DerivedData/SourcePackages/artifacts" -type f -name generate_keys 2>/dev/null | head -1)"
[[ -n "$GEN" ]] || { echo "Sparkle tools not found; build the app once (xcodebuild … build) then re-run."; exit 1; }
"$GEN"
echo "Then publish releases with: $(dirname "$GEN")/generate_appcast <folder of signed .zip/.dmg> → upload appcast.xml next to manifest.json"
