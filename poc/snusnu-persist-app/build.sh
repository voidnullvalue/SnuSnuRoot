#!/bin/sh
set -eu

app_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(CDPATH= cd -- "$app_dir/../.." && pwd)"
build_dir="$app_dir/build"
work_dir="$(mktemp -d "$build_dir.work.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

find_sdk_file() {
    sdk_pattern="$1"
    for sdk_root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
            "${HOME:-}/Android/Sdk"; do
        [ -d "$sdk_root" ] || continue
        # SDK directories are version-named and shell glob order is stable;
        # retaining the last match selects the newest installed tool.
        for sdk_candidate in $sdk_root/$sdk_pattern; do
            [ -f "$sdk_candidate" ] && sdk_result="$sdk_candidate"
        done
    done
    [ -n "${sdk_result:-}" ] && printf '%s\n' "$sdk_result"
}

resolve_tool() {
    explicit="$1"
    tool_name="$2"
    sdk_pattern="$3"
    if [ -n "$explicit" ]; then printf '%s\n' "$explicit"; return; fi
    if command -v "$tool_name" >/dev/null 2>&1; then
        command -v "$tool_name"
        return
    fi
    find_sdk_file "$sdk_pattern"
}

android_jar="${ANDROID_JAR:-$(find_sdk_file 'platforms/*/android.jar')}"
aapt2="$(resolve_tool "${AAPT2:-}" aapt2 'build-tools/*/aapt2')"
d8="$(resolve_tool "${D8:-}" d8 'build-tools/*/d8')"
apksigner="$(resolve_tool "${APKSIGNER:-}" apksigner 'build-tools/*/apksigner')"

for java_tool in javac jar keytool; do
    command -v "$java_tool" >/dev/null 2>&1 \
        || { echo "missing JDK tool: $java_tool" >&2; exit 1; }
done
for required in "$android_jar" "$aapt2" "$d8" "$apksigner"; do
    [ -f "$required" ] || { echo "missing Android SDK build input: $required" >&2; exit 1; }
done

mkdir -p "$work_dir/classes" "$work_dir/dex" "$build_dir"
javac -source 8 -target 8 -classpath "$android_jar" -d "$work_dir/classes" \
    "$app_dir/src/io/github/voidnullvalue/snusnuroot/persistence/BootstrapActivity.java" \
    "$app_dir/src/io/github/voidnullvalue/snusnuroot/persistence/BootReceiver.java" \
    "$app_dir/src/io/github/voidnullvalue/snusnuroot/persistence/PersistenceService.java"
jar cf "$work_dir/classes.jar" -C "$work_dir/classes" .
"$d8" --min-api 28 --output "$work_dir/dex" "$work_dir/classes.jar"

"$aapt2" link -o "$work_dir/unsigned.apk" -I "$android_jar" \
    --manifest "$app_dir/AndroidManifest.xml" --min-sdk-version 28 --target-sdk-version 28
jar uf "$work_dir/unsigned.apk" -C "$work_dir/dex" classes.dex

keystore="${SNUSNU_KEYSTORE:-$app_dir/signing/snusnu-debug.keystore}"
if [ ! -f "$keystore" ]; then
    mkdir -p "$(dirname -- "$keystore")"
    keytool -genkeypair -keystore "$keystore" -storepass android -keypass android \
        -alias androiddebugkey -dname 'CN=Android Debug,O=Android,C=US' \
        -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
fi
"$apksigner" sign \
    --min-sdk-version 28 --v1-signing-enabled true \
    --v2-signing-enabled true --v3-signing-enabled false \
    --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
    --out "$build_dir/snusnu-persistence.apk" "$work_dir/unsigned.apk"
"$apksigner" verify --verbose \
    "$build_dir/snusnu-persistence.apk"
sha256sum "$build_dir/snusnu-persistence.apk"
