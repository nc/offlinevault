#!/bin/sh
# Runs the accuracy eval through the built Debug app against the dev library, one model per invocation:
#
#   scripts/eval/run_app_eval.sh <model-file.gguf> <model-label> [--ids a,b | --section s | --limit n]
#   scripts/eval/run_app_eval.sh Qwen3-4B-Instruct-2507-Q4_K_M.gguf qwen3-4b-q4_k_m
#
# Exports the questions, launches the app in batch mode (OFFLINEVAULT_ASK_FILE / OFFLINEVAULT_ASK_OUT, see
# OfflineVault/ScreenshotMode.swift), relaunches it until every question has an answer (the app rewrites the answers
# file after each one, so a crash loses nothing), then scores the answers into results/<date>-<label>.{json,md}.
# Rerunning the same day with the same label resumes. Env: OFFLINEVAULT_APP, OFFLINEVAULT_LIBRARY (default
# LibraryDev), OFFLINEVAULT_EVAL_WORK (default build/eval), RUN_ID, EVAL_OUT (where the scored results go, default
# scripts/eval/results).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MODEL_FILE=$1
LABEL=$2
shift 2
PY=$ROOT/scripts/content/.venv/bin/python
EVAL=$ROOT/scripts/eval/run_eval.py
APP=${OFFLINEVAULT_APP:-$ROOT/build/DerivedData/Build/Products/Debug/OfflineVault.app/Contents/MacOS/OfflineVault}
LIBRARY=${OFFLINEVAULT_LIBRARY:-$ROOT/LibraryDev}
WORK=${OFFLINEVAULT_EVAL_WORK:-$ROOT/build/eval}
RUN_ID=${RUN_ID:-$(date -u +%Y-%m-%d)-$LABEL}
QUESTIONS=$WORK/$RUN_ID-questions.json
ANSWERS=$WORK/$RUN_ID-answers.json
LOG=$WORK/$RUN_ID-app.log

[ -f "$LIBRARY/models/$MODEL_FILE" ] || { echo "no such model in $LIBRARY/models: $MODEL_FILE" >&2; exit 1; }
[ -x "$APP" ] || { echo "build the Debug app first: $APP" >&2; exit 1; }
mkdir -p "$WORK"
"$PY" "$EVAL" export --out "$QUESTIONS" "$@"
wanted=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$QUESTIONS")
# Answers that failed with a provider error are asked again by the next launch, so they do not count.
answered() { [ -f "$ANSWERS" ] && "$PY" -c 'import json,sys; print(sum(1 for a in json.load(open(sys.argv[1])) if not a.get("error")))' "$ANSWERS" || echo 0; }

attempt=0
while [ "$(answered)" -lt "$wanted" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -le 5 ] || { echo "gave up after 5 launches with $(answered)/$wanted answered; scoring what there is (errors count as wrong), see $LOG" >&2; break; }
  if pgrep -f "OfflineVault.app/Contents/MacOS/OfflineVault" >/dev/null; then echo "OfflineVault is already running; quit it first" >&2; exit 1; fi
  echo "launch $attempt: $(answered)/$wanted answered, model $MODEL_FILE"
  OFFLINEVAULT_ASK_FILE=$QUESTIONS OFFLINEVAULT_ASK_OUT=$ANSWERS \
    "$APP" -libraryPath "$LIBRARY" -selectedModelFile "$MODEL_FILE" -useFixtureServer NO >>"$LOG" 2>&1 &
  app=$!
  # The app is meant to quit after the last answer; when it lingers (seen twice), it is killed 120 s after the
  # answers file is complete, and if no answer lands for 30 minutes the launch is abandoned and retried.
  done_at=""; last_count=$(answered); last_change=$(date +%s)
  while kill -0 "$app" 2>/dev/null; do
    sleep 10
    n=$(answered)
    if [ "$n" -ne "$last_count" ]; then last_count=$n; last_change=$(date +%s); fi
    if [ "$n" -ge "$wanted" ]; then
      [ -n "$done_at" ] || done_at=$(date +%s)
      [ $(( $(date +%s) - done_at )) -lt 120 ] || { echo "app lingered after the last answer; stopping it" >&2; kill "$app" 2>/dev/null; sleep 5; kill -9 "$app" 2>/dev/null; }
    elif [ $(( $(date +%s) - last_change )) -gt 1800 ]; then
      echo "no answer for 30 minutes; stopping the app for a relaunch" >&2; kill "$app" 2>/dev/null; sleep 5; kill -9 "$app" 2>/dev/null
    fi
  done
  wait "$app" 2>/dev/null || true
done
echo "$(answered)/$wanted answered"
"$PY" "$EVAL" run --provider file --answers "$ANSWERS" --models "$LABEL" --run-id "$RUN_ID" --out "${EVAL_OUT:-$ROOT/scripts/eval/results}" "$@"
