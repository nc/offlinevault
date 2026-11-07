#!/bin/sh
# The release gate: retrieval harness, then the safety-critical subset through the app with the default model.
#
#   scripts/eval/gate.sh            writes build/eval/gate-<git short sha>.json and exits 1 when the gate fails
#
# scripts/eval/gate.yaml lists the subset and the thresholds; scripts/eval/gate.py judges the two runs. The app run
# needs the Debug build (OFFLINEVAULT_APP) and LibraryDev with the Field Guide, the cited books and the default model,
# as scripts/eval/run_app_eval.sh documents. Rerunning the same day resumes the app run's answers file.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PY=$ROOT/scripts/content/.venv/bin/python
WORK=${OFFLINEVAULT_EVAL_WORK:-$ROOT/build/eval}
MODEL_FILE=${GATE_MODEL_FILE:-Qwen3-4B-Instruct-2507-Q4_K_M.gguf}
MODEL_LABEL=${GATE_MODEL_LABEL:-qwen3-4b-q4_k_m}
SHA=$(git -C "$ROOT" rev-parse --short HEAD)
RETRIEVAL=$WORK/gate-$SHA-retrieval.json
RUN_ID=gate-$SHA-$MODEL_LABEL
mkdir -p "$WORK"

echo "== retrieval harness ($SHA)"
(cd "$ROOT/Core" && swift build --product retrievaltool 2>&1 | tail -1)
BIN=$(cd "$ROOT/Core" && swift build --show-bin-path)
OFFLINEVAULT_BIN_DIR=$ROOT/OfflineVault/Resources/bin "$BIN/retrievaltool" --library "${OFFLINEVAULT_LIBRARY:-$ROOT/LibraryDev}" \
  --questions "$ROOT/scripts/eval/questions.yaml" --python "$PY" --out "$RETRIEVAL" | tail -6

echo "== app run: $MODEL_FILE over the gate subset"
EVAL_OUT=$WORK RUN_ID=$RUN_ID "$ROOT/scripts/eval/run_app_eval.sh" "$MODEL_FILE" "$MODEL_LABEL" --ids "$("$PY" "$ROOT/scripts/eval/gate.py" ids)"

echo "== verdict"
"$PY" "$ROOT/scripts/eval/gate.py" check --retrieval "$RETRIEVAL" --app "$WORK/$RUN_ID.json" --commit "$SHA" --out "$WORK/gate-$SHA.json"
