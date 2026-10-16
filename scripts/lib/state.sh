#!/bin/sh
# Advisory, atomically replaced stage evidence. Every authorization also uses
# live device checks; boot-scoped records are invalid across boot IDs.

state_validate_name() {
    case "$1" in ''|*[!a-z0-9_-]*) return 1 ;; esac
}

state_init() {
    if [ "${SNUSNU_STATE_BACKEND:-device}" = local ]; then
        mkdir -p "$SNUSNU_STATE_DIR"
    else
        adb shell "mkdir -p '$SNUSNU_STATE_DIR'; chmod 0777 '$SNUSNU_STATE_DIR'" >/dev/null
    fi
}

state_record() {
    stage="$1"; status="$2"; boot="$3"; detail="${4:-}"
    state_validate_name "$stage" || return 1
    [ -n "$boot" ] || return 1
    state_init
    if [ "${SNUSNU_STATE_BACKEND:-device}" = local ]; then
        tmp="$SNUSNU_STATE_DIR/.$stage.$$"
        printf 'status=%s\nboot_id=%s\ndetail=%s\n' "$status" "$boot" "$detail" >"$tmp"
        mv -f "$tmp" "$SNUSNU_STATE_DIR/$stage"
    else
        # Values written here are generated identifiers/result classes, never
        # user shell text. Replace whitespace in detail before interpolation.
        clean_detail="$(stage_reason "$detail")"
        adb shell "tmp='$SNUSNU_STATE_DIR/.$stage.\$\$'; printf '%s\\n' 'status=$status' 'boot_id=$boot' 'detail=$clean_detail' >\"\$tmp\" && chmod 0666 \"\$tmp\" && mv -f \"\$tmp\" '$SNUSNU_STATE_DIR/$stage'" >/dev/null
    fi
}

state_field() {
    stage="$1"; field="$2"
    state_validate_name "$stage" || return 1
    case "$field" in status|boot_id|detail) : ;; *) return 1 ;; esac
    if [ "${SNUSNU_STATE_BACKEND:-device}" = local ]; then
        [ -f "$SNUSNU_STATE_DIR/$stage" ] || return 1
        sed -n "s/^$field=//p" "$SNUSNU_STATE_DIR/$stage" | tail -1
    else
        device_value "sed -n 's/^$field=//p' '$SNUSNU_STATE_DIR/$stage' 2>/dev/null" | tail -1
    fi
}

state_boot_relation() {
    stage="$1"; now="$2"
    recorded="$(state_field "$stage" boot_id 2>/dev/null || true)"
    [ -n "$recorded" ] || { echo missing; return; }
    [ "$recorded" = "$now" ] && echo current || echo stale
}

require_current_success() {
    required="$1"; consumer="$2"; message="$3"
    now="$(current_boot_id)"
    relation="$(state_boot_relation "$required" "$now")"
    status="$(state_field "$required" status 2>/dev/null || true)"
    [ "$relation" = current ] && [ "$status" = success ] \
        || stage_fatal "$consumer" PRECONDITION_FAILURE "$message"
}

state_clear_all() {
    if [ "${SNUSNU_STATE_BACKEND:-device}" = local ]; then
        [ -d "$SNUSNU_STATE_DIR" ] && find "$SNUSNU_STATE_DIR" -maxdepth 1 -type f -delete
    else
        adb shell "rm -rf '$SNUSNU_STATE_DIR'" >/dev/null
    fi
}
