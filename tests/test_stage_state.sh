#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
mock="$repo_dir/tests/fixtures/mock_adb_stages.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
record() {
    dir="$1" stage="$2" status="$3" boot="$4" detail="$5"
    SNUSNU_REPO_DIR="$repo_dir" SNUSNU_STATE_BACKEND=local SNUSNU_STATE_DIR="$dir" SNUSNU_TEST_BOOT_ID="$boot" \
        sh -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/state.sh"; state_record "$3" "$4" "$5" "$6"' sh "$repo_dir" "$dir" "$stage" "$status" "$boot" "$detail"
}
run_stage() {
    state_dir="$1"; shift
    env ADB="$mock" SNUSNU_STATE_BACKEND=local SNUSNU_STATE_DIR="$state_dir" SNUSNU_TEST_BOOT_ID=boot-a "$@"
}

# Leak success records this boot and touches only the leak command.
state="$tmp/leak"; log="$tmp/leak.log"
MOCK_ADB_LOG="$log" run_stage "$state" "$repo_dir/scripts/stages/40-hwbinder-leak.sh" >"$tmp/out"
grep -q '^STAGE_OK leak$' "$tmp/out" || fail 'leak did not succeed'
[ "$(sed -n 's/^boot_id=//p' "$state/leak")" = boot-a ] || fail 'leak boot ID not recorded'
grep -q 'REQUEST=HWBINDER_STATEFUL$' "$log" || fail 'leak primitive not issued'
! grep -q 'HWBINDER_STATEFUL_WRITE' "$log" || fail 'leak invoked write'

# Same-boot write succeeds; stale and missing leak records fail before write.
state="$tmp/write-ok"; record "$state" leak success boot-a pid=1995
run_stage "$state" "$repo_dir/scripts/stages/50-hwbinder-write.sh" >"$tmp/out"
grep -q '^STAGE_OK write$' "$tmp/out" || fail 'same-boot leak rejected'

# Even a valid current-boot leak cannot authorize a build-mismatched write.
state="$tmp/write-firmware"; log="$tmp/write-firmware.log"
record "$state" leak success boot-a pid=1995
if MOCK_FW_BUILD=PS7329.3842N \
    MOCK_FW_FINGERPRINT='Amazon/trona/trona:9/PS7329.3842N/device:user/amz-p,release-keys' \
    MOCK_ADB_LOG="$log" run_stage "$state" \
    "$repo_dir/scripts/stages/50-hwbinder-write.sh" >"$tmp/out" 2>&1; then
    fail 'unsupported firmware authorized write'
else
    rc=$?
fi
[ "$rc" -eq 23 ] || fail "unsupported write exit was $rc"
! grep -q 'REQUEST=HWBINDER_STATEFUL_WRITE$' "$log" \
    || fail 'unsupported firmware touched the write primitive'
state="$tmp/write-stale"; record "$state" leak success boot-old pid=1995
if run_stage "$state" "$repo_dir/scripts/stages/50-hwbinder-write.sh" >"$tmp/out" 2>&1; then fail 'stale leak authorized write'; fi
grep -q 'successful hwbinder leak from the current boot' "$tmp/out" || fail 'stale leak reason unclear'
state="$tmp/write-missing"
if run_stage "$state" "$repo_dir/scripts/stages/50-hwbinder-write.sh" >"$tmp/out" 2>&1; then fail 'missing leak authorized write'; fi

# A stale carrier PID cannot authorize write.
state="$tmp/stale-pid"; record "$state" leak success boot-a pid=9999
if run_stage "$state" "$repo_dir/scripts/stages/50-hwbinder-write.sh" >"$tmp/out" 2>&1; then fail 'stale carrier PID authorized write'; fi
grep -q 'leak_carrier_pid_is_stale' "$tmp/out" || fail 'stale PID not classified'

# Invalid carrier and ABI/JNI mismatch fail before Binder is touched.
bad='uid=10101 pid=1995 context=u:r:amazon_app:s0 status=Groups: 3003  elf=ELF64 abi=arm64-v8a jni=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so'
state="$tmp/bad-carrier"; log="$tmp/bad.log"
if MOCK_IDENTITY="$bad" MOCK_ADB_LOG="$log" run_stage "$state" "$repo_dir/scripts/stages/40-hwbinder-leak.sh" >"$tmp/out" 2>&1; then fail 'invalid carrier accepted'; fi
! grep -q 'REQUEST=HWBINDER_STATEFUL$' "$log" || fail 'invalid carrier touched Binder'
mismatch='uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups: 3003  elf=ELF64 abi=arm64-v8a jni=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.armeabi-v7a.so'
if MOCK_IDENTITY="$mismatch" run_stage "$tmp/mismatch" "$repo_dir/scripts/stages/40-hwbinder-leak.sh" >"$tmp/out" 2>&1; then fail 'ABI/JNI mismatch accepted'; fi

# Failed leak is the only path here that marks this boot spent.
state="$tmp/spent"
if MOCK_LEAK_RESULT='result=0x40003d0000000000' run_stage "$state" "$repo_dir/scripts/stages/40-hwbinder-leak.sh" >"$tmp/out" 2>&1; then fail 'spent leak succeeded'; else rc=$?; fi
[ "$rc" -eq 30 ] || fail "spent leak exit was $rc"
[ "$(sed -n 's/^status=//p' "$state/leak")" = spent ] || fail 'Binder-spent state not recorded'
grep -q 'class=BINDER_BOOT_SPENT' "$tmp/out" || fail 'Binder-spent failure not classified'

# Unparseable transport output is uncertain, not falsely labeled spent.
state="$tmp/unknown"
if MOCK_LEAK_RESULT=transport_error run_stage "$state" "$repo_dir/scripts/stages/40-hwbinder-leak.sh" >"$tmp/out" 2>&1; then fail 'unknown leak succeeded'; else rc=$?; fi
[ "$rc" -eq 31 ] || fail "unknown leak exit was $rc"
[ "$(sed -n 's/^status=//p' "$state/leak")" = unknown ] || fail 'unknown leak was mislabeled spent'
grep -q 'class=BINDER_STATE_UNKNOWN' "$tmp/out" || fail 'unknown Binder state not classified'

# Status exposes stale boot records and stale stored carrier identity.
state="$tmp/status"; record "$state" leak success boot-old pid=1995
record "$state" carrier success boot-a 'pid=1995,abi=arm64-v8a,elf=ELF64'
MOCK_CARRIER_UP=no SNUSNU_ASSET_HELPER="$repo_dir/tests/fixtures/mock_asset_helper.sh" \
    run_stage "$state" "$repo_dir/scripts/stages/status.sh" >"$tmp/out"
grep -q '^leak=stale_previous_boot$' "$tmp/out" || fail 'status treated old leak as current'
grep -q '^carrier=stale_pid_or_not_running$' "$tmp/out" || fail 'status did not expose stale carrier PID'

echo 'PASS: boot-aware stage state and carrier boundaries'
