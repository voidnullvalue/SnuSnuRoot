#!/bin/sh
set -eu

if [ "${1:-}" != shell ]; then
    exit 0
fi
shift
command="$*"
case "$command" in
    *'getprop sys.boot_completed'*) echo 1 ;;
    *'settings get global hidden_api_blacklist_exemptions'*) echo null ;;
    *'getprop persist.sys.saved_time'*)
        printf '%s\n' 'x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000'
        ;;
    *'cat /data/local/tmp/__reroot_old_time'*) echo 1788785208143 ;;
    *'logcat -d -v time'*) echo 0 ;;
    *'getprop ro.product.cpu.abilist'*) echo arm64-v8a,armeabi-v7a ;;
    *'toybox od -An -t u1 -N 5'*) echo ' 127 69 76 70 2' ;;
    *'toybox nc -w 3 127.0.0.1 43271'*)
        IFS= read -r request || request=
        case "$request" in
            PING) echo PONG ;;
            ID) echo 'uid=10100 pid=1995 context=u:r:amazon_app:s0 status=Uid:=10100=10100=10100=10100 Gid:=10100=10100=10100=10100 Groups:=3003  elf=ELF64 abi=arm64-v8a jni=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so' ;;
        esac
        ;;
    *'toybox nc -w 6 127.0.0.1 43271'*)
        IFS= read -r request || request=
        [ "$request" = HWBINDER_STATEFUL ]
        echo 'HWBINDER_STATEFUL result=0x40003d0000000000 file=0x0 node=0x0'
        ;;
esac
