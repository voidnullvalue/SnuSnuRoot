#!/bin/sh
# Contract: input=uid-0 payload (default rootsvc_payload.sh); preconditions=
# verified assets, numeric saved_time or already-valid arm; output=armed waiter,
# original numeric snapshot, boot-scoped evidence. Idempotent=conditional:
# already armed is inspected, never re-armed. Consumes Zygote one-shot=yes when
# arming. Binder=no. Safe retry=no after injection uncertainty. Next: reboot,
# then carrier. This standalone stage never reboots.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=arm-waiter
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/state.sh"

require_device
payload="${1:-$SNUSNU_REPO_DIR/scripts/rootsvc_payload.sh}"
[ -f "$payload" ] || stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE payload_missing
asset_helper="${SNUSNU_ASSET_HELPER:-$SNUSNU_REPO_DIR/scripts/stage_initial_root_assets.sh}"
"$asset_helper" verify >/dev/null 2>&1 \
    || stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE assets_not_ready
saved="$(device_value getprop persist.sys.saved_time)"
case "$(waiter_state "$saved")" in
    armed)
        old="$(device_value 'cat /data/local/tmp/__reroot_old_time')"
        case "$old" in ''|*[!0-9]*) stage_fatal "$STAGE_NAME" WAITER_UNARMED invalid_restore_snapshot ;; esac
        echo 'waiter=already_armed'
        ;;
    unarmed_numeric)
        "$SNUSNU_REPO_DIR/scripts/stage_reroot_waiter.sh" "$payload" \
            || stage_fatal "$STAGE_NAME" ZYGOTE_ONESHOT_SPENT waiter_arming_failed 40
        old="$saved"
        ;;
    *) stage_fatal "$STAGE_NAME" WAITER_UNARMED saved_time_not_numeric_or_armed 40 ;;
esac
[ "$(waiter_state "$(device_value getprop persist.sys.saved_time)")" = armed ] \
    || stage_fatal "$STAGE_NAME" WAITER_UNARMED waiter_verification_failed 40
boot="$(current_boot_id)"
state_record waiter success "$boot" "restore=$old"
echo "waiter=armed"
echo "restore_value=$old"
echo "boot_id=$boot"
stage_ok "$STAGE_NAME"
