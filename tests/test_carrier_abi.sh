#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_dir/scripts/carrier_abi.sh"
payload_root="$repo_dir/prebuilt/device"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }

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

echo "PASS: carrier ABI selection regressions"
