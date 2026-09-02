<p align="center">
  <img src="assets/snusnuroot-logo.svg" alt="SnuSnuRoot logo" width="400">
</p>

# SnuSnuRoot

Self-contained toolkit to root a Fire HD 10 (trona / PS7331.4460N) over adb and
install a working Magisk userspace + manager — all in one run, without touching
/boot or the underlying /system filesystem.

## What it does

Everything runs from the host over adb. Two stages, both reversible in one boot:

1. **Root chain** (`runme.sh root`)
   - Arms the verified boot-time `time_update` parser (`persist.sys.saved_time`)
     with a waiter via the boot's single zygote injection.
   - Reboots; on the fresh boot the carrier is respawned through
     WebViewZygoteInit, the hwbinder stateful leak + NULL write drop SELinux to
     Permissive, then the pre-armed waiter launches the payload and restores
     the original numeric `saved_time`.
   - End state: a uid-0 listener on `127.0.0.1:4325` (`u:r:time_update:s0`).

2. **Magisk userspace** (`runme.sh bootstrap` then `runme.sh manager`)
   - `bootstrap` mounts a Magisk tmpfs on `/sbin` (original entries preserved
     via bind mounts), applies a live SELinux policy, starts `magiskd`, and
     binds the Manager's `trusted_cert` from the staged stub APK *before* any su
     test, so a cold daemon can never uninstall the Manager.
   - `manager` stages the matching stub + BusyBox, runs `--post-fs-data`,
     installs the Manager APK, runs `--service` / `--boot-complete`, and
     launches the app.

## Layout

```
runme.sh                  single entry point
scripts/
  root_poc.sh             full root driver (root|status|disarm)
  stage_reroot_waiter.sh  arm the boot waiter (pre-reboot)
  reroot_after_boot.sh    per-boot reroot chain
  rootsvc_payload.sh      uid-0 listener payload
  zygote_payload_system_app.sh
  webview_zygote_preload_client.py
  snusnu_magisk_bootstrap.sh   Phase 1 /sbin runtime
  snusnu_magisk_manager.sh     Phase 2 Manager integration
magisk/
  out/app-release.apk          Manager APK (com.topjohnwu.magisk, 30700)
  native/out/arm64-v8a/        magisk, magiskpolicy, magiskboot, magiskinit, libinit-ld.so
  .snusnu-revision             build revision the APK/binaries were produced from
tools/xbps-root/usr/           minimal adb + transitive shared-library closure
```

## Quick start

```sh
git clone git@github.com:voidnullvalue/SnuSnuRoot.git
cd SnuSnuRoot
./runme.sh status      # confirm adb device + current state
./runme.sh root        # stage waiter, reboot, reroot (uid-0 on 127.0.0.1:4325)
./runme.sh bootstrap   # live Magisk runtime on /sbin
./runme.sh manager     # install + launch Magisk Manager
./runme.sh request     # trigger an adb-shell su request; tap Allow on the tablet
./runme.sh status      # verify: Manager installed, daemon version, policies
```

Once the Manager is up it reports Magisk installed/up-to-date (the Home card's
"Reinstall" button is the *installed* state indicator) and MagiskSU GUI
authorization works per-app.

## Notes & safety

- **Do not reboot after disarm.** Root is an in-memory per-boot chain;
  `persist.sys.saved_time` returning to a plain numeric value means the waiter
  is disarmed and the next boot is stock.
- The device kernel has no mount namespaces (`CONFIG_NAMESPACES` unset), so
  the `/sbin` tmpfs is system-global and visible to ordinary adb shell too.
- Payloads reference on-device paths (`/data/securedStorageLocation/...`,
  `/data/local/tmp/...`); they are re-created at runtime.
- Prebuilt only: no Magisk source is shipped. `snusnu_magisk_manager.sh`
  verifies artifacts against `magisk/.snusnu-revision`; rebuilding requires
  the full `topjohnwu/magisk` checkout and build environment.

## Requirements

- Linux host with `adb` (the bundled one is used automatically), `unzip`,
  `base64`, `python3`.
- Fire HD 10 with USB debugging enabled and an authorized adb host.