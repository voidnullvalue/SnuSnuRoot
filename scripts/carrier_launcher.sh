#!/system/bin/sh
set -eu

asset_dir=/data/securedStorageLocation/codex.amazon.jni.v51
app_process=/system/bin/app_process64
main_class=com.android.webview.chromium.WebViewChromiumFactoryProviderForP

if [ ! -x "$app_process" ]; then
    echo "SNU_ABI_ERROR: app_process64 is unavailable" >&2
    exit 70
fi
export CLASSPATH="$asset_dir/agent.jar"
exec "$app_process" /system/bin "$main_class"
