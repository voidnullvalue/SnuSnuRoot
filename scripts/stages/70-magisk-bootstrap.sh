#!/bin/sh
# Contract: input=packaged Magisk runtime; precondition=healthy UID-0 listener;
# action=existing reversible /sbin bootstrap; output=verified daemon/socket.
# Idempotent=implementation-defined and live-verified. Boot-scoped=yes.
# Binder/Zygote=no. Safe retry=yes after bootstrap rollback. Next: persistence,
# manager, or stop.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=bootstrap-magisk
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/state.sh"

require_device
root_reply="$(printf 'id -u\nexit\n' | adb shell "toybox nc -w 2 127.0.0.1 $SNUSNU_ROOT_PORT" 2>/dev/null | tr -d '\r' || true)"
case "$root_reply" in 0*) : ;; *) stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE uid0_listener_required ;; esac
"$SNUSNU_REPO_DIR/scripts/snusnu_magisk_bootstrap.sh" start \
    || stage_fatal "$STAGE_NAME" POST_WRITE_FAILURE magisk_bootstrap_failed 50
ready="$(device_value "test -S /sbin/.magisk/device/socket && ps | grep -q '[m]agiskd' && echo yes || echo no")"
[ "$ready" = yes ] || stage_fatal "$STAGE_NAME" POST_WRITE_FAILURE magisk_daemon_or_socket_missing 50
boot="$(current_boot_id)"
state_record magisk success "$boot" daemon_and_socket_ready
echo 'magisk=ready'
echo 'magisk_socket=ready'
stage_ok "$STAGE_NAME"

