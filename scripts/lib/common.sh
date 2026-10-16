#!/bin/sh
# Shared host helpers for independently runnable root stages.

if [ -z "${SNUSNU_REPO_DIR:-}" ]; then
    SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
fi
SNUSNU_ADB="${ADB:-$SNUSNU_REPO_DIR/tools/adb-portable.sh}"
SNUSNU_ASSET_DIR="${SNUSNU_ASSET_DIR:-/data/securedStorageLocation/codex.amazon.jni.v51}"
SNUSNU_STATE_DIR="${SNUSNU_STATE_DIR:-/data/local/tmp/snusnu-state}"
SNUSNU_PROBE_PORT="${SNUSNU_PROBE_PORT:-43271}"
SNUSNU_ROOT_PORT="${SNUSNU_ROOT_PORT:-4325}"
SNUSNU_TRIGGER='x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000'

adb() { timeout "${SNUSNU_ADB_TIMEOUT:-30}" "$SNUSNU_ADB" "$@"; }
device_value() { adb shell "$@" 2>/dev/null | tr -d '\r'; }

require_device() {
    devices="$(adb devices 2>&1 | awk '$2 == "device" {print $1}')"
    [ -n "$devices" ] || stage_fatal "${STAGE_NAME:-unknown}" PRECONDITION_FAILURE "no_authorized_device"
    count="$(printf '%s\n' "$devices" | awk 'END {print NR}')"
    [ "$count" -eq 1 ] || stage_fatal "${STAGE_NAME:-unknown}" PRECONDITION_FAILURE "multiple_devices_set_ANDROID_SERIAL"
}

current_boot_id() {
    if [ "${SNUSNU_STATE_BACKEND:-device}" = local ]; then
        printf '%s\n' "${SNUSNU_TEST_BOOT_ID:-test-boot}"
    else
        device_value 'cat /proc/sys/kernel/random/boot_id'
    fi
}

stage_reason() { printf '%s' "$*" | tr ' \t\r\n' '_'; }
stage_ok() {
    printf 'STAGE_OK %s\n' "$1"
}
stage_fail_line() {
    printf 'STAGE_FAIL %s class=%s reason=%s\n' "$1" "$2" "$(stage_reason "$3")" >&2
}
stage_fatal() {
    name="$1"; class="$2"; reason="$3"; code="${4:-20}"
    printf 'FATAL: %s\n' "$reason" >&2
    stage_fail_line "$name" "$class" "$reason"
    exit "$code"
}

waiter_state() {
    value="$1"
    if [ "$value" = "$SNUSNU_TRIGGER" ]; then
        echo armed
    else
        case "$value" in
            ''|*[!0-9]*) echo invalid ;;
            *) echo unarmed_numeric ;;
        esac
    fi
}

require_verified_firmware() {
    . "$SNUSNU_REPO_DIR/scripts/firmware_compat.sh"
    snusnu_firmware_require "$SNUSNU_REPO_DIR/firmware/manifest.psv" \
        || stage_fatal "${STAGE_NAME:-firmware}" FIRMWARE_UNSUPPORTED \
            no_verified_exact_build_payload 23
}

