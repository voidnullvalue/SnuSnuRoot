#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_dir/scripts/carrier_abi.sh"
payload_root="$repo_dir/prebuilt/device"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
asset_dir=/data/securedStorageLocation/codex.amazon.jni.v51
valid_suffix='elf=ELF64 abi=arm64-v8a jni=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so'
assert_identity_passes() {
    carrier_validate_identity "$1" "$asset_dir" \
        || fail "valid identity rejected: $CARRIER_VALIDATION_ERROR"
}
assert_identity_fails() {
    expected="$1"
    identity="$2"
    if carrier_validate_identity "$identity" "$asset_dir"; then
        fail "invalid identity accepted: $identity"
    fi
    case "$CARRIER_VALIDATION_ERROR" in *"$expected"*) : ;;
        *) fail "expected error '$expected', got '$CARRIER_VALIDATION_ERROR'" ;; esac
}

# 64-bit device + 64-bit carrier.
selected64="$(select_payload ELF64 "$payload_root")"
assert_eq "$selected64" "$payload_root/arm64-v8a/libhwbinder_target.so"
assert_eq "$(elf_class_file "$selected64")" ELF64

# 64-bit device + 32-bit carrier: selection follows the carrier class.
selected32="$(select_payload ELF32 "$payload_root")"
assert_eq "$selected32" "$payload_root/armeabi-v7a/libhwbinder_target.so"
assert_eq "$(elf_class_file "$selected32")" ELF32

# Incompatible and missing payloads fail closed.
empty_root="$(mktemp -d)"
trap 'rm -rf "$empty_root"' EXIT HUP INT TERM
if select_payload ELF64 "$empty_root" >/dev/null 2>&1; then
    fail "missing payload was accepted"
fi
mkdir -p "$empty_root/arm64-v8a"
printf 'not an elf\n' > "$empty_root/arm64-v8a/libhwbinder_target.so"
if select_payload ELF64 "$empty_root" >/dev/null 2>&1; then
    fail "incompatible payload was accepted"
fi

# A respawn is re-evaluated; a replacement with another ABI changes selection.
first="$(select_payload ELF64 "$payload_root")"
replacement="$(select_payload ELF32 "$payload_root")"
[ "$first" != "$replacement" ] || fail "respawn reused stale ABI selection"

agent_strings="$(unzip -p "$payload_root/arm64-v8a/agent.jar" classes.dex | strings)"
for marker in libhwbinder_target. elf= abi= jni=; do
    case "$agent_strings" in *"$marker"*) : ;;
        *) fail "agent lacks runtime ABI marker: $marker" ;; esac
done

# Exact field parsing for the observed legacy carrier and formatting variants.
observed='uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Uid:=10100=10100=10100=10100 Gid:=10100=10100=10100=10100 Groups:=3003  elf=ELF64 abi=arm64-v8a jni=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so'
assert_identity_passes "$observed"
assert_identity_passes "uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups: 3003  $valid_suffix"
assert_identity_passes "uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups:=3003  $valid_suffix"
assert_identity_passes "uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups: 9997   3003 3004  $valid_suffix"

# Machine-readable output is independent of field order.
tab="$(printf '\tX')"; tab="${tab%X}"
assert_identity_passes "IDV2${tab}jni=$asset_dir/libhwbinder_target.arm64-v8a.so${tab}groups=9997,3003${tab}pid=1995${tab}uid=10100${tab}abi=arm64-v8a${tab}context=u:r:amazon_app:s0${tab}elf=ELF64"
assert_identity_passes "uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups:${tab}9997${tab}3003  $valid_suffix"

assert_identity_fails "missing supplementary group 3003" \
    "uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups: 9997  $valid_suffix"
assert_identity_fails "missing supplementary group 3003" \
    "uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups: 13003 30030  $valid_suffix"
assert_identity_fails "UID must be 10100" \
    "uid=10101 pid=1995 context=u:r:amazon_app:s0 status=Groups: 3003  $valid_suffix"
assert_identity_fails "SELinux context" \
    "uid=10100 pid=1995 context=u:r:untrusted_app:s0 status=Groups: 3003  $valid_suffix"
assert_identity_fails "invalid PID" \
    "uid=10100 context=u:r:amazon_app:s0 status=Groups: 3003  $valid_suffix"
assert_identity_fails "ABI/ELF mismatch" \
    "uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups: 3003 elf=ELF64 abi=armeabi-v7a jni=$asset_dir/libhwbinder_target.armeabi-v7a.so"
assert_identity_fails "ABI/JNI mismatch" \
    "uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups: 3003 elf=ELF64 abi=arm64-v8a jni=$asset_dir/libhwbinder_target.armeabi-v7a.so"

echo "PASS: carrier ABI selection regressions"
