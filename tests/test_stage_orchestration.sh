#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
mock="$repo_dir/tests/fixtures/mock_adb_stages.sh"
asset="$repo_dir/tests/fixtures/mock_asset_helper.sh"
runner="$repo_dir/tests/fixtures/mock_stage_runner.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

# Asset stage is repeatable and ends in a stable result.
for _ in 1 2; do
    ADB="$mock" SNUSNU_ASSET_HELPER="$asset" MOCK_ASSET_LOG="$tmp/assets.log" \
        "$repo_dir/runme.sh" stage-assets >"$tmp/out"
    grep -q '^STAGE_OK stage-assets$' "$tmp/out" || fail 'repeat asset stage failed'
done

# Invalid/numeric-unarmed waiter is reported without rebooting.
if ADB="$mock" SNUSNU_ASSET_HELPER="$asset" MOCK_SAVED_TIME=broken MOCK_ADB_LOG="$tmp/waiter.log" \
    "$repo_dir/runme.sh" arm-waiter >"$tmp/out" 2>&1; then fail 'invalid waiter state accepted'; fi
grep -q 'class=WAITER_UNARMED' "$tmp/out" || fail 'waiter-unarmed not classified'
! grep -q '^CALL reboot' "$tmp/waiter.log" || fail 'standalone waiter rebooted'

# Root composition has a stable order when no reboot/retry is needed.
stage_log="$tmp/order"; : >"$stage_log"
ADB="$mock" SNUSNU_STAGE_RUNNER="$runner" MOCK_STAGE_LOG="$stage_log" MOCK_STAGE_COUNT="$tmp/count" \
    "$repo_dir/runme.sh" root >"$tmp/out"
expected='stage-assets
arm-waiter
carrier
leak
write
root-service
bootstrap-magisk
install-persistence'
[ "$(cat "$stage_log")" = "$expected" ] || { cat "$stage_log"; fail 'root stage order changed'; }

# Unsupported firmware is rejected before the first stage can stage or run a
# build-specific carrier.
: >"$stage_log"
if ADB="$mock" MOCK_FW_BUILD=PS7329.3842N \
    MOCK_FW_FINGERPRINT='Amazon/trona/trona:9/PS7329.3842N/device:user/amz-p,release-keys' \
    SNUSNU_STAGE_RUNNER="$runner" MOCK_STAGE_LOG="$stage_log" \
    "$repo_dir/runme.sh" root >"$tmp/out" 2>&1; then
    fail 'unsupported firmware entered the root flow'
else
    rc=$?
fi
[ "$rc" -eq 23 ] || fail "unsupported firmware exit was $rc"
[ ! -s "$stage_log" ] || fail 'unsupported firmware ran a root stage'
grep -q 'class=FIRMWARE_UNSUPPORTED' "$tmp/out" \
    || fail 'unsupported firmware was not classified'

# Deterministic carrier failure does not reboot or retry.
: >"$stage_log"; : >"$tmp/adb.log"
if ADB="$mock" MOCK_ADB_LOG="$tmp/adb.log" SNUSNU_STAGE_RUNNER="$runner" MOCK_STAGE_LOG="$stage_log" \
    MOCK_STAGE_COUNT="$tmp/count" MOCK_FAIL_STAGE=carrier "$repo_dir/runme.sh" root >"$tmp/out" 2>&1; then fail 'carrier failure succeeded'; fi
[ "$(grep -c '^carrier$' "$stage_log")" -eq 1 ] || fail 'deterministic carrier failure retried'
! grep -q '^CALL reboot' "$tmp/adb.log" || fail 'deterministic failure rebooted'

# Binder-spent failures alone get fresh-boot retries, bounded by attempts.
: >"$stage_log"; : >"$tmp/adb.log"; rm -f "$tmp/count"
if ADB="$mock" MOCK_ADB_LOG="$tmp/adb.log" SNUSNU_STAGE_RUNNER="$runner" MOCK_STAGE_LOG="$stage_log" \
    MOCK_STAGE_COUNT="$tmp/count" MOCK_FAIL_STAGE=leak SNUSNU_ROOT_ATTEMPTS=2 SNUSNU_REBOOT_SETTLE_SECONDS=0 \
    "$repo_dir/runme.sh" root >"$tmp/out" 2>&1; then fail 'always-spent Binder flow succeeded'; else rc=$?; fi
[ "$rc" -eq 30 ] || fail "Binder exhausted exit was $rc"
[ "$(grep -c '^leak$' "$stage_log")" -eq 2 ] || fail 'Binder-spent flow was not retried once'
[ "$(grep -c '^CALL reboot' "$tmp/adb.log")" -eq 1 ] || fail 'Binder retry did not use exactly one fresh boot'

echo 'PASS: standalone safety and root orchestration'
