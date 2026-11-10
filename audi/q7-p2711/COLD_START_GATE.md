# P2711 cold-start gate — experimental candidate 1

Built for the supplied **MH2p_ER_AUG35_P2711** HMI, on top of the original
Q7 v1.5 SD ZIP. Host-tested, not vehicle-tested. This is an Android Auto
presentation gate, not a CarPlay port or a delay to AA transport negotiation.

**Experimental SD package:** [download candidate 1](../../builds/ClusterIntegration_q7_p2711_coldstart_candidate1.zip)
(open the file and choose **Download raw file**).
[SHA-256](../../builds/ClusterIntegration_q7_p2711_coldstart_candidate1.zip.sha256) ·
[Validation evidence](COLD_START_VALIDATION.md).
Read the rollback and parked-vehicle validation sections below before testing.

## Behavior

- Android Auto's `gal` wrapper starts immediately, exactly as in v1.5. No
  kill/reconnect watcher, readiness files, five-second startup heuristic, or
  new system-file locations.
- H.264 `prepare` runs immediately in the shipped daemon's invisible PREPARE
  state. It consumes video immediately, preserving the early codec data rather
  than deferring all decoding until after the 2 MB ring has wrapped.
- `resume` is held until the actual cockpit map reports both `mapDrawn` and
  `isInitialized()`. The native-map guard cannot suspend/hide the OEM map before
  those signals. Release is polled once per second, not a fixed startup delay.
- Stop while waiting cancels the pending resume and stops the warm decoder;
  pause cancels the resume. The original v1.5 no-stop-splash patch is preserved.
- The readiness latch is in JVM memory; an HMI restart starts a fresh wait.
- Main-screen AA, audio and BAP navigation events are not gated.
- If stock navigation never initializes or a readiness probe fails, cockpit
  video stays hidden. This includes a car whose native cockpit map is unavailable.
  Main-screen AA continues. There is no timeout override.
- Existing unplug/hand-back behavior after readiness is preserved. This patch
  does not claim to fix the separate post-unplug black-screen problem.

## Verified API in the supplied HMI

The MH2p implementation does not have the MHI2Q `Navigation.getInstance()` API.
The existing OSGi tracker supplies `IMapClusterServiceWrapper`. Its superclass
`AbstractNaviServiceWrapper.get()` returns the weakly referenced implementation.
`MapClusterService.kombiMap` is the actual `AbstractMap` instance.
`AbstractMap.mapDrawn` is volatile and set by `notifyMapFirstDrawn()`.
The stock `CtxShown` first-draw callback invokes that method and then
`mapInitialized()`. `isInitialized()` simply reads `mMapInitialized`.
The probe reads these signals only; it invokes no navigation state changes.

## Binary preservation

The shipped integration source is stale. This build does not recompile it.
A host-only ASM tool renames the original private FIFO sender and adds a thin
wrapper calling the new Java gate. All 104 original method bodies and attributes
are checked byte-for-byte against the release class. The new guard and gate are
compiled to class-file version 48 (Java 1.4).

Only the existing AA-only JAR entry changes in the complete SD package. Every
other ZIP entry's payload is compared to v1.5: original installer, uninstaller,
SSH rollback, failsafe, gal wrapper, native daemon/hook, config, signed ModKit
loader and NavCompassIgnore are unchanged. The stock HMI JAR is not distributed.
The builder pins hashes of both the supplied HMI and original v1.5 ZIP.

## Rollback — existing MH2p procedure

Before testing, keep an untouched copy of the existing SD card, especially
`Mods/ClusterIntegration/Update/Backup/`, on your computer. Overlaying a new
package must not delete that backup folder.

For normal removal, put an empty `uninstall.txt` in
`Mods/ClusterIntegration/` and run the original ModKit installation flow.
For early-boot rescue, copy `Mods/ClusterIntegration/failsafe.sh` to the card
root next to `Data`, `Meta`, `Mods`. Boot with the card, then remove the card
and delete its root-level `failsafe.sh` so it does not repeat. The log is
`Logs/ClusterIntegration-failsafe.log`. SSH `Update/rollback.sh` remains intact.

These procedures uninstall the mod; they do not automatically reinstall your
previous v1.5 mod. Reinstall the preserved v1.5 package separately if desired.
The existing uninstaller can print `Done` after an individual restore fails:
check for `ERROR` lines and verify restored originals. Recovery depends on valid
original binaries/backups and a functioning ModKit boot path; it cannot be
promised for every head-unit failure.

## Parked vehicle validation still required

Test a true cold boot with the phone attached before power-on; a phone connected
after the OEM cockpit map appears; wireless-adapter startup; unplug while the
gate is waiting; and fast reconnect. Check that AA main screen/audio work while
waiting and the native map is not hidden early. Test an HMI restart as well.
Although the screenshot says the navigation database is unavailable, the owner
confirmed that the original cockpit map works. The strict gate will still wait
indefinitely if stock map initialization fails during a particular boot.

Enable the existing Java logging option to capture `/tmp/cluster.log`:
`MH2P_VIDEO_GATE WAIT` at startup, followed by
`MH2P_VIDEO_GATE READY initialized=1 first_drawn=1` on release.
`WAIT probe failed:` records reflection/API failures. Use the existing daemon
logging option to confirm PREPARE decoding occurs before the deferred resume.
Perform the normal rollback check and preserve its log before daily use.

## Rebuild and host tests

Requires a JDK, ECJ 3.20.0 and ASM 9.7.1 (host build dependencies only):

```
ECJ_JAR=/path/to/ecj.jar bash modkit/test/readiness_gate.sh
bash modkit/build_readiness_package.sh /path/to/stock-lsd.jar \
  builds/ClusterIntegration_v0034_q7_p2711_audi.zip \
  /path/to/candidate.zip /path/to/ecj.jar /path/to/asm.jar
```

The modified Java classes live in `audi/q7-p2711/readiness/` as an explicit
profile overlay, leaving the standard source/build path unchanged.
Use this dedicated builder. The generic `build_sd_package.sh` overlays other
tracked scripts that differ from the v1.5 ZIP and does not instrument the sender.
