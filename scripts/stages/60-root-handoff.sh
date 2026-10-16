#!/bin/sh
# Contract: input=current-boot successful write and pre-staged waiter payload;
# preconditions=Permissive + current write evidence; action=wait for UID-0
# handoff only; output=validated listener UID/context. Boot-scoped=yes.
# Idempotent=yes while listener lives. Binder/Zygote=no. Safe retry=yes.
# Next: bootstrap-magisk or stop. Does not bootstrap Magisk itself.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=root-service
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/state.sh"

require_device
require_current_success write "$STAGE_NAME" 'root-service requires a successful write from the current boot'
[ "$(device_value getenforce)" = Permissive ] \
    || stage_fatal "$STAGE_NAME" POST_WRITE_FAILURE SELinux_is_not_Permissive 50
reply=
for _ in $(seq 1 60); do
    reply="$(printf 'id -u\ncat /proc/self/attr/current\nexit\n' | adb shell "toybox nc -w 2 127.0.0.1 $SNUSNU_ROOT_PORT" 2>/dev/null | tr -d '\r' || true)"
    case "$reply" in 0*u:r:time_update:s0*) break ;; esac
    sleep 1
done
case "$reply" in 0*u:r:time_update:s0*) : ;;
    *) stage_fatal "$STAGE_NAME" WAITER_UNARMED uid0_waiter_handoff_not_ready 40 ;;
esac
boot="$(current_boot_id)"
state_record root success "$boot" 'uid=0,context=u:r:time_update:s0'
echo 'root_service=ready'
echo 'root_uid=0'
echo 'root_context=u:r:time_update:s0'
echo "boot_id=$boot"
stage_ok "$STAGE_NAME"

