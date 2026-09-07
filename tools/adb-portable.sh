#!/bin/sh
set -eu

tool_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(CDPATH= cd -- "$tool_dir/.." && pwd)"
bundled_adb="$repo_dir/tools/xbps-root/usr/bin/adb"
bundled_loader="$repo_dir/tools/xbps-root/usr/lib/ld-linux-x86-64.so.2"
bundled_lib="$repo_dir/tools/xbps-root/usr/lib"

if [ -n "${SNUSNU_SYSTEM_ADB:-}" ]; then
    exec "$SNUSNU_SYSTEM_ADB" "$@"
fi
if [ "${SNUSNU_USE_BUNDLED_ADB:-0}" != 1 ] && command -v adb >/dev/null 2>&1; then
    exec "$(command -v adb)" "$@"
fi
if [ "$(uname -m)" = x86_64 ] && [ -x "$bundled_adb" ] \
        && [ -x "$bundled_loader" ]; then
    exec "$bundled_loader" --library-path "$bundled_lib" "$bundled_adb" "$@"
fi

echo "FATAL: adb unavailable; install Android platform-tools or set SNUSNU_SYSTEM_ADB" >&2
exit 127
