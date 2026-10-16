# Root stage interface

`./runme.sh root` remains the normal path. It composes the same exploit chain
from independently runnable stages and is the only command that automatically
reboots or retries. Researchers may stop after any successful stage.

```text
stage-assets
     |
arm-waiter --(manual/high-level reboot)--> carrier
                                            |
                                           leak
                                            |
                                           write
                                            |
                                      root-service
                                            |
                                    bootstrap-magisk
                                            |
                                  install-persistence
                                            |
                                         manager
```

The scripts in `scripts/stages/` depend only on `scripts/lib/` and existing
native/helper implementations. They never call `runme.sh`. Every stage prints
stable `key=value` facts followed by `STAGE_OK <name>`, or exits nonzero with a
final `STAGE_FAIL <name> class=<class> reason=<reason>` line.

## Contracts

| Stage | Inputs and preconditions | Output/state | Repeat/retry and consumption | Valid next stage |
| --- | --- | --- | --- | --- |
| `stage-assets` | Authorized device; packaged agent, helpers, and both JNI ABIs. Updating secured files needs an existing or newly created UID-1000 staging channel. | Live hash verification for `agent.jar`, helpers, ELF64 and ELF32 JNI. | Hash-current runs are idempotent and consume no state. A missing-file install may create the UID-1000 channel and therefore consume that boot's Zygote one-shot; this unavoidable platform constraint is printed before installation. Never consumes Binder state. | `arm-waiter`, or `carrier` if already armed/on the intended boot. |
| `arm-waiter` | Assets ready; payload file; `saved_time` numeric or an already valid arm; valid numeric restore snapshot when already armed. | Waiter is live-verified; original number and boot evidence recorded. | Conditional idempotence: an armed waiter is inspected, never re-armed. A new arm consumes the boot's Zygote one-shot. Never consumes Binder state. No automatic reboot; unsafe to blindly retry after an uncertain injection. | Reboot, then `carrier`. |
| `carrier` | Clean hidden-API setting and staged assets. | Live PID, UID 10100, `amazon_app` context, group 3003, ELF64, ABI and exact JNI path; boot-scoped evidence. | Reuses a valid carrier; otherwise deterministic spawn may consume Zygote one-shot. Never sends a Binder primitive and never marks Binder spent on failure. | `leak`. |
| `leak` | A separately created, live-valid carrier. | `success`, `spent`, or `uncertain` evidence with current boot ID and carrier PID. | Sends only `HWBINDER_STATEFUL`. It can consume fresh-boot Binder state and is generally not retryable in the same boot. An already recorded success is only reported after live carrier/PID validation. Never reboots or writes. | `write` on success; manual reboot after spent state. |
| `write` | Successful leak from this exact boot; same live carrier PID; valid ELF/ABI/JNI. | Native `0x51` result plus live `Permissive`; boot-scoped evidence. | Never arms, leaks, reboots, or bootstraps. An already recorded success still requires live `Permissive`. Uncertain failures are not silently retried. | `root-service`. |
| `root-service` | Current-boot write success and live `Permissive`; pre-staged waiter payload. | UID-0 listener with `u:r:time_update:s0`; boot-scoped evidence. | Idempotent while the listener is healthy. Consumes neither primitive. Does not start Magisk. | `bootstrap-magisk`, or stop. |
| `bootstrap-magisk` | Healthy UID-0 listener and packaged Magisk artifacts. | Live daemon and socket verification; boot-scoped evidence. | Uses the existing rollback-capable bootstrap. No Binder/Zygote consumption. | `install-persistence`, `manager`, or stop. |
| `install-persistence` | Healthy UID-0 listener, packaged actor/runtime. | Enabled direct-boot actor and armed trigger; live verification plus evidence. | Conditional/hash-gated and preserves prior enable state on interrupted install. Uses the current root channel; no Binder primitive or automatic reboot. | `manager`, `verify`, reboot, or `disarm`. |

Boot-sensitive state is stored as atomically replaced records under:

```text
/data/local/tmp/snusnu-state/
    carrier
    waiter
    leak
    write
    root
    magisk
    persistence
```

Each record has `status=`, `boot_id=`, and `detail=` fields. Records are
advisory: transitions compare their boot ID with
`/proc/sys/kernel/random/boot_id` and repeat relevant live checks. In
particular, `write` requires the same live carrier PID/ABI/JNI as the recorded
leak. Old records are reported as `stale_previous_boot`, never accepted.

Failure classes are stable: `PRECONDITION_FAILURE`, `CARRIER_FAILURE`,
`ZYGOTE_ONESHOT_SPENT`, `BINDER_BOOT_SPENT`, `BINDER_STATE_UNKNOWN`,
`WAITER_UNARMED`, and `POST_WRITE_FAILURE`. An unparseable/transport-failed leak is recorded as
`unknown`, not falsely labeled spent. Leak/write success is also explicit.
Only `BINDER_BOOT_SPENT` makes the high-level flow retry on a fresh boot;
deterministic precondition, carrier, waiter, and post-write failures stop.

## Research workflows

Carrier-only work:

```sh
./runme.sh stage-assets
./runme.sh carrier
./runme.sh status --verbose
```

Binder leak testing:

```sh
./runme.sh carrier
./runme.sh leak
./runme.sh status
```

Manual progression:

```sh
./runme.sh stage-assets
./runme.sh arm-waiter
# reboot explicitly when required
./runme.sh carrier
./runme.sh leak
./runme.sh write
./runme.sh root-service
```

Normal end-to-end use:

```sh
./runme.sh root
```
