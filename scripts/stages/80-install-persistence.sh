#!/bin/sh
# Contract: input=packaged boot actor/runtime; precondition=UID-0 listener;
# action=existing autonomous persistence install/arm; output=verified actor and
# armed trigger. Idempotent=conditional and hash-gated. Binder=no. Zygote=no
# through the current UID-0 channel. Safe retry=installation rollback preserves
# prior enable state. Next: manager, verify, reboot, or disarm.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=install-persistence
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/state.sh"

require_device
require_verified_firmware
root_reply="$(printf 'id -u\nexit\n' | adb shell "toybox nc -w 2 127.0.0.1 $SNUSNU_ROOT_PORT" 2>/dev/null | tr -d '\r' || true)"
case "$root_reply" in 0*) : ;; *) stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE uid0_listener_required ;; esac
"$SNUSNU_REPO_DIR/scripts/persistence_driver.sh" arm \
    || stage_fatal "$STAGE_NAME" POST_WRITE_FAILURE persistence_install_failed 50
[ "$(waiter_state "$(device_value getprop persist.sys.saved_time)")" = armed ] \
    || stage_fatal "$STAGE_NAME" WAITER_UNARMED persistence_did_not_leave_waiter_armed 40
actor="$(device_value 'settings get global snusnu_persist_enabled')"
[ "$actor" = 1 ] || stage_fatal "$STAGE_NAME" POST_WRITE_FAILURE persistence_actor_not_enabled 50
state_record persistence success "$(current_boot_id)" actor_enabled_waiter_armed
echo 'persistence=installed'
echo 'persistence_actor=enabled'
stage_ok "$STAGE_NAME"

