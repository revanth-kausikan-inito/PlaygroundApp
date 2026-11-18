#!/usr/bin/env bash
# Puts phones back as they were before testing: deletes the test images the app added to Photos,
# the app's batch files, and the UI-test runner app.
#
#   scripts/cleanup_device.sh [-p DERIVED_DATA] UDID [UDID ...]
#
# Photos go to Recently Deleted (iOS has no way to skip it); empty it on the phone, or it clears after 30 days.
# The Playground App itself stays installed; remove it with `xcrun devicectl device uninstall app`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD=""
while getopts "p:" opt; do case $opt in p) DD=$OPTARG;; *) exit 2;; esac; done
shift $((OPTIND-1))
[ $# -gt 0 ] || { echo "usage: $0 [-p DERIVED_DATA] UDID [UDID ...]"; exit 2; }

if [ -z "$DD" ]; then
  DD="$(mktemp -d)/derived"
  xcodebuild -project "$ROOT/PlaygroundApp.xcodeproj" -scheme PlaygroundApp -destination generic/platform=iOS \
    -derivedDataPath "$DD" -allowProvisioningUpdates build-for-testing >"$DD.build.log" 2>&1 || { tail -20 "$DD.build.log"; exit 1; }
fi

clean() {
  local udid=$1 log="$DD.cleanup.$1.log"
  xcodebuild -project "$ROOT/PlaygroundApp.xcodeproj" -scheme PlaygroundApp -destination "id=$udid" \
    -derivedDataPath "$DD" -resultBundlePath "$DD.cleanup.$udid.xcresult" \
    -only-testing:PlaygroundAppUITests/BatchUITests/test9_Cleanup \
    -allowProvisioningUpdates test-without-building >"$log" 2>&1
  local result=$?
  local status; status=$(xcrun xcresulttool export attachments --path "$DD.cleanup.$udid.xcresult" --output-path "$DD.att.$udid" >/dev/null 2>&1; grep -rh "cleanup:" "$DD.att.$udid" 2>/dev/null | head -1)
  xcrun devicectl device uninstall app --device "$udid" com.Inito.PlaygroundAppUITests.xctrunner >/dev/null 2>&1
  echo "$udid: ${status:-no status} (test exit $result, log $log)"
}
pids=(); for u in "$@"; do clean "$u" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || true; done
