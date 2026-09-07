# SnuSnuRoot reboot persistence v2

Tested on trona/KFTRWI, PS7331.4460N (FireOS 7.3.3.1), 2026-09-06.

## Mechanism

`runme.sh arm` requires the current SnusnuRoot UID-0 foothold. It installs the
API-28 direct-boot actor `io.github.voidnullvalue.snusnuroot.persistence`,
grants the development permission `WRITE_SECURE_SETTINGS`, stages the waiter
and Magisk files, and installs `/data/snusnu_hwbinder_root` as
`root:system 0750`, `system_data_file`.

At locked boot the actor spends CVE-2024-31317 once to start a UID-1000
`system_app` shell. That process:

1. verifies/re-arms the persistent `saved_time` trigger;
2. waits for `sys.boot_completed=1` plus five seconds;
3. runs the stateful hwbinder leak/write from the verified 24-byte SID domain
   and leaves the carrier resident so binder cleanup cannot tear down the UAF;
4. records exact native results and resets the retry count on success.

The pre-armed `time_update` command runs as UID 0, waits for Permissive, starts
the loopback root shell on 4325, and restores live Magisk. The trigger remains
armed on this firmware. A transient `ENODATA` grooming miss is recorded in a
synced on-disk counter but never requests an automatic reboot. The tablet stays
booted and usable; a later user-initiated reboot can try again.

No boot, recovery, system, vendor, RPMB, or verified-boot state is modified.

## Exact-device results

- Clean lifecycle: disarm restored numeric `saved_time`, removed the package,
  helpers, and carrier, and left Enforcing/no listener/no Magisk runtime.
- Persistence reached `0x5000000000000000`,
  `0x5100000000000000`, Permissive, UID 0 on 4325, Magisk restored.
- Longer observation showed `watchdog_sw` resets after the standalone carrier
  exited. Explicit retry reboots were removed and the actor now fails open.
- The `stateful-root-hold` carrier retains the exploited binder process,
  mappings, and file descriptors for the entire boot. The host-resident control
  and a fully autonomous boot both remained stable beyond the prior watchdog
  interval; the autonomous boot restored UID 0 and Magisk in 30 seconds.
- Re-running `runme.sh arm` is idempotent.
- Failure tests proved the diagnostic retry counter survives reboot;
  direct `untrusted_app` grooming and exec from `assetstorage_data_file` were
  rejected and are not used by the final path.

## Commands

```sh
# Start with the normal SnusnuRoot flow already providing UID 0/Permissive.
./runme.sh doctor
./runme.sh arm
adb reboot
./runme.sh verify

./runme.sh status
./runme.sh disarm
```

`verify` requires the current boot ID, armed trigger, `rearm_result=ok`, exact
kernel-write success, the resident carrier, Permissive, UID 0, and `magiskd`.
`disarm` disables
and removes the actor, reboots for a clean UID-1000 one-shot, restores numeric
`saved_time`, and removes all persistence files.
