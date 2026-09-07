#!/bin/sh
set -eu

elf_class_file() {
    file="$1"
    magic="$(od -An -t u1 -N 5 "$file" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
    case "$magic" in
        "127 69 76 70 1") echo ELF32 ;;
        "127 69 76 70 2") echo ELF64 ;;
        *) echo UNKNOWN ;;
    esac
}

abi_for_elf_class() {
    case "$1" in
        ELF32) echo armeabi-v7a ;;
        ELF64) echo arm64-v8a ;;
        *) return 1 ;;
    esac
}

select_payload() {
    class="$1"
    root="$2"
    abi="$(abi_for_elf_class "$class")" || return 1
    payload="$root/$abi/libhwbinder_target.so"
    [ -s "$payload" ] || return 2
    [ "$(elf_class_file "$payload")" = "$class" ] || return 3
    printf '%s\n' "$payload"
}

if [ "${1:-}" = --self-test ]; then
    [ "$(elf_class_file "$2")" = "$3" ]
elif [ "$#" -eq 2 ]; then
    select_payload "$1" "$2"
elif [ "$#" -ne 0 ]; then
    echo "usage: $0 [ELF32|ELF64 PAYLOAD_ROOT]" >&2
    exit 64
fi
