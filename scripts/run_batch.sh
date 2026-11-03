#!/usr/bin/env bash
# Runs the batch UI test on every available paired iPhone in parallel and merges the results.
#
#   scripts/run_batch.sh [-n COUNT] [-r REPEATS] [-s SOURCE_DIR] [-o OUT_DIR] [UDID ...]
#
# With no UDIDs, every paired, available iPhone is used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT=10; REPEATS=10
SOURCE="/Users/amitmitra/Repositories/SQPT/AAAE validation images"
OUT="$ROOT/batch-results/$(date +%Y%m%d-%H%M%S)"
BUNDLE=com.Inito.PlaygroundApp

while getopts "n:r:s:o:" opt; do
  case $opt in
    n) COUNT=$OPTARG;; r) REPEATS=$OPTARG;; s) SOURCE=$OPTARG;; o) OUT=$OPTARG;;
    *) exit 2;;
  esac
done
shift $((OPTIND-1))

mkdir -p "$OUT"
date +%s >"$OUT/started.txt"
DD="$OUT/derived"; STAGE="$OUT/input"; mkdir -p "$STAGE"

# --- devices
if [ $# -gt 0 ]; then
  UDIDS=("$@")
else
  xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1
  UDIDS=($(python3 - "$OUT/devices.json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("deviceType") == "iPhone" and cp.get("pairingState") == "paired" \
       and cp.get("tunnelState") in ("connected", "disconnected") and d.get("deviceProperties", {}).get("developerModeStatus") == "enabled":
        print(hw["udid"])
PY
))
fi
echo "Devices: ${UDIDS[*]}"

# --- stage COUNT images: first image of COUNT different concentration folders, deterministic.
python3 - "$SOURCE" "$STAGE" "$COUNT" <<'PY'
import os, shutil, sys
src, dst, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
picks = []
for run in sorted(os.listdir(src)):
    runp = os.path.join(src, run)
    if not os.path.isdir(runp): continue
    for conc in sorted(os.listdir(runp)):
        d = os.path.join(runp, conc)
        if conc.endswith("_originals_backup") or not os.path.isdir(d): continue
        files = sorted(f for f in os.listdir(d) if f.lower().endswith((".png", ".jpg", ".jpeg")))
        if files: picks.append((run, conc, os.path.join(d, files[0])))
for i, (run, conc, path) in enumerate(picks[:count]):
    name = f"{i:03d}__{run}__{conc}__{os.path.basename(path)}"
    shutil.copy(path, os.path.join(dst, name))
print(f"staged {min(count, len(picks))} images")
PY

# --- build once
xcodebuild -project "$ROOT/PlaygroundApp.xcodeproj" -scheme PlaygroundApp \
  -destination generic/platform=iOS -derivedDataPath "$DD" -allowProvisioningUpdates \
  build-for-testing >"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
APP="$(find "$DD/Build/Products" -maxdepth 2 -name PlaygroundApp.app | head -1)"

run_device() {
  local udid=$1 dir="$OUT/$1"; mkdir -p "$dir"
  {
    xcrun devicectl device install app --device "$udid" "$APP"
    xcrun devicectl device copy to --device "$udid" --source "$STAGE" \
      --destination Documents/BatchInput --domain-type appDataContainer --domain-identifier $BUNDLE
    local started=$(date +%s)
    # One retry: the phone sometimes times out enabling automation mode on the first attempt.
    for attempt in 1 2; do
      TEST_RUNNER_BATCH_COUNT=$COUNT TEST_RUNNER_BATCH_REPEATS=$REPEATS \
      xcodebuild -project "$ROOT/PlaygroundApp.xcodeproj" -scheme PlaygroundApp \
        -destination "id=$udid" -derivedDataPath "$DD" -resultBundlePath "$dir/result$attempt.xcresult" \
        -skip-testing:PlaygroundAppUITests/BatchUITests/test1b_DumpPicker \
        -allowProvisioningUpdates test-without-building > "$dir/xcodebuild$attempt.log" 2>&1 || true
      cat "$dir/xcodebuild$attempt.log"
      grep -q "Timed out while enabling automation mode" "$dir/xcodebuild$attempt.log" || break
      echo "attempt $attempt: automation mode timed out, retrying"; sleep 5
    done
    mv "$dir/result$attempt.xcresult" "$dir/result.xcresult"
    echo "wall_seconds=$(( $(date +%s) - started ))" >"$dir/wall.txt"
    xcrun devicectl device copy from --device "$udid" --source Documents/QRCaptures \
      --destination "$dir/QRCaptures" --domain-type appDataContainer --domain-identifier $BUNDLE
    xcrun xcresulttool export attachments --path "$dir/result.xcresult" --output-path "$dir/attachments" || true
  } >"$dir/run.log" 2>&1
  echo "finished $udid (log: $dir/run.log)"
}

pids=()
for udid in "${UDIDS[@]}"; do run_device "$udid" & pids+=($!); done
for pid in "${pids[@]}"; do wait "$pid" || true; done

python3 "$ROOT/scripts/merge_results.py" "$OUT" "$STAGE"
echo "Report: $OUT/report.csv  Summary: $OUT/summary.csv  Cross-device: $OUT/cross_device.csv"
