#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_dir/scripts/firmware_compat.sh"
manifest="$repo_dir/firmware/manifest.psv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

adb() {
    [ "$1" = shell ] && [ "$2" = getprop ] || return 1
    case "$3" in
        ro.product.device) printf '%s\n' "$device" ;;
        ro.build.id) printf '%s\n' "$build" ;;
        ro.build.version.incremental) printf '%s\n' "$incremental" ;;
        ro.build.fingerprint) printf '%s\n' "$fingerprint" ;;
        *) return 1 ;;
    esac
}
expect_pass() {
    snusnu_firmware_require "$manifest" >"$tmp/output" 2>&1 || {
        cat "$tmp/output"; echo "FAIL: expected verified firmware" >&2; exit 1;
    }
}
expect_reject() {
    if snusnu_firmware_require "$manifest" >"$tmp/output" 2>&1; then
        cat "$tmp/output"; echo "FAIL: unsupported firmware was accepted" >&2; exit 1
    fi
    grep -q "refusing to stage" "$tmp/output" || {
        cat "$tmp/output"; echo "FAIL: rejection reason missing" >&2; exit 1;
    }
}

device=trona
build=PS7331.4460N
incremental=0031575862404
fingerprint=Amazon/trona/trona:9/PS7331.4460N/0031575862404:user/amz-p,release-keys
expect_pass

# Same build ID, different incremental must not accept the prebuilt.
incremental=0031575862405
expect_reject
incremental=0031575862404

# Both the build ID and fingerprint are checked; mismatches fail closed.
build=PS7329.3842N
expect_reject
fingerprint=Amazon/trona/trona:9/PS7329.3842N/redacted:user/amz-p,release-keys
expect_reject
build=PS7331.4460N
fingerprint=Amazon/other/other:9/PS7331.4460N/0031575862404:user/amz-p,release-keys
expect_reject

# Missing ADB data, unknown builds/devices, wildcard evidence rows.
fingerprint=''
expect_reject
device=other
build=PS7331.4460N
fingerprint=Amazon/other/other:9/PS7331.4460N/0031575862404:user/amz-p,release-keys
expect_reject
device=trona
build=PS7326.3178N
fingerprint=Amazon/trona/trona:9/PS7326.3178N/redacted:user/amz-p,release-keys
expect_reject

# Duplicate/overlapping matches must not accidentally select a payload.
build=PS7331.4460N
fingerprint=Amazon/trona/trona:9/PS7331.4460N/0031575862404:user/amz-p,release-keys
printf '%s\n' 'trona|PS7331.4460N|0031575862404|verified|prebuilt|duplicate' >> "$tmp/dupe"
cat "$manifest" >> "$tmp/dupe"
if snusnu_firmware_require "$tmp/dupe" >"$tmp/output" 2>&1; then
    echo "FAIL: ambiguous manifest was accepted" >&2; exit 1
fi
echo "PASS: exact-build firmware fail-closed checks"
