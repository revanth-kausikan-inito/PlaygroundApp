#!/usr/bin/env bash
# Runs every distinct-QR image N times on every connected iPhone in parallel (folder mode: one tap
# in the app, no photo picker) and merges the results.
#
#   scripts/run_batch.sh [-d] [-k] [-n COUNT] [-r REPEATS] [-s SOURCE_DIR] [-o OUT_DIR] [UDID ...]
#
# At the end, each phone is cleaned (test photos, app files, runner app) unless -k is given.
# -d is a dry run: picks the images and prints the plan, but builds nothing and touches no phone.
# COUNT limits the images (0 = every distinct QR). With no UDIDs, every paired iPhone that is
# connected by USB cable is used (Wi-Fi phones are ignored: the image copy is slow and drops).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT=0; REPEATS=10; DRY=0; KEEP=0
SOURCE="/Users/amitmitra/Repositories/SQPT/AAAE validation images"
OUT="$ROOT/batch-results/$(date +%Y%m%d-%H%M%S)"
BUNDLE=com.Inito.PlaygroundApp
MAX_ATTEMPTS=3

while getopts "dkn:r:s:o:" opt; do
  case $opt in
    d) DRY=1;; k) KEEP=1;;
    n) COUNT=$OPTARG;; r) REPEATS=$OPTARG;; s) SOURCE=$OPTARG;; o) OUT=$OPTARG;;
    *) exit 2;;
  esac
done
shift $((OPTIND-1))

mkdir -p "$OUT"
date +%s >"$OUT/started.txt"
DD="$OUT/derived"; STAGE="$OUT/input"; mkdir -p "$STAGE"

# --- devices
xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1
if [ $# -gt 0 ]; then
  UDIDS=("$@")
else
  UDIDS=($(python3 - "$OUT/devices.json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("deviceType") == "iPhone" and cp.get("pairingState") == "paired" \
       and cp.get("transportType") == "wired" and d.get("deviceProperties", {}).get("developerModeStatus") != "disabled":
        print(hw["udid"])
PY
))
fi
[ ${#UDIDS[@]} -gt 0 ] || { echo "No reachable iPhones."; exit 1; }
echo "Devices: ${UDIDS[*]}"

# --- one image per distinct QR, backup folders skipped
python3 "$ROOT/scripts/select_images.py" "$SOURCE" "$STAGE" "$OUT" "$COUNT" || exit 1
EXPECTED=$(( $(ls "$STAGE" | wc -l | tr -d ' ') * REPEATS ))

if [ $DRY -eq 1 ]; then
  python3 - "$OUT" "$STAGE" "$REPEATS" "${UDIDS[@]}" <<'PY'
import csv, json, os, sys
out, stage, repeats, udids = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
names = {d["hardwareProperties"]["udid"]: d for d in json.load(open(os.path.join(out, "devices.json")))["result"]["devices"]}
files = sorted(os.listdir(stage))
size = sum(os.path.getsize(os.path.join(stage, f)) for f in files)
sel = list(csv.DictReader(open(os.path.join(out, "selection.csv"))))
count = lambda d: sum(1 for r in sel if r["decision"] == d)
print("\nDRY RUN - nothing built, installed or copied\n")
print(f"Images considered (backup folders skipped): {len(sel)}")
print(f"  kept (distinct QR): {count('kept') + count('not staged')}   skipped (same QR as another image): {count('skipped')}")
print(f"  staged for this run: {len(files)}  ({size / 1e6:.0f} MB per phone)")
print(f"Repeats per image: {repeats}   Runs per phone: {len(files) * repeats}   Distinct strip codes: {len({r['strip_code'] for r in sel if r['decision'] != 'skipped'})}")
print("Phones:")
for u in udids:
    d = names.get(u)
    if not d:
        print(f"  {u}  NOT FOUND in devicectl"); continue
    p, c = d["deviceProperties"], d["connectionProperties"]
    print(f"  {d['hardwareProperties'].get('marketingName')} ({p.get('name')})  iOS {p.get('osVersionNumber')}  {c.get('transportType')}  {u}")
print(f"Output folder: {out}")
print("Steps per phone: uninstall app, install, copy images, run folder test (retry/resume up to 3x), pull results; then merge.")
PY
  exit 0
fi

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
    local t0=$(date +%s)
    xcrun devicectl device uninstall app --device "$udid" $BUNDLE || true
    xcrun devicectl device install app --device "$udid" "$APP"
    local t1=$(date +%s)
    xcrun devicectl device copy to --device "$udid" --source "$STAGE" \
      --destination Documents/BatchInput --domain-type appDataContainer --domain-identifier $BUNDLE
    local t2=$(date +%s)

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
    local t3=$(date +%s)
    echo "wall_seconds=$(( t3 - started ))" >"$dir/wall.txt"
    echo "runs=$rows expected=$EXPECTED" >>"$dir/wall.txt"
    echo "install_s=$(( t1 - t0 )) copy_s=$(( t2 - t1 )) test_and_pull_s=$(( t3 - started )) total_s=$(( t3 - t0 ))" >>"$dir/wall.txt"
  } >"$dir/run.log" 2>&1
  echo "finished $udid: $(sed -n 2,3p "$dir/wall.txt" | tr '\n' ' ') (log: $dir/run.log)"
}

pids=()
for udid in "${UDIDS[@]}"; do run_device "$udid" & pids+=($!); done
for pid in "${pids[@]}"; do wait "$pid" || true; done

python3 "$ROOT/scripts/merge_results.py" "$OUT" "$STAGE"

# Clean only the phones whose results are complete and safely pulled; an incomplete phone keeps its
# data so the run can be resumed.
if [ $KEEP -eq 0 ]; then
  DONE=()
  for udid in "${UDIDS[@]}"; do
    rows=$(grep -o "runs=[0-9]*" "$OUT/$udid/wall.txt" 2>/dev/null | head -1 | cut -d= -f2)
    if [ "${rows:-0}" -ge "$EXPECTED" ]; then DONE+=("$udid"); else echo "NOT cleaning $udid: run incomplete (${rows:-0}/$EXPECTED)"; fi
  done
  [ ${#DONE[@]} -gt 0 ] && "$ROOT/scripts/cleanup_device.sh" -p "$DD" "${DONE[@]}"
fi
echo "Report: $OUT/report.csv  Summary: $OUT/summary.csv  Cross-device: $OUT/cross_device.csv  Selection: $OUT/selection.csv"
