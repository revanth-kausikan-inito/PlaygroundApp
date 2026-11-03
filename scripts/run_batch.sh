#!/usr/bin/env bash
# Runs every distinct-QR image N times on every connected iPhone in parallel (folder mode: one tap
# in the app, no photo picker) and merges the results.
#
#   scripts/run_batch.sh [-n COUNT] [-r REPEATS] [-s SOURCE_DIR] [-o OUT_DIR] [UDID ...]
#
# COUNT limits the images (0 = every distinct QR). With no UDIDs, every paired iPhone that is
# reachable (USB, or an active tunnel) is used.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT=0; REPEATS=10
SOURCE="/Users/amitmitra/Repositories/SQPT/AAAE validation images"
OUT="$ROOT/batch-results/$(date +%Y%m%d-%H%M%S)"
BUNDLE=com.Inito.PlaygroundApp
MAX_ATTEMPTS=3

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
       and (cp.get("tunnelState") == "connected" or cp.get("transportType") == "wired") and d.get("deviceProperties", {}).get("developerModeStatus") == "enabled":
        print(hw["udid"])
PY
))
fi
[ ${#UDIDS[@]} -gt 0 ] || { echo "No reachable iPhones."; exit 1; }
echo "Devices: ${UDIDS[*]}"

# --- one image per distinct QR, backup folders skipped
python3 "$ROOT/scripts/select_images.py" "$SOURCE" "$STAGE" "$OUT" "$COUNT" || exit 1
EXPECTED=$(( $(ls "$STAGE" | wc -l | tr -d ' ') * REPEATS ))

# --- build once
xcodebuild -project "$ROOT/PlaygroundApp.xcodeproj" -scheme PlaygroundApp \
  -destination generic/platform=iOS -derivedDataPath "$DD" -allowProvisioningUpdates \
  build-for-testing >"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
APP="$(find "$DD/Build/Products" -maxdepth 2 -name PlaygroundApp.app | head -1)"

pull_results() {
  local udid=$1 dir=$2
  rm -rf "$dir/BatchOutput"
  xcrun devicectl device copy from --device "$udid" --source Documents/BatchOutput \
    --destination "$dir/BatchOutput" --domain-type appDataContainer --domain-identifier $BUNDLE >>"$dir/run.log" 2>&1
  [ -f "$dir/BatchOutput/results.jsonl" ] && wc -l <"$dir/BatchOutput/results.jsonl" | tr -d ' ' || echo 0
}

run_device() {
  local udid=$1 dir="$OUT/$1"; mkdir -p "$dir"
  {
    # Uninstalling first wipes the app container, so images and results from an earlier run
    # can never be mixed into this one.
    xcrun devicectl device uninstall app --device "$udid" $BUNDLE || true
    xcrun devicectl device install app --device "$udid" "$APP"
    xcrun devicectl device copy to --device "$udid" --source "$STAGE" \
      --destination Documents/BatchInput --domain-type appDataContainer --domain-identifier $BUNDLE

    local started=$(date +%s) fresh=1 rows=0
    for attempt in $(seq 1 $MAX_ATTEMPTS); do
      TEST_RUNNER_BATCH_REPEATS=$REPEATS TEST_RUNNER_BATCH_FRESH=$fresh \
      xcodebuild -project "$ROOT/PlaygroundApp.xcodeproj" -scheme PlaygroundApp \
        -destination "id=$udid" -derivedDataPath "$DD" -resultBundlePath "$dir/result$attempt.xcresult" \
        -only-testing:PlaygroundAppUITests/BatchUITests/test3_RunFolder \
        -allowProvisioningUpdates test-without-building >"$dir/xcodebuild$attempt.log" 2>&1 || true
      rows=$(pull_results "$udid" "$dir")
      echo "attempt $attempt: $rows of $EXPECTED runs on the device"
      [ "$rows" -ge "$EXPECTED" ] && break
      fresh=0   # later attempts resume where the last one stopped
      sleep 5
    done
    echo "wall_seconds=$(( $(date +%s) - started ))" >"$dir/wall.txt"
    echo "runs=$rows expected=$EXPECTED" >>"$dir/wall.txt"
  } >"$dir/run.log" 2>&1
  echo "finished $udid: $(tail -1 "$dir/wall.txt") (log: $dir/run.log)"
}

pids=()
for udid in "${UDIDS[@]}"; do run_device "$udid" & pids+=($!); done
for pid in "${pids[@]}"; do wait "$pid" || true; done

python3 "$ROOT/scripts/merge_results.py" "$OUT" "$STAGE"
echo "Report: $OUT/report.csv  Summary: $OUT/summary.csv  Cross-device: $OUT/cross_device.csv  Selection: $OUT/selection.csv"
