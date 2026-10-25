# Root on Fire HD 10 (trona, 11th gen) — full documentation

Device: **Fire HD 10 (11th gen, "trona" / KFTRWI)**, MT8183, Android 9 (API 28),
FireOS **7.3.3.1 (PS7331.4460N, incremental 0031575862404)**, serial
`G001KT0511960U8G`.

Verified result: the direct-boot actor restores SELinux Permissive, a loopback
root shell as **uid 0, `u:r:time_update:s0`** on `127.0.0.1:4325`, and Magisk.
Exiting the original standalone hwbinder carrier caused an MTK `watchdog_sw`
reset; the fixed carrier retains its binder objects for the boot. A fully
automatic reboot then remained stable beyond the observed watchdog window.
No boot image or read-only partition is modified.

---

## 1. Architecture — four primitives chained

### P1. CVE-2024-31317 — Zygote `hidden_api_blacklist_exemptions` injection
Affects FireOS 7 / Android 9–11 (pre-A12 simple-payload variant). The
`settings put global hidden_api_blacklist_exemptions "...payload..."` value is
parsed by system_server and handed to zygote; the embedded complete spawn
command (`--runtime-args ... --setuid=<UID> --seinfo=<SEINFO> --invoke-with
<cmd>;`) makes zygote fork a child running our command with the chosen uid and
SELinux seinfo.

Constraints (hard-won, see `notes/uid1000-method.md`):
- **One-shot per boot.** Only the FIRST exception-set after boot reaches the
  wrapper-exec path; all later attempts die in `RuntimeInit.parseArgs`. Before
  injecting, check logcat wiring: `no zygote connection` at boot = channel
  dead for the session (reboot).
- **uid 0 is rejected** by zygote (`Failed to set API blacklist
  exemptions` + EOFException). Ceiling of the direct injection: uid 1000
  (`u:r:system_app:s0`) — used for staging, or uid 10100 (`amazon_app`) — used
  as carrier.
- `settings delete` immediately after `put` is the bootloop guard: the crafted
  value must never survive; verify `settings get ... = null` before and after.

### P2. amazon_app JNI carrier + hwbinder leak/write (in-memory kwrite)
The one-shot injection spawns a child as **uid 10100
(`u:r:amazon_app:s0`)**. Its wrapper executes `/system/bin/app_process64` and
runs the carrier agent from
`/data/securedStorageLocation/codex.amazon.jni.v51/agent.jar`.

The agent exposes a small socket protocol on `127.0.0.1:43271`:

| command | meaning |
| --- | --- |
| `PING` | → `PONG` (liveness) |
| `ID` | → uid/pid/SELinux context identity |
| `HWBINDER_STATEFUL` | kernel-side leak step. Success = `result=0x5000000000000000` |
| `HWBINDER_STATEFUL_WRITE` | write step. Success = `result=0x51...` ; writes NULL to `selinux_enforcing` → SELinux goes Permissive (in-memory; reverts on reboot) |

The leak result byte `0x50` is a per-boot one-shot: once spent (`0x40...`,
ENODATA/EALREADY), only a full kernel reboot clears it. A respawned carrier
cannot rebind the abstract socket and uid-2000 shell cannot kill the uid-10100
carrier, so a failed leak means "this boot is spent".

#### Carrier ABI handling

Device ABI support does not describe a process ABI. A 64-bit-capable Android
device can run a 32-bit WebView provider, whose WebView zygote and children are
therefore ELF32. Loading the former single ELF64 `libhwbinder_target.so` in
that child produced `UnsatisfiedLinkError: ... is 64-bit instead of 32-bit`.

Both `arm64-v8a` and `armeabi-v7a` JNI targets are now built and staged. The
stateful primitive cannot safely run through Android's 32-bit Binder compat
ABI: `binder_uintptr_t` is 32 bits there, but this stage returns and compares
64-bit kernel pointers and writes a fixed 64-bit kernel address. The ELF32
build therefore reports stage `0x4f`/`EOPNOTSUPP` before opening hwbinder or
spending boot-scoped state.

The carrier launcher avoids that path deterministically. The injected
`amazon_app` child executes `/system/bin/app_process64` and starts the same
agent main class directly. Before `HWBINDER_STATEFUL`, the agent reads its own
`/proc/self/exe` ELF header, selects the ABI-suffixed JNI payload, and reports
that exact path. The host verifies its ELF header and requires an ELF64/ELF64
match. UID 10100, supplementary group 3003, and
`u:r:amazon_app:s0` are still checked from the live agent response.

ABI diagnostics include `device_supported_abis`, `carrier_pid`, the carrier
UID/context, `carrier_abi`, `carrier_elf_class`, `selected_jni_library`, and
`native_elf_class`. `UNKNOWN` means `/proc` or the payload was unreadable;
`selected JNI payload does not match carrier` means staging is stale or the
carrier changed ABI. These checks happen before the one-shot Binder command,
so correcting the assets does not conceal a spent primitive.

Healthy output on trona resembles:

```text
device_supported_abis=arm64-v8a,armeabi-v7a,armeabi
carrier_pid=1234 ... context=u:r:amazon_app:s0 ... Groups:=3003
carrier_abi=arm64-v8a carrier_elf_class=ELF64
selected_jni_library=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so selected_elf_class=ELF64
native_library=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so native_elf_class=ELF64
```

If either class is `UNKNOWN`, check access to `/proc/self/exe` or restage the
assets. A class mismatch names both classes and exits before issuing
`HWBINDER_STATEFUL`.

The carrier `ID` response is machine-readable (`IDV2` plus tab-separated
`key=value` fields). Host parsing validates UID, PID, SELinux context, each
supplementary group as an exact number, ELF class, ABI, and JNI path
independently. The host also accepts the earlier human-readable response so
already-staged carriers can be diagnosed without a false group failure.

Phase B failures carry a class-specific exit status. Validation and other
pre-exploit failures stop without claiming the boot's Binder primitive was
spent. Only a failed stateful leak permits an automatic fresh-boot retry. On
trona, `time_update` may consume and normalize the armed property to a numeric
timestamp during that boot; retry handling therefore uses a dedicated staging
boot to re-arm it before rebooting again for Phase B. Numeric or invalid waiter
state at the start of Phase B now aborts immediately.

Phase A also reuses an already-validated UID-1000 staging listener. Injecting
a second listener after asset installation can leave a delayed one-shot
request that wins the next boot's race and prevents the `amazon_app` carrier
from starting. Asset replacement is followed by `sync`, so an unexpected
reboot cannot leave a zero-length or partially installed carrier payload.

### P3. time_update property-trigger waiter (boot-time uid-0 handoff)
`persist.sys.saved_time` is read by Amazon's `time_update` service at boot;
the value is parseable as `time -s <value>` syntax (command-injection via
`[$(...)]`). When armed with

```
x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000
```

the bootstrap `w/b` runs as **uid 0, `u:r:time_update:s0`** ~30s into boot. It
waits until P2 makes SELinux Permissive, starts the root listener, and restores
the live Magisk runtime. On 4460N the trigger remains armed after consumption;
the UID-1000 actor verifies it and restores it if necessary.

### P4. installed boot actor (v2 persistence)

`io.github.voidnullvalue.snusnuroot.persistence` receives locked/normal boot
and uses its persistently granted development permission
`WRITE_SECURE_SETTINGS` to create the proven UID-1000 channel. The child
verifies re-arm first, waits for completed boot plus five seconds, then executes
the stateful hwbinder carrier from `/data/snusnu_hwbinder_root` in
`system_app` (the verified 24-byte SID geometry). Transient `ENODATA` failures
are recorded but never request an automatic reboot; the tablet stays usable
and a later user-initiated reboot can try again.

---

## 2. Initial-root assets on device

```
/data/securedStorageLocation/codex.amazon.jni.v51/
    agent.jar              # amazon_app socket agent (43271 protocol above)
    libcodex_jni.so        # JNI binder/hwbinder glue
    libhwbinder_target.so  # target service glue
    oat/
/data/securedStorageLocation/w/b        # time_update bootstrap (uid-0 waiter)
/data/local/tmp/__reroot_old_time       # numeric restore snapshot (safety)
/data/snusnu_hwbinder_root              # root:system 0750, system_data_file
/data/securedStorageLocation/snusnu/
    waiter.sh                           # waits for Permissive, restores runtime
    magisk_restore.sh
    state/retry_count                   # synced failed-boot diagnostic counter
    magisk/
```

`scripts/stage_initial_root_assets.sh` installs these from the checked-in
prebuilt artifacts through the UID-1000 channel. `runme.sh root` invokes it
automatically before the first reboot; repeated runs verify hashes and make no
changes when the files are already current.

## 3. Scripts (entry points)

| script | role |
| --- | --- |
| `runme.sh` | Top-level `arm`, `status`, `verify`, and `disarm`, plus host fallbacks. |
| `scripts/root_poc.sh` | Full PoC driver — staging-if-needed → reboot → root chain, plus cleanup subcommand. |
| `scripts/stage_initial_root_assets.sh` | Idempotently installs and verifies the agent/JNI/hwbinder files required by phase B. |
| `scripts/stage_reroot_waiter.sh <payload>` | Phase A: consumes the boot's one-shot to install `w/b` and arm `persist.sys.saved_time`. Ends with "waiter armed; reboot". |
| `scripts/reroot_after_boot.sh <payload>` | Phase B: runs P2 (leak → write → Permissive) and confirms P3 handoff + root service on 4325. |
| `scripts/snusnu_waiter.sh` | Device-side UID-0 waiter and root/Magisk restoration. |
| `poc/snusnu-persist-app/` | API-28 direct-boot APK, native hwbinder payload, build and self-check. |
| `scripts/snusnu_magisk_device_restore.sh` | Device-side live-Magisk reconstruction (`start`/`status`/`stop`, `__SNU_MAGISK_OK__` marker), staged at `/data/securedStorageLocation/snusnu/magisk_restore.sh`. |
| `scripts/webview_zygote_preload_client.py` | Sends the 5-field WebView-zygote preload command. |
| `scripts/zygote_payload_system_app.sh` | uid-1000 one-shot payload used by staging. |

### 3.5 Autonomous reroot v2

`./runme.sh arm` requires the current UID-0 SnusnuRoot foothold so it can place
and label the system-domain carrier. It installs/grants the boot actor, clears
its stopped state, stages waiter/Magisk files, resets the durable retry count,
and arms the saved-time trigger. Later boots run entirely on-device. Exact
native results and recovery state are exposed by `runme.sh status`.

## 4. Usage

```bash
cd SnuSnuRoot
./runme.sh doctor           # checks host and all shipped runtime artifacts
adb devices                 # expect one authorized device

# One-shot, end-to-end (recommended):
scripts/root_poc.sh

# Install persistence after the initial root, then prove re-arm twice:
./runme.sh arm
adb reboot
./runme.sh verify
adb reboot
./runme.sh verify

# Manual phases:
scripts/stage_reroot_waiter.sh /tmp/opencode/rootsvc_payload.sh   # once only
adb reboot                                                        # (physical if wedged)
scripts/reroot_after_boot.sh   /tmp/opencode/rootsvc_payload.sh   # per boot
```

The persistence lifecycle uses checked-in APK, Magisk, ARM64 carrier, and ADB
artifacts. It does not need an Android SDK, JDK, NDK, compiler, Magisk source
checkout, or distro-specific package command. A system `adb` is preferred; on
x86_64 the bundled loader and libraries also run on musl distributions. On a
non-x86_64 Linux host, install platform-tools or set `ADB=/path/to/adb`. Set
`ANDROID_SERIAL` when more than one device is connected. APK rebuilding is an
explicit maintainer operation: `SNUSNU_REBUILD_APP=1 ./runme.sh arm`.

On success:
```
== 7/7 exit-state guard ==
saved_time still armed -> persistent-root waiter re-fires every boot
exemptions=null
enforce=Permissive
OK reroot flow complete

root service: uid=0(root) context=u:r:time_update:s0 on 127.0.0.1:4325
   try: printf 'id\nexit\n' | adb shell 'toybox nc -w 3 127.0.0.1 4325'
```

Verify root:
```
printf 'id\nexit\n' | adb shell 'toybox nc -w 3 127.0.0.1 4325'
-> uid=0(root) gid=1000(system) groups=... context=u:r:time_update:s0
```

## 5. Safety invariants / gotchas

1. **`hidden_api_blacklist_exemptions` must always return to `null`.** The
   PoC checks before/after; a left-set value = soft bootloop.
2. **One-shot per boot** for injection (P1) and leak (P2). Don't re-run
   staging while armed; don't burn the leak if you aren't ready for the write.
3. **EALREADY (0x40...) on leak**: boot is spent; reboot physically if `adb
   reboot` is ignored (device can wedge at high load; power-hold works).
4. **`time_update` cannot re-arm itself.** The v2 app spends P1 on a UID-1000
   child and re-arms through that child before attempting the kernel write.
   Disable the installed v2 boot actor before manually validating
   `root_poc.sh`; otherwise its expected `snusnu-persist-system` child consumes
   P1 before the manual `amazon_app` carrier can start.
5. **Payload lifecycle**: everything is on `/data`; the durable pieces are the
   installed boot actor, `/data/snusnu_hwbinder_root`,
   `/data/securedStorageLocation/w/b`, and `snusnu/`.
6. **Kernel write reverts on reboot** (in-memory NULL-write to
   selinux_enforcing). Persistence comes from the boot actor's re-arm plus the
   waiter, not from the write.

## 6. Cleanup / revert

`./runme.sh disarm` disables and removes the APK, reboots once to obtain a
fresh P1 one-shot, restores the numeric saved-time snapshot through UID 1000,
and removes the staged waiter/runtime files.

---

## 7. Verified evidence (this project)

- `notes/uid1000-method.md` — P1 verification (uid 1000 channel).
- `notes/handoff.md` — full-append continuation; stage-7 accept-armed fix;
  root pid/uid verification log.
- Success transcript logs: `/tmp/opencode/stage_run.log`,
  `/tmp/opencode/lottery_run.log`.
