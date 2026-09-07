# Runtime artifacts

These files are consumed directly by `runme.sh`; end users do not need an
Android SDK, JDK, NDK, compiler, or a Magisk source checkout.

- `snusnu-persistence.apk`: API-28 direct-boot actor.
- `device/arm64-v8a/magisk`: live Magisk runtime used by the waiter.
- `device/arm64-v8a/magiskpolicy`: matching policy utility.
- `device/arm64-v8a/snusnu_hwbinder_root`: resident hwbinder carrier.
- `device/arm64-v8a/agent.jar`: WebView-zygote initial-root agent.
- `device/arm64-v8a/libcodex_jni.so`: JNI bridge loaded by the agent.
- `device/arm64-v8a/libhwbinder_target.so`: tested initial-root hwbinder target.
- `SHA256SUMS`: integrity manifest checked by `./runme.sh doctor`.

Maintainers can rebuild the APK with
`SNUSNU_REBUILD_APP=1 ./runme.sh arm`. The checked-in APK remains the default
installation artifact so normal use never invokes host build tools.
