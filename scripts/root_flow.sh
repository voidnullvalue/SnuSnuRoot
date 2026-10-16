#!/bin/sh
# High-level composition only. Individual implementation lives in stages/.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STAGE_NAME=root
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"

run_stage() {
    stage="$1"; shift
    script="$1"; shift
    if [ -n "${SNUSNU_STAGE_RUNNER:-}" ]; then
        "$SNUSNU_STAGE_RUNNER" "$stage" "$script" "$@"
    else
        "$script" "$@"
    fi
}

wait_for_boot() {
    adb wait-for-device >/dev/null 2>&1 || true
    completed=
    for _ in $(seq 1 60); do
        completed="$(device_value getprop sys.boot_completed)"
        [ "$completed" = 1 ] && return 0
        sleep 5
    done
    stage_fatal root PRECONDITION_FAILURE boot_completed_never_reached
}

fresh_boot() {
    echo 'orchestrator=reboot_for_fresh_boot'
    adb reboot >/dev/null 2>&1 || true
    sleep "${SNUSNU_REBOOT_SETTLE_SECONDS:-10}"
    wait_for_boot
}

require_device
require_verified_firmware
payload="${1:-$SNUSNU_REPO_DIR/scripts/rootsvc_payload.sh}"
pre_waiter="$(waiter_state "$(device_value getprop persist.sys.saved_time)")"
run_stage stage-assets "$SNUSNU_REPO_DIR/scripts/stages/10-stage-assets.sh"
run_stage arm-waiter "$SNUSNU_REPO_DIR/scripts/stages/20-arm-waiter.sh" "$payload"
if [ "$pre_waiter" != armed ]; then
    fresh_boot
fi

max_attempts="${SNUSNU_ROOT_ATTEMPTS:-6}"
case "$max_attempts" in ''|*[!0-9]*|0) stage_fatal root PRECONDITION_FAILURE invalid_SNUSNU_ROOT_ATTEMPTS ;; esac
attempt=1
while :; do
    echo "root_attempt=$attempt/$max_attempts"
    run_stage carrier "$SNUSNU_REPO_DIR/scripts/stages/30-carrier.sh"
    if run_stage leak "$SNUSNU_REPO_DIR/scripts/stages/40-hwbinder-leak.sh"; then
        break
    else
        leak_rc=$?
    fi
    [ "$leak_rc" -eq 30 ] \
        || stage_fatal root PRECONDITION_FAILURE deterministic_stage_failure_no_retry "$leak_rc"
    [ "$attempt" -lt "$max_attempts" ] \
        || stage_fatal root BINDER_BOOT_SPENT binder_attempts_exhausted 30
    attempt=$((attempt + 1))
    fresh_boot
    case "$(waiter_state "$(device_value getprop persist.sys.saved_time)")" in
        armed) : ;;
        unarmed_numeric)
            run_stage arm-waiter "$SNUSNU_REPO_DIR/scripts/stages/20-arm-waiter.sh" "$payload"
            fresh_boot
            ;;
        *) stage_fatal root WAITER_UNARMED invalid_waiter_state_during_retry 40 ;;
    esac
done
run_stage write "$SNUSNU_REPO_DIR/scripts/stages/50-hwbinder-write.sh"
run_stage root-service "$SNUSNU_REPO_DIR/scripts/stages/60-root-handoff.sh"
run_stage bootstrap-magisk "$SNUSNU_REPO_DIR/scripts/stages/70-magisk-bootstrap.sh"
run_stage install-persistence "$SNUSNU_REPO_DIR/scripts/stages/80-install-persistence.sh"
echo 'ROOT_OK complete_root_magisk_persistence'

