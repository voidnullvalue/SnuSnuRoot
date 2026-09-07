#!/bin/sh
set -eu

# Install the carrier agent and both ABI variants required by the initial
# root carrier. The operation is hash-gated and safe to repeat.

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
adb_bin="${ADB:-$repo_dir/tools/adb-portable.sh}"
asset_dir="${SNUSNU_ASSET_DIR:-/data/securedStorageLocation/codex.amazon.jni.v51}"
prebuilt_dir="$repo_dir/prebuilt/device/arm64-v8a"
prebuilt32_dir="$repo_dir/prebuilt/device/armeabi-v7a"
action="${1:-install}"

adb() { timeout 30 "$adb_bin" "$@"; }
die() { echo "FATAL: $*" >&2; exit 1; }

host_file() {
    case "$1" in
        agent.jar) echo "$prebuilt_dir/agent.jar" ;;
        libcodex_jni.so) echo "$prebuilt_dir/libcodex_jni.so" ;;
        libhwbinder_target.so) echo "$prebuilt_dir/libhwbinder_target.so" ;;
        libhwbinder_target.arm64-v8a.so) echo "$prebuilt_dir/libhwbinder_target.so" ;;
        libhwbinder_target.armeabi-v7a.so) echo "$prebuilt32_dir/libhwbinder_target.so" ;;
        carrier_launcher.sh) echo "$repo_dir/scripts/carrier_launcher.sh" ;;
        *) die "unknown initial-root artifact: $1" ;;
    esac
}

device_digest() {
    adb shell "toybox sha256sum '$asset_dir/$1' 2>/dev/null" \
        | tr -d '\r' | awk '{print $1}'
}

artifact_ready() {
    source="$(host_file "$1")"
    [ -s "$source" ] || die "missing initial-root artifact: $source"
    expected="$(sha256sum "$source" | awk '{print $1}')"
    actual="$(device_digest "$1")"
    [ "$actual" = "$expected" ]
}

verify_assets() {
    failed=0
    for name in agent.jar libcodex_jni.so libhwbinder_target.so \
        libhwbinder_target.arm64-v8a.so \
        libhwbinder_target.armeabi-v7a.so carrier_launcher.sh; do
        source="$(host_file "$name")"
        expected="$(sha256sum "$source" | awk '{print $1}')"
        actual="$(device_digest "$name")"
        if [ "$actual" = "$expected" ]; then
            echo "$name=ready sha256=$actual"
        else
            echo "$name=missing_or_mismatched expected=$expected actual=${actual:-absent}"
            failed=1
        fi
    done
    return "$failed"
}

ensure_uid1000_channel() {
    identity="$(printf 'id\nexit\n' | adb shell \
        'toybox nc -w 3 127.0.0.1 4321' 2>/dev/null | tr -d '\r')"
    case "$identity" in *uid=1000*) return 0 ;; esac

    echo "starting uid-1000 staging channel"
    timeout 30 "$adb_bin" shell < "$repo_dir/scripts/zygote_payload_system_app.sh" \
        >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        identity="$(printf 'id\nexit\n' | adb shell \
            'toybox nc -w 3 127.0.0.1 4321' 2>/dev/null | tr -d '\r')"
        case "$identity" in *uid=1000*) return 0 ;; esac
        sleep 1
    done
    die "could not start uid-1000 staging channel"
}

emit_file() {
    target="$1"
    source="$2"
    encoded="$target.new.b64"
    decoded="$target.new"
    printf ': > %s\n' "$encoded"
    base64 "$source" | tr -d '\n' | fold -w 512 \
        | while IFS= read -r chunk || [ -n "$chunk" ]; do
        printf "printf '%%s' '%s' >> %s\n" "$chunk" "$encoded"
    done
    printf 'toybox base64 -d %s > %s && chmod 0555 %s && rm -f %s\n' \
        "$encoded" "$decoded" "$decoded" "$encoded"
}

install_artifact() {
    name="$1"
    source="$(host_file "$name")"
    target="$asset_dir/$name"
    expected="$(sha256sum "$source" | awk '{print $1}')"
    if artifact_ready "$name"; then
        echo "$name=already_current"
        return 0
    fi

    echo "installing $name"
    output="$({
        emit_file "$target" "$source"
        printf 'test "$(toybox sha256sum %s.new | cut -d" " -f1)" = %s && mv -f %s.new %s && sync\n' \
            "$target" "$expected" "$target" "$target"
        printf 'toybox sha256sum %s\nexit\n' "$target"
    } | timeout 180 "$adb_bin" shell \
        'toybox nc -w 150 127.0.0.1 4321' 2>&1 | tr -d '\r')"
    case "$output" in
        *"$expected"*) : ;;
        *) die "transfer verification failed for $name: $output" ;;
    esac
}

case "$action" in
    verify)
        verify_assets
        ;;
    install)
        if verify_assets >/dev/null 2>&1; then
            verify_assets
            exit 0
        fi
        ensure_uid1000_channel
        printf 'mkdir -p %s; chmod 0755 %s\nexit\n' "$asset_dir" "$asset_dir" \
            | adb shell 'toybox nc -w 10 127.0.0.1 4321' >/dev/null
        for name in agent.jar libcodex_jni.so libhwbinder_target.so \
            libhwbinder_target.arm64-v8a.so \
            libhwbinder_target.armeabi-v7a.so carrier_launcher.sh; do
            install_artifact "$name"
        done
        verify_assets || die "initial-root asset verification failed"
        ;;
    *)
        die "usage: $0 [install|verify]"
        ;;
esac
