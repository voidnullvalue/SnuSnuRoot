#!/bin/sh
# Live carrier operations. Validation always precedes Binder commands.

. "$SNUSNU_REPO_DIR/scripts/carrier_abi.sh"

carrier_ping() {
    [ "$(printf 'PING\n' | adb shell "toybox nc -w 3 127.0.0.1 $SNUSNU_PROBE_PORT" 2>&1 | tr -d '\r')" = PONG ]
}

carrier_identity() {
    printf 'ID\n' | adb shell "toybox nc -w 3 127.0.0.1 $SNUSNU_PROBE_PORT" 2>&1 | tr -d '\r'
}

remote_elf_class() {
    bytes="$(device_value "toybox od -An -t u1 -N 5 '$1' 2>/dev/null" | tr -s ' ' | sed 's/^ //')"
    case "$bytes" in
        '127 69 76 70 1') echo ELF32 ;;
        '127 69 76 70 2') echo ELF64 ;;
        *) echo UNKNOWN ;;
    esac
}

carrier_validate_live() {
    carrier_ping || { CARRIER_VALIDATION_ERROR=not_running; return 1; }
    identity="$(carrier_identity)"
    carrier_validate_identity "$identity" "$SNUSNU_ASSET_DIR" || return 1
    selected_class="$(remote_elf_class "$CARRIER_JNI")"
    [ "$selected_class" = "$CARRIER_ELF" ] || {
        CARRIER_VALIDATION_ERROR="ABI/JNI ELF mismatch (carrier=$CARRIER_ELF payload=$selected_class)"
        return 1
    }
    [ "$CARRIER_ELF" = ELF64 ] || {
        CARRIER_VALIDATION_ERROR="ELF32 Binder compat ABI is unsafe for 64-bit kernel pointers"
        return 1
    }
    return 0
}

carrier_spawn() {
    payload='LClass1;->method1(
10
--runtime-args
--setuid=10100
--setgid=10100
--runtime-flags=2049
--mount-external-full
--setgroups=3003
--nice-name=codex-system-amazon-v52
--seinfo=amazonapp:targetSdkVersion=22:complete
--invoke-with
/system/bin/sh '"$SNUSNU_ASSET_DIR"'/carrier_launcher.sh;
'
    {
        printf 'settings put global hidden_api_blacklist_exemptions "%s"\n' "$payload"
        printf 'settings delete global hidden_api_blacklist_exemptions\n'
    } | adb shell >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        carrier_ping && return 0
        sleep 1
    done
    return 1
}

carrier_print() {
    printf 'carrier_pid=%s\ncarrier_uid=%s\ncarrier_context=%s\n' "$CARRIER_PID" "$CARRIER_UID" "$CARRIER_CONTEXT"
    printf 'carrier_group_3003=yes\ncarrier_elf=%s\ncarrier_abi=%s\ncarrier_jni=%s\n' "$CARRIER_ELF" "$CARRIER_ABI" "$CARRIER_JNI"
}

