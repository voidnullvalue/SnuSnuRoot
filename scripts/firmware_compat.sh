#!/bin/sh
# POSIX-shell, sourceable firmware identity and compatibility guard.
# Caller defines adb() and passes an absolute manifest path.
# The manifest is informational except for exact verified:prebuilt matches.
# No force/skip override: a mistaken kernel write is not an acceptable fallback.

snusnu_firmware_probe() {
    SNUSNU_FW_DEVICE="$(adb shell getprop ro.product.device 2>/dev/null | tr -d '\r\n')" || return 1
    SNUSNU_FW_BUILD="$(adb shell getprop ro.build.id 2>/dev/null | tr -d '\r\n')" || return 1
    SNUSNU_FW_INCREMENTAL="$(adb shell getprop ro.build.version.incremental 2>/dev/null | tr -d '\r\n')" || return 1
    SNUSNU_FW_FINGERPRINT="$(adb shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r\n')" || return 1

    [ -n "$SNUSNU_FW_DEVICE" ] && [ -n "$SNUSNU_FW_BUILD" ] \
        && [ -n "$SNUSNU_FW_INCREMENTAL" ] \
        && [ -n "$SNUSNU_FW_FINGERPRINT" ] || return 1

    # A version number alone is not sufficient: verify the fingerprint agrees
    # on both device identity and build ID. Never construct a payload from it.
    case "$SNUSNU_FW_FINGERPRINT" in
        "Amazon/$SNUSNU_FW_DEVICE/$SNUSNU_FW_DEVICE:"*"/$SNUSNU_FW_BUILD/"*) ;;
        *) return 1 ;;
    esac
}

snusnu_firmware_resolve() {
    manifest="$1"
    [ -r "$manifest" ] || return 1
    SNUSNU_FW_TIER=unsupported
    SNUSNU_FW_ASSETS=none
    count=0
    while IFS='|' read -r record_device record_build record_incremental record_tier record_assets record_notes; do
        case "$record_device" in ""|\#*) continue ;; esac
        [ "$record_device" = "$SNUSNU_FW_DEVICE" ] || continue
        [ "$record_build" = "$SNUSNU_FW_BUILD" ] || continue
        if [ "$record_incremental" != '*' ] \
                && [ "$record_incremental" != "$SNUSNU_FW_INCREMENTAL" ]; then
            continue
        fi
        count=$((count + 1))
        SNUSNU_FW_TIER="$record_tier"
        SNUSNU_FW_ASSETS="$record_assets"
    done < "$manifest"
    # Duplicate matches are ambiguous, including overlapping wildcard rows.
    [ "$count" -le 1 ] || return 1
    # A wildcard entry may NEVER authorize an executable payload.
    case "$SNUSNU_FW_ASSETS:$SNUSNU_FW_TIER:$count" in
        prebuilt:verified:1)
            # Verify the selected entry is a specific incremental.
            # The shipped firmware is the only entry allowed to do kernel writes.
            [ "$record_incremental" != '*' ] || return 1
            ;;
        none:*|prebuilt:*|*:*) ;;
    esac
    return 0
}

snusnu_firmware_report() {
    if ! snusnu_firmware_probe; then
        echo "firmware=unknown reason=missing_or_inconsistent_adb_properties" >&2
        return 1
    fi
    if ! snusnu_firmware_resolve "$1"; then
        echo "firmware=unknown reason=manifest_missing_or_ambiguous" >&2
        return 1
    fi
    echo "firmware_device=$SNUSNU_FW_DEVICE"
    echo "firmware_build=$SNUSNU_FW_BUILD"
    echo "firmware_incremental=$SNUSNU_FW_INCREMENTAL"
    echo "firmware_verification=$SNUSNU_FW_TIER"
    echo "firmware_assets=$SNUSNU_FW_ASSETS"
    [ "$SNUSNU_FW_TIER:$SNUSNU_FW_ASSETS" = verified:prebuilt ] || return 1
}

snusnu_firmware_require() {
    if ! snusnu_firmware_report "$1"; then
        echo "FATAL: no verified, exact-build payload; refusing to stage or execute the kernel-write carrier" >&2
        return 1
    fi
}
