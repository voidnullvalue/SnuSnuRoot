#!/bin/sh
set -eu

# SnuSnuRoot single entry point: root the tablet and install Magisk.
#
#   ./runme.sh root              full root flow: stage waiter -> reboot -> reroot -> uid-0 listener on 4325
#   ./runme.sh bootstrap         Phase 1: live Magisk runtime on /sbin (magiskd + su + policy)
#   ./runme.sh manager           Phase 2: build/install Manager, post-fs-data, service, boot-complete, launch
#   ./runme.sh request           trigger an adb-shell MagiskSU authorization request
#   ./runme.sh status            report current device state
#   ./runme.sh disarm            remove root persistence (restore numeric saved_time) -- optional revert
#   ./runme.sh help              this message
#
# Sequence on a stock device: root -> bootstrap -> manager -> (tap Allow on device).

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PATH="$SELF_DIR/tools/xbps-root/usr/bin:$PATH"
export LD_LIBRARY_PATH="$SELF_DIR/tools/xbps-root/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

ACTION="${1:-help}"

require_adb() {
    adb get-state >/dev/null 2>&1 \
        || { echo "FATAL: no authorized adb device" >&2; exit 1; }
}

do_status() {
    "$SELF_DIR/scripts/snusnu_magisk_manager.sh" status
    echo
    "$SELF_DIR/scripts/root_poc.sh" status
}

case "$ACTION" in
    root)
        require_adb
        echo "start: staging waiter and running the root flow"
        exec "$SELF_DIR/scripts/root_poc.sh"
        ;;
    bootstrap)
        require_adb
        exec "$SELF_DIR/scripts/snusnu_magisk_bootstrap.sh" start
        ;;
    manager)
        require_adb
        exec "$SELF_DIR/scripts/snusnu_magisk_manager.sh" setup
        ;;
    request)
        require_adb
        exec "$SELF_DIR/scripts/snusnu_magisk_manager.sh" request
        ;;
    status)
        require_adb
        do_status
        ;;
    disarm)
        require_adb
        exec "$SELF_DIR/scripts/root_poc.sh" disarm
        ;;
    help|--help|-h|"")
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "FATAL: unknown action: $ACTION (root|bootstrap|manager|request|status|disarm)" >&2
        exit 2
        ;;
esac