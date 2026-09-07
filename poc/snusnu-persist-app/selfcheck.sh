#!/bin/sh
set -eu

app_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(CDPATH= cd -- "$app_dir/../.." && pwd)"
apk="$app_dir/build/snusnu-persistence.apk"
aapt2="/home/void/Android/Sdk/build-tools/37.0.0/aapt2"
apksigner="/home/void/Android/Sdk/build-tools/37.0.0/apksigner"

"$app_dir/build.sh" >/dev/null
"$apksigner" verify --min-sdk-version 28 "$apk"
badging=$("$aapt2" dump badging "$apk")
printf '%s\n' "$badging" | grep -q "package: name='io.github.voidnullvalue.snusnuroot.persistence'"
printf '%s\n' "$badging" | grep -q "minSdkVersion:'28'"
printf '%s\n' "$badging" | grep -q "uses-permission: name='android.permission.WRITE_SECURE_SETTINGS'"

carrier="$repo_dir/poc/hwbinder-secctx-exploit/build/controlled_target"
[ -x "$carrier" ]
strings "$carrier" | grep -q '^stateful-root$'
strings "$carrier" | grep -q '^stateful-root-hold$'
strings "$carrier" | grep -q 'HWBINDER_STATEFUL_WRITE result='

policy="$repo_dir/tools/policy.conf"
grep -q '^allow system_app hwbinder_device:chr_file .* open' "$policy"
grep -q '^allow system_app hwservicemanager:binder .* call' "$policy"
grep -q '^allow system_app hidl_token_hwservice:hwservice_manager .* find' "$policy"
grep -q '^allow system_app self:process .* setsched' "$policy"
grep -q '^allow system_app system_data_file:file .* execute' "$policy"

binder="$repo_dir/source/kernel_src/kernel/mediatek/mt8183/4.4/drivers/android/binder.c"
grep -q 'extra_buffers_size += ALIGN(secctx_sz, sizeof(u64));' "$binder"
if grep -A4 -B4 'extra_buffers_size += ALIGN(secctx_sz' "$binder" | grep -q 'extra_buffers_size <'; then
    echo "unexpected binder overflow guard present" >&2
    exit 1
fi

echo "SELF_CHECK_OK apk+abi+policy+kernel prerequisites"
