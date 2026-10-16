#!/bin/sh
# Contract: input=current-boot successful leak; preconditions=same boot, same
# live carrier PID, valid ABI/JNI; action=HWBINDER_STATEFUL_WRITE only; output=
# native 0x51 result and live Permissive. Idempotent=live-verified after success.
# Requires same boot=yes. Safe retry=no after an uncertain write. Next:
# root-service. Never arms, leaks, reboots, or bootstraps Magisk.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=write
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/state.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/carrier.sh"

require_device
require_verified_firmware
boot="$(current_boot_id)"
require_current_success leak "$STAGE_NAME" 'write requires a successful hwbinder leak from the current boot'
if [ "$(state_boot_relation write "$boot")" = current ] \
        && [ "$(state_field write status 2>/dev/null || true)" = success ] \
        && [ "$(device_value getenforce)" = Permissive ]; then
    echo 'write=success_already_verified'
    stage_ok "$STAGE_NAME"
    exit 0
fi
carrier_validate_live \
    || stage_fatal "$STAGE_NAME" CARRIER_FAILURE "$CARRIER_VALIDATION_ERROR" 22
leak_detail="$(state_field leak detail 2>/dev/null || true)"
leak_pid="${leak_detail#pid=}"; leak_pid="${leak_pid%%,*}"
[ "$leak_pid" = "$CARRIER_PID" ] \
    || stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE leak_carrier_pid_is_stale
state_record write attempting "$boot" "pid=$CARRIER_PID"
result="$(printf 'HWBINDER_STATEFUL_WRITE\n' | adb shell "toybox nc -w 6 127.0.0.1 $SNUSNU_PROBE_PORT" 2>&1 | tr -d '\r' || true)"
echo "hwbinder_write_result=$result"
case "$result" in *result=0x51*) : ;; *)
    state_record write unknown "$boot" "result=$(stage_reason "$result")"
    stage_fatal "$STAGE_NAME" POST_WRITE_FAILURE unexpected_native_write_result 50
esac
enforce="$(device_value getenforce)"
[ "$enforce" = Permissive ] || {
    state_record write failed "$boot" "selinux=$enforce"
    stage_fatal "$STAGE_NAME" POST_WRITE_FAILURE selinux_not_permissive_after_write 50
}
state_record write success "$boot" "pid=$CARRIER_PID,result=0x51,selinux=Permissive"
echo 'write=success'
echo 'selinux=Permissive'
echo "boot_id=$boot"
stage_ok "$STAGE_NAME"

