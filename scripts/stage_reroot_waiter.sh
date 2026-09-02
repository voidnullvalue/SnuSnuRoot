#!/bin/sh
set -eu

# Arm the verified boot-time time_update parser with a bounded waiter.  This
# consumes the current boot's Zygote injection; reboot before running the
# hwbinder carrier.  The waiter restores the original numeric property as soon
# as Permissive arrives and the loopback root payload has been launched.

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
adb_bin="$repo_dir/tools/xbps-root/usr/bin/adb"
adb_lib="$repo_dir/tools/xbps-root/usr/lib"
payload_host="${1:?payload path required}"
waiter_dir=/data/securedStorageLocation/w
waiter_file="$waiter_dir/b"
payload_device=/data/local/tmp/__reroot_payload.sh
old_time_file=/data/local/tmp/__reroot_old_time
trigger='x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000'

adb() { LD_LIBRARY_PATH="$adb_lib" "$adb_bin" "$@"; }
die() { echo "FATAL: $*" >&2; exit 1; }

[ -f "$payload_host" ] || die "payload file not found: $payload_host"

exempt="$(adb shell 'settings get global hidden_api_blacklist_exemptions' | tr -d '\r')"
[ "$exempt" = null ] || die "stale exemptions value: $exempt"

old_time="$(adb shell getprop persist.sys.saved_time | tr -d '\r')"
case "$old_time" in
  ''|*[!0-9]*) die "saved_time is not a clean numeric value: $old_time" ;;
esac

adb push "$payload_host" "$payload_device" >/dev/null
adb shell "chmod 0755 $payload_device; printf '%s' '$old_time' > $old_time_file; chmod 0644 $old_time_file"

bootstrap="$(printf '%s\n' \
  '#!/system/bin/sh' \
  'log -t REROOTWAIT "started uid=$(id -u) ctx=$(cat /proc/self/attr/current)"' \
  'while [ "$(getenforce 2>/dev/null)" != Permissive ]; do sleep 1; done' \
  'log -t REROOTWAIT "permissive observed"' \
  "/system/bin/sh $payload_device &" \
  'sleep 3' \
  "setprop persist.sys.saved_time $old_time" \
  'log -t REROOTWAIT "restored=$(getprop persist.sys.saved_time)"')"
bootstrap_b64="$(printf '%s\n' "$bootstrap" | base64 -w0)"
trigger_b64="$(printf '%s' "$trigger" | base64 -w0)"

stage_command="mkdir -p $waiter_dir; chmod 0755 $waiter_dir; printf '%s' '$bootstrap_b64' | toybox base64 -d > $waiter_file; chmod 0644 $waiter_file; setprop persist.sys.saved_time \"\$(printf '%s' '$trigger_b64' | toybox base64 -d)\"; log -t REROOTWAIT \"armed=\$(getprop persist.sys.saved_time)\";"
adb shell < "$repo_dir/scripts/zygote_payload_system_app.sh" >/dev/null
sleep 3
identity="$(printf 'id\nexit\n' | adb shell 'toybox nc -w 3 127.0.0.1 4321' | tr -d '\r')"
case "$identity" in
  *uid=1000*context=u:r:system_app:s0*) : ;;
  *) die "uid-1000 staging listener failed: $identity" ;;
esac

{
  printf '%s\n' "$stage_command"
  printf 'exit\n'
} | adb shell 'toybox nc -w 10 127.0.0.1 4321' >/dev/null

sleep 3
exempt="$(adb shell 'settings get global hidden_api_blacklist_exemptions' | tr -d '\r')"
[ "$exempt" = null ] || die "exemptions cleanup failed: $exempt"
armed="$(adb shell getprop persist.sys.saved_time | tr -d '\r')"
[ "$armed" = "$trigger" ] || die "waiter property was not armed: $armed"

echo "waiter armed; restore_value=$old_time"
echo "reboot before running reroot_after_boot.sh"
