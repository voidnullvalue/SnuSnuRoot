#!/bin/sh
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=status
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/state.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/carrier.sh"

require_device
verbose=0
[ "${1:-}" = --verbose ] && verbose=1
boot="$(current_boot_id)"
echo "boot_id=$boot"
echo "selinux=$(device_value getenforce)"
asset_helper="${SNUSNU_ASSET_HELPER:-$SNUSNU_REPO_DIR/scripts/stage_initial_root_assets.sh}"
if "$asset_helper" verify >/dev/null 2>&1; then
    echo 'assets=ready'
else
    echo 'assets=not_ready'
fi
echo "waiter=$(waiter_state "$(device_value getprop persist.sys.saved_time)")"
if carrier_validate_live; then
    echo 'carrier=ready'
    echo "carrier_pid=$CARRIER_PID"
    echo "carrier_abi=$CARRIER_ABI"
    echo "carrier_elf=$CARRIER_ELF"
else
    stored_detail="$(state_field carrier detail 2>/dev/null || true)"
    case "$stored_detail" in pid=*) echo 'carrier=stale_pid_or_not_running' ;; *) echo 'carrier=not_ready' ;; esac
    [ "$verbose" -eq 0 ] || echo "carrier_reason=$(stage_reason "${CARRIER_VALIDATION_ERROR:-unavailable}")"
fi
for entry in leak write; do
    relation="$(state_boot_relation "$entry" "$boot")"
    value="$(state_field "$entry" status 2>/dev/null || true)"
    case "$relation:$value" in
        missing:*) report=not_run ;;
        stale:*) report=stale_previous_boot ;;
        current:success) report=success ;;
        current:spent) report=spent_current_boot ;;
        current:attempting|current:unknown) report=uncertain_current_boot ;;
        *) report="${value:-not_run}" ;;
    esac
    echo "$entry=$report"
done
root_reply="$(printf 'id -u\nexit\n' | adb shell "toybox nc -w 2 127.0.0.1 $SNUSNU_ROOT_PORT" 2>/dev/null | tr -d '\r' || true)"
case "$root_reply" in 0*) echo 'root_service=ready' ;; *) echo 'root_service=not_ready' ;; esac
magisk="$(device_value "test -S /sbin/.magisk/device/socket && ps | grep -q '[m]agiskd' && echo ready || echo not_ready")"
echo "magisk=$magisk"
persist="$(device_value 'settings get global snusnu_persist_enabled')"
[ "$persist" = 1 ] && echo 'persistence=installed' || echo 'persistence=not_installed'
if [ "$verbose" -eq 1 ]; then
    echo "state_dir=$SNUSNU_STATE_DIR"
    echo "saved_time=$(device_value getprop persist.sys.saved_time)"
    echo "carrier_record=$(state_field carrier detail 2>/dev/null || true)"
    echo "leak_record_boot=$(state_field leak boot_id 2>/dev/null || true)"
    echo "write_record_boot=$(state_field write boot_id 2>/dev/null || true)"
fi
