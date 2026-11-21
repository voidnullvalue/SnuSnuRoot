<p align="center">
  <img src="assets/snusnuroot-logo.svg" alt="SnuSnuRoot logo" width="400">
</p>

# SnuSnuRoot

Self-contained toolkit to root a Fire HD 10 (trona / PS7331.4460N) over adb and
install a working Magisk userspace + manager — all in one run, without touching
/boot or the underlying /system filesystem.

## Reported firmware compatibility

SnuSnuRoot was originally developed for the **Fire HD 10 (2021, KFTRWI / trona)** on **PS7331.4460N**. Other builds have been reported working, but a successful root does **not** establish that the bundled payload supports the build unchanged or that unattended persistence is reliable.

| Fire OS build | Reported result | Evidence and limitations |
| --- | --- | --- |
| **PS7331.4460N** (Fire OS 7.3.3.1) | Original documented root target | See [root.md](root.md). |
| **PS7331.4463N** (Fire OS 7.3.3.1) | Independent UID 0 and MagiskSU success; warm-reboot persistence demonstrated with local fixes | [Detailed independent test report](https://github.com/voidnullvalue/SnuSnuRoot/pull/1#issuecomment-5983315838) (first native attempt missed; cold starts **not tested** in that report). [PR #1](https://github.com/voidnullvalue/SnuSnuRoot/pull/1) also reports persistence across power cycles. [Issue #4](https://github.com/voidnullvalue/SnuSnuRoot/issues/4) reports an older revision working but intermittent missing Magisk `su`, and a newer firmware safety gate rejecting this build. [Issue #5](https://github.com/voidnullvalue/SnuSnuRoot/issues/5) contains an additional HD 10 Plus write-up and files. |
| **PS7331.4463N** (Fire OS 7.3.3.1), contributed fork | Unattended persistence independently reported with changes beyond upstream SnuSnuRoot | [Contributor's report](https://github.com/voidnullvalue/SnuSnuRoot/issues/6) documents three warm and two power-off boots (5/5) using a separate, modified [persistence implementation](https://github.com/acari-git/firehd10-persistent-root). **Not evidence that the stock upstream actor passes those tests.** |
| **PS7329.3842N** (Fire OS 7.3.2.9) | Full root chain demonstrated on trona with a **firmware-specific rebuilt native carrier** | [PR #2 and verification evidence](https://github.com/voidnullvalue/SnuSnuRoot/pull/2). The shipped PS7331 carrier uses a different SELinux address and is **not** validated for this build; no general unattended persistence claim is made. |

A [firmware address table in PR #2](https://github.com/voidnullvalue/SnuSnuRoot/pull/2) also mentions **PS7326.3178N**, but that is **not** a demonstrated end-to-end SnuSnuRoot success and is not listed as a working build.

**Before attempting a root:** check your exact device build and the repository's current firmware-compatibility checks. A historical report using a specific commit, local patch, or rebuilt payload is **not** an endorsement of running current HEAD or the shipped binaries on that build. Kernel-write targets are firmware-specific; guessing them can damage the device, and there is no established reliable Trona unbrick procedure.

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

3. **Reboot persistence** (`runme.sh arm`)
   - Installs a direct-boot actor that regains the UID-1000 system-app channel,
     runs the hwbinder primitive from a resident carrier, and restores UID 0,
     Permissive SELinux, and Magisk after every normal reboot.
   - Does not modify boot, recovery, system, vendor, RPMB, or verified-boot
     state. Native misses fail open without requesting another reboot.

## Layout

```
runme.sh                  single entry point
prebuilt/                 signed boot actor, Magisk runtime, resident carrier
poc/snusnu-persist-app/   direct-boot actor source and maintainer build script
scripts/
  root_poc.sh             full root driver (root|status|disarm)
  stage_reroot_waiter.sh  arm the boot waiter (pre-reboot)
  reroot_after_boot.sh    per-boot reroot chain
  rootsvc_payload.sh      uid-0 listener payload
  zygote_payload_system_app.sh
  webview_zygote_preload_client.py
  snusnu_magisk_bootstrap.sh   Phase 1 /sbin runtime
  snusnu_magisk_manager.sh     Phase 2 Manager integration
  snusnu_boot_entry.sh         UID-0 boot entry
  snusnu_waiter.sh             root/Magisk restoration waiter
magisk/
  out/app-release.apk          Manager APK (com.topjohnwu.magisk, 30700)
  native/out/arm64-v8a/        magisk, magiskpolicy, magiskboot, magiskinit, libinit-ld.so
  .snusnu-revision             build revision the APK/binaries were produced from
tools/xbps-root/usr/           minimal adb + transitive shared-library closure
```

## Quick start

```sh
git clone https://github.com/voidnullvalue/SnuSnuRoot.git
cd SnuSnuRoot
./runme.sh status      # confirm adb device + current state
./runme.sh root        # stage waiter, reboot, reroot (uid-0 on 127.0.0.1:4325)
./runme.sh bootstrap   # live Magisk runtime on /sbin
./runme.sh manager     # install + launch Magisk Manager
./runme.sh request     # trigger an adb-shell su request; tap Allow on the tablet
./runme.sh status      # verify: Manager installed, daemon version, policies

# Install and verify automatic reboot persistence after root is active:
./runme.sh doctor
./runme.sh arm
adb reboot
./runme.sh verify
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

## License and Magisk source

SnuSnuRoot is distributed under the **GNU General Public License v3.0**; see
[`LICENSE`](LICENSE).

This repository also redistributes Magisk APK/native artifacts built from
`topjohnwu/Magisk`, which is GPL-3.0 licensed. The bundled artifacts correspond
to the exact upstream revision recorded in `magisk/.snusnu-revision`:

`8c4341e9288360010495a2bc3b46fd2e3f505f9f` — Magisk v31.0 release preparation.

Corresponding source for that revision is available from:

https://github.com/topjohnwu/Magisk/tree/8c4341e9288360010495a2bc3b46fd2e3f505f9f

The Magisk project and its copyrights remain with their respective upstream
copyright holders. SnuSnuRoot's own modifications, scripts, and integration
code are likewise distributed under GPL-3.0.

## Requirements

- Linux host. Persistence use needs no SDK, JDK, NDK, compiler, or Magisk
  source checkout. On x86_64, the bundled ADB runtime works on glibc and musl;
  other host architectures must provide `ADB=/path/to/adb`.
- The initial host-driven root fallback additionally uses `python3`.
- Fire HD 10 with USB debugging enabled and an authorized adb host.


## PS7329.3842N (Fire OS 7.3.2.9) verification

A full-chain verification of this toolchain on the older PS7329.3842N build —
including the corrected `selinux_enforcing` address (`0xffffff800996d668`) and
the per-build address-recovery pipeline — is documented in
[docs/PS7329-3842N-verification.md](docs/PS7329-3842N-verification.md) and
[docs/ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md). The shipped `prebuilt/` binaries
target PS7331.4460N only; PS7329 users must rebuild the JNI carrier per the
verification doc.
