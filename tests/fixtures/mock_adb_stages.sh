#!/bin/sh
set -eu
[ -z "${MOCK_ADB_LOG:-}" ] || printf 'CALL %s\n' "$*" >>"$MOCK_ADB_LOG"
case "${1:-}" in
    devices)
        printf 'List of devices attached\nmock-device\tdevice\n'
        exit 0 ;;
    wait-for-device|reboot|get-state)
        [ "${1:-}" = get-state ] && echo device
        exit 0 ;;
    shell) shift ;;
    *) exit 0 ;;
esac
command="$*"
case "$command" in
    *'/proc/sys/kernel/random/boot_id'*) echo "${MOCK_BOOT_ID:-boot-a}" ;;
    *'getprop sys.boot_completed'*) echo 1 ;;
    *'getprop ro.product.device'*) echo "${MOCK_FW_DEVICE:-trona}" ;;
    *'getprop ro.build.id'*) echo "${MOCK_FW_BUILD:-PS7331.4460N}" ;;
    *'getprop ro.build.version.incremental'*) echo "${MOCK_FW_INCREMENTAL:-0031575862404}" ;;
    *'getprop ro.build.fingerprint'*) echo "${MOCK_FW_FINGERPRINT:-Amazon/trona/trona:9/PS7331.4460N/0031575862404:user/amz-p,release-keys}" ;;
    *'getprop persist.sys.saved_time'*) printf '%s\n' "${MOCK_SAVED_TIME:-x[\$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000}" ;;
    *'settings get global hidden_api_blacklist_exemptions'*) echo null ;;
    *'settings get global snusnu_persist_enabled'*) echo "${MOCK_PERSIST_ENABLED:-0}" ;;
    *'getprop ro.product.cpu.abilist'*) echo arm64-v8a,armeabi-v7a ;;
    *'toybox od -An -t u1 -N 5'*) echo " ${MOCK_ELF_BYTES:-127 69 76 70 2}" ;;
    *'getenforce'*) echo "${MOCK_SELINUX:-Permissive}" ;;
    *'toybox nc -w 3 127.0.0.1 43271'*)
        IFS= read -r request || request=
        [ -z "${MOCK_ADB_LOG:-}" ] || echo "REQUEST=$request" >>"$MOCK_ADB_LOG"
        case "$request" in
            PING) [ "${MOCK_CARRIER_UP:-yes}" = yes ] && echo PONG ;;
            ID) printf '%s\n' "${MOCK_IDENTITY:-uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Groups: 3003  elf=ELF64 abi=arm64-v8a jni=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so}" ;;
        esac ;;
    *'toybox nc -w 6 127.0.0.1 43271'*)
        IFS= read -r request || request=
        [ -z "${MOCK_ADB_LOG:-}" ] || echo "REQUEST=$request" >>"$MOCK_ADB_LOG"
        case "$request" in
            HWBINDER_STATEFUL) echo "${MOCK_LEAK_RESULT:-result=0x5000000000000000}" ;;
            HWBINDER_STATEFUL_WRITE) echo "${MOCK_WRITE_RESULT:-result=0x5100000000000000}" ;;
        esac ;;
    *'toybox nc -w 2 127.0.0.1 4325'*)
        IFS= read -r request || request=
        case "$request" in id*) printf '0\nu:r:time_update:s0\n' ;; esac ;;
    *'test -S /sbin/.magisk/device/socket'*) echo "${MOCK_MAGISK:-not_ready}" ;;
    *'sed -n '*'snusnu-state'*) : ;;
    *) : ;;
esac

