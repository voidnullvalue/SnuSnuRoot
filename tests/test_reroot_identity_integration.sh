#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
output="$(mktemp)"
trap 'rm -f "$output"' EXIT HUP INT TERM
if ADB="$repo_dir/tests/fixtures/mock_adb_identity.sh" \
        "$repo_dir/scripts/reroot_after_boot.sh" "$repo_dir/scripts/rootsvc_payload.sh" \
        >"$output" 2>&1; then
    echo "FAIL: mocked spent leak unexpectedly succeeded" >&2
    exit 1
else
    result=$?
fi
[ "$result" -eq 30 ] || { cat "$output"; echo "FAIL: expected stateful-spent exit 30, got $result" >&2; exit 1; }
grep -q '^== 3/7 stateful leak' "$output" \
    || { cat "$output"; echo "FAIL: valid observed identity did not reach stateful leak" >&2; exit 1; }
if grep -q 'carrier validation failed' "$output"; then
    cat "$output"
    echo "FAIL: valid observed identity failed validation" >&2
    exit 1
fi
echo "PASS: observed carrier identity reaches stateful leak"
