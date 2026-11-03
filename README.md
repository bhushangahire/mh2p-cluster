# Android Auto and CarPlay Cluster Integration

Bridge Android Auto navigation from Porsche PCM5 / ~~VW / Audi~~ MH2P to instrument cluster displays.

> **Donate to charity** https://www.justgiving.com/

> **Status:** Beta (beta2_candidate_90d0b76) — Testing compatibility across Porsche Cayenne, Macan, Panamera and 911

> **Download (Porsche)** [ClusterIntegration_v0034_beta2_candidate_90d0b76.zip](https://github.com/jonny190/mh2p-cluster/raw/main/builds/ClusterIntegration_v0034_beta2_candidate_90d0b76.zip)
>
> **Download (Audi MH2p, experimental)** [ClusterIntegration_v0034_beta2_candidate_90d0b76_audi.zip](https://github.com/jonny190/mh2p-cluster/raw/main/builds/ClusterIntegration_v0034_beta2_candidate_90d0b76_audi.zip) and read the [Audi section](#audi-mh2p-e-tron-and-other-mlbevo-audis--experimental) first. The Porsche package aborts on an Audi with "Not a Porsche head unit", and copying only the scripts from `modkit/` over it is not enough: the Audi installer also needs `Update/aa_only/` and `Update/audi/`, which are part of the Audi zip.

---

## Overview

Translates Android Auto and Carplay navigation events into BAP (Bedien-und Anzeigeprotokoll) messages for real-time turn-by-turn navigation on your instrument cluster. Native navigation monopolizes the cluster — this changes that.

- Intercepts Android Auto navigation events via DSI and Carplay vis RGI (thanks to https://github.com/luka-dev/mib2q-carplay-rgi/)
- Converts them to BAP protocol messages
- Sends to cluster via `CombiBAPServiceNavi`
- Overrides native navigation with configurable heartbeat (default 2s)
- Supports both Google Maps and Waze

---

## Features

- **Full navigation support** — turn arrows, distance, road names, roundabouts, highway exits
- **Real-time updates** — proximity-zone throttling (veryFar→now) with heartbeat to override native nav
- **Unit detection** — automatic km/mi and LHD/RHD detection via platform services with JSON country fallback (60+ countries)
- **JSON configuration** — runtime-configurable without recompilation; override via USB/SD card
- **Comprehensive logging** — dual-timestamp log with optional privacy hashing and external USB/SD output
- **Java 1.4 compatible** — runs on the embedded QNX/OSGI platform without modern Java features

---

## Architecture

`ClusterIntegration` is a single Java class (Java 1.4 compatible) that bridges the Android Auto DSI, Carplay RGI event stream to the Porsche instrument cluster BAP navigation protocol.

### Data Flow

```
Android Auto (Phone)
        |
    DSI Events (Navigation, Media)
        |
AndroidAutoClusterIntegration
    +-- navFocusRequestNotification   -> start/stop heartbeat, set RGType
    +-- updateNavigationNextTurnEvent -> convertToBAPManeuver -> updateManeuverDescriptor
    +-- updateNavigationNextTurnDistance -> rate-limit -> unit convert -> updateDistanceToNextManeuver
    +-- Heartbeat Timer (every 2s)   -> resend cached maneuver+distance
        |
CombiBAPServiceNavi (OSGi)
        |
Instrument Cluster
```

### Service Injection

All platform services are injected via setters after construction:

| Service | Purpose |
|---|---|
| `CombiBAPServiceNavi` | BAP cluster output — maneuver, distance, RGStatus, destination |
| `ISysServices` | Unit system detection, car clock, car type/variant detection |
| `ICarCoreServices` | Drive-side detection via `configuration().airConditionMaster().driverSideLeft()` |
| `StorageMountHandler` | Remounts USB/SD R/W for external log writing |
| `ICarStatisticsService` | Injected but not currently used in active code |

### AA Event → BAP Maneuver Translation

Maps Android Auto `eventCode` (1–19) + `turnSide` + `angle` + `num` to a BAP maneuver descriptor. Direction is a 0–255 byte (0=straight, 64=left/90°, 128=back/180°, 192=right/270°).

| Event(s) | Translation |
|---|---|
| `event=3–5` (turns) | TURN, direction from `angle` or fallback to `turnSide` |
| `event=6` (U-turn) | UTURN |
| `event=7` (on-ramp) | TURN_ON_MAINROAD, direction from `turnSide` |
| `event=8/10` (off-ramp/merge) | EXIT_LEFT or EXIT_RIGHT based on `turnSide`; side=0 → FOLLOW_STREET |
| `event=9` (fork) | FORK_2 |
| `event=14` (STRAIGHT/KEEP) | `num==1` = Waze lane-keep → FOLLOW_STREET; `num==0` or `num>1` = motorway exit → EXIT_LEFT/RIGHT |
| `event=11–13` (roundabout) | ROUNDABOUT_TRS_LEFT/RIGHT. RHD correction: `(540−angle)%360`; LHD: `(angle+180)%360`. T-junction: 180°→0° when exit ≤ 2 |
| `event=16/17` (ferry) | FERRY |
| `event=19` (destination preview) | Sets flag, falls through as FOLLOW_STREET. DESTINATION symbol shown only on `event=0 valid=2` |

### Distance Update Pipeline

1. **Throttle check** — minimum ms between sends per proximity zone (veryFar=2000ms  to now=100ms). In "always" bargraph mode, bargraph-only updates bypass the throttle.
2. **Maneuver change detection** — key = `road|eventCode|turnSide`. New maneuver resets baseline distance and bypasses throttle for first update.
3. **Distance threshold** — minimum change required per zone (100m at veryFar  to 5m at now) before text updates. Bargraph always updates for smooth fill.
4. **Unit conversion** — metric: m below 100m, tenths of km to 19.9km. Imperial: yards below 161m, tenths of miles to 9.9mi.
5. **Bargraph** — `(1 − distance/maneuverInitialDistance) × 100`, clamped 0–100.
6. **Roundabout traversal** — force distance/bargraph to 0 during CONTINUE events to suppress erratic display inside roundabout.

### Heartbeat

A daemon timer fires every `heartbeatInterval` ms (default 2000ms) while navigation is active. It resends the last cached maneuver, distance, bargraph, and destination data to continuously override the cluster's native navigation display.

### Unit & Drive-Side Detection (3-tier each)

| Priority | Units | Drive side |
|---|---|---|
| 1 (highest) | `forceImperial` config flag | `forceRHD` config flag |
| 2 | `ISysServices.units().distance().setting()` (1=km, 2=mi) | `ICarCoreServices.configuration().airConditionMaster().driverSideLeft()` |
| 3 | JSON `countries` table via locale/system properties | JSON `countries` table `rhd` field |
| 4 (default) | Metric | LHD |

### Bargraph Auto Mode — Car Variant Detection

When `bargraphMode="auto"`, the car type is queried at runtime via `sysServices.config().carType()`:

| Car | carClass | generation | Resolved mode |
|---|---|---|---|
| Cayenne E3 | 5 | 3 | `"always"` |
| 911 992 | 6 | 8 | `"always"` |
| Panamera G2 | 6 | 2 | `"always"` |
| Macan | 4 | 1 | `"distance"` |
| Unknown | any | any | `"always"` (safe default) |

Explicit JSON values always override auto-detection.

### Roundabout Latching

Android Auto sends EXIT (event=13) first, then CONTINUE (event=12) × N through the roundabout. Latching caches the exit direction on event=11/13 and reuses it for all subsequent event=12 updates, preventing the arrow from flickering. Cleared on any non-roundabout event. Configurable via `enableRoundaboutLatching`.

### Logging

Two parallel log files: **plain** (full road names) and **hashed** (road names, music metadata replaced with `[HASH_nnn]` for privacy). Each entry has a dual timestamp: QNX boot time + real car clock from `ISysServices.clock().localTime()`. When `enableExternalLogging=true`, logs are written to USB/SD if writable, with automatic fallback to `/tmp`.

---

## Installation

**Based on MH2p Mod Kit** https://lawpaul.github.io/MH2p_SD_ModKit_Site/

> **Warning:** This modifies Java files on your PCM5/MH2P unit. Only proceed if you understand the risks.

**Prerequisites:**
- Car with PCM5/MH2P (Porsche tested; Audi MH2p experimental, see [Audi MH2p](#audi-mh2p-e-tron-and-other-mlbevo-audis--experimental))
- SD card
- Android Auto phone
- Android Auto <a href="https://lawpaul.github.io/MH2p_SD_ModKit_Site/">activated </a>

**Installation:**
- Download latest release
- Format SD card as FAT32
- extract  file to the root of SD card
- start vehicle
- insert the SD card
- within few seconds, MH2p will reboot
- update installs automatically
- when update is done installing, a prompt will say "Please remove update media"
- remove update media from vehicle
- MH2p will reboot into normal mode with mods installed/uninstalled

**Build:**
Edit build script with paths in your environment and run: 
recompile.sh
or
recompile.bat

**Deploy and test:**
The easiest way is to just scp it to the target if you <a href="https://github.com/fifthBro/mh2p-ssh-access">enbaled ssh access</a>

---

## Audi MH2p (e-tron and other MLBevo Audis) — experimental

> **Audi Q7 (P2711) profile:** full-width map in the Virtual Cockpit with the car marker above Audi's bottom bar, native-map hiding, and fixes for a black cockpit and repeated reconnects. See [audi/q7-p2711](audi/q7-p2711/README.md).

> **Status:** running on an e-tron 55 (`MH2p_ER_AUG35_P2873`, UK, RHD): the shadowed Java class loads, turn-by-turn services are found, the phone streams the cluster map and the virtual cockpit shows it; the cockpit fit is solved; what is being tested now is the hand-back to the Audi map when Android Auto ends (see [Handing the cockpit back](#handing-the-cockpit-back-to-the-audi-map-when-android-auto-ends)). The port changes the install gate and packaging: the native binaries and the config are byte-identical to the Porsche release except for three verified byte patches the package build applies (the boot splash image inside `cluster` from `modkit/splash/splash.png`, see [Changing the cockpit loading splash](#changing-the-cockpit-loading-splash); the decoder ring-start fix from PR #11 inside `cluster`, `modkit/patches/cluster.patches.txt`; and the 54-byte cluster display entry inside `gal_cluster.so` from `modkit/template/template.txt`, see [Fitting the map](#fitting-the-map-to-the-e-trons-cockpit)), the Java classes are the release classes (on Audi the installer uses a copy of the JAR with the CarPlay classes dropped) plus two added classes, a no-op stand-in for the Porsche-only `StorageMountHandler` that the Audi HMI does not ship and `KombiMapGuard`, which hides the Audi map while the video renders and gives the cockpit back to it afterwards, and a rebuilt `AndroidAuto2Subsystem` that starts it.

### Why it might just work

The Porsche PCM5 HMI is built on Audi's framework: every platform class this mod touches lives in `de.audi.*` packages (`CombiBAPServiceNavi` for the cluster's BAP navigation protocol, `ISysServices`, `ICarCoreServices`, the navigation bundle's `IMapClusterService` whose methods talk about the "Kombi", Audi's word for the instrument cluster), and Android Auto runs in the same `gal` process. Nothing in the Java layer or the native hooks checks for Porsche; only the ModKit install script did. The turn-by-turn path (arrows, distance, road name over BAP) has the best odds, because it only uses those shared services. The cluster video path additionally assumes the head unit drives the cluster as QNX displayable `33`. That is known for Porsche and looks right for MH2p Audis: Audi's own service training for the MIB2+ A8 (eSelf-Study Program 990293) states that the virtual cockpit "receives image data from J794 [the MMI main unit] via LVDS and MOST bus", with LVDS carrying "the large navigation map and the detailed intersection maps", which is the same head-unit-rendered cluster map architecture the mod relies on. A public, research-only analysis of an Audi Q3 F3 image with the same `MH2p_ER_AUG35_P2873` firmware (github.com/Dezoxy/audi-mh2p-p2873-research, report 02) found `DISPLAYABLE_KOMBI_MAP_VIEW = 33` in that HMI's display-management constants, the same `switchKombiMapToHiddenContext()` map-control methods, a cluster display on `LVDS2`, and all 61 symbols `gal_cluster.c` imports resolving against that image's receiver, protobuf and screen libraries; it states that nothing in it has run on a vehicle, and it does not compare object layouts or Java constructors with Porsche. Upstream has not answered the two Audi requests on its tracker (issue #8, an A6/A7 on P2711, closed without comment; issue #16 open), so treat every step below as the first public attempt.

Prerequisites specific to Audi: the head unit must be MH2p (MMI version string `MH2P_..`; MY2021+ e-trons are MIB3 with 3xxx firmware and out of scope), and Android Auto must already work. LawPaul's ModKit page lists the e-tron as supported with "extra steps for Apple CarPlay or Android Auto"; those steps are not public, so get Android Auto activated first and only then install this mod.

Two different things have to line up in the `gal` hook, and they carry different risk. The C++ symbol names it interposes come from Google's receiver library (`libautoreceiver.so`) and have stayed stable across VW-group generations; the installer now checks them on your unit and a missing one only makes that hook a silent pass-through. The object layouts it pokes (the message router's endpoint table, the `shared_ptr<IoBuffer>` it reads on every incoming message) were taken from the Porsche binary and can only be tested on the car; a mismatch there can crash `gal`, which is why the diagnostic first boot below exists.

### What the Audi package changes

- `install.sh` accepts `OEM=AU` in addition to `PO`. Firmware build numbers are one VAG-wide counter, so the Audi range is 26xx / 27xx / 28xx: public e-tron GE strings are `MH2p_ER_AUG35_P2711`, `P2718`, `K2716_1` and `P2873` (EU) and `MH2P_US_AUG35_P2711` (US); the firmware trains listed on mib-helper.com for AUG35 are K2470, P2711, P2718, K2716, P2873 and P9805. An e-tron still on the 2019 launch build `K2470` is outside the accepted range; update the MMI first, or use `force_install.txt` knowingly. `P2873` sits in the same build window as the Porsche `P2870` / `P2874` the hooks were built against and is the best-case target; the 27xx builds are older and untested, so the installer prints a warning for any Audi build outside 28xx. Units without a TYPE code (`MH2p_ER_AU_P2873`, Q3 and A1) parse fine.
- Other OEMs and out-of-range firmware still abort. `Mods/ClusterIntegration/force_install.txt` on the SD card overrides the OEM and firmware gate for people who know what they are doing.
- A preflight check aborts before changing anything if `/mnt/app/eso/hmi/lsd/jars` or `/mnt/app/eso/bin/apps` is missing.
- Every change is recorded in `Mods/ClusterIntegration/Update/Backup/manifest.txt` with the backup copy it made (see [Backups and rollback](#backups-and-rollback)).
- On Audi, CarPlay support is opt-in via `Mods/ClusterIntegration/enable_carplay.txt`. Without it the installer uses `Update/aa_only/*_aa.jar`, a copy of the release JAR without the `carplay` package, so the stock classes shadowed are `AndroidAuto2Subsystem` and `AndroidAuto2EventListener` and Audi's own `CarPlayDSIManager` keeps running CarPlay; the `dio_manager` wrapper and hook are not installed either. The CarPlay hook rewrites every iAP2 Identify inside the wireless CarPlay process using Porsche-derived object layouts, and the CarPlay shadow class replaces Audi's whole CarPlay DSI manager; on an untested unit either can break CarPlay outright, and neither does anything for Android Auto. Porsche installs everything as before. On an e-tron P2873 image this is not a precaution but a necessity: `javap` against the unit's own `lsd.jar` shows the full JAR's CarPlay classes calling constructors that do not exist there (`CarPlayDSIManager` inner classes, `CarplayRequest`, `CarPlaySpeechRequestHandler`), so `enable_carplay.txt` is known to break CarPlay on that firmware.
- The mod's `AndroidAuto2Subsystem` constructs `de.audi.app.car.adi.legacy.sportchrono.StorageMountHandler`, a Porsche-side class ("Sport Chrono") that the Audi HMI image does not contain (verified on an e-tron P2873: the whole `de/audi/app/car/adi` package is absent from `lsd.jar`). Without it the shadowed class dies with `NoClassDefFoundError` and takes Android Auto with it. The Audi package therefore carries `Update/audi/ClusterIntegration_StorageMountHandler_stub.jar`, a no-op stand-in (source and build script under `modkit/stub/`, class-file version 48 like the HMI's own classes) that the installer adds to `/mnt/app/eso/hmi/lsd/jars` on Audi; `lsd.sh` puts every jar in that directory on the JVM boot class path ahead of `/ifs/lsd.jxe`. It is skipped when the installer can see the real class in the HMI image, or when `Mods/ClusterIntegration/no_stub.txt` exists; the uninstaller removes it with the mod's other jars. A card without the `audi/` folder keeps an already installed stand-in, and on a unit that has none the installer aborts before changing anything. The only thing the stand-in gives up is the mod's optional remount of the SD card for its own log file.
- The Android-Auto-only JAR also carries `nav/KombiMapGuard` (source under `lsd/`, see [Handing the cockpit back](#handing-the-cockpit-back-to-the-audi-map-when-android-auto-ends)) and a rebuilt `AndroidAuto2Subsystem` that starts it. `modkit/build_aa_jar.sh` compiles the two from `lsd/` with the Eclipse compiler at `-target 1.4` (class-file version 48, `StringBuffer` concatenation, no class literals: what the HMI's J9 JVM loads) against the unit's stock classes, and replaces them in the derived jar; `build_sd_package.sh` runs it. Before the rebuild was trusted, the release `AndroidAuto2Subsystem` was compared with the class compiled from `lsd/` (`javap -c`, both compilers' idioms normalised): same fields, methods, strings, calls and branches, so the source is current for that class. The other release classes are still used as shipped.
- Per-car settings can be baked into the installed config from the card: `Mods/ClusterIntegration/config_overrides.txt` holds `key=value` lines (JSON values) that the installer applies to the top-level `config` block of `cluster_config.json` (plain keys such as `forceRHD`, or `gal_h264.mode`, `gal_h264.codecRes`, `mirror.zoomX` for the inline video objects that apply when `carConfig` has no entry for the car) and records in the manifest; `config_overrides.example.txt` ships next to it with the useful keys commented out. Re-running without the file reinstalls the shipped config.
- Marker files next to `Update/` on the card: `force_install.txt` (skip the gate), `diag.txt` (diagnostic mode), `enable_carplay.txt` (CarPlay hook and full JAR on Audi), `config_overrides.txt` (config values, including `gal_h264.*` / `mirror.*`), `gal_env.txt` (environment for the Android Auto hook: live logging), `daemon_log.txt` (start the cluster daemon with `verbose=2`, which writes `cluster_daemon.log` to the first writable USB stick or `/tmp`; off by default since PR #11), `no_stub.txt` (Audi: do not install the StorageMountHandler stand-in), `uninstall.txt` (ModKit convention: run the uninstaller).
- `uninstall.sh` no longer checks the OEM. It only restores what the mod changed, so it is safe everywhere. `Update/rollback.sh` runs it over SSH without the ModKit.

The scripts are tracked under `modkit/`, and `modkit/build_sd_package.sh` rebuilds a flashable zip from any release zip (deriving the Android-Auto-only JAR as it goes); `modkit/check_hmi_signatures.sh` compares the shadowed classes against a unit's stock jars with `javap`:

```
modkit/build_sd_package.sh builds/ClusterIntegration_v0034_beta2_candidate_90d0b76.zip \
                           builds/ClusterIntegration_v0034_beta2_candidate_90d0b76_audi.zip
```

### Verified against an e-tron P2873 image

Checked with `javap` against classes pulled from `/mnt/app/eso/hmi/lsd/lsd.jar` of an e-tron 55 on `MH2p_ER_AUG35_P2873` (HMI `HMI_AU_MIB2P_H_ER_G35_C27_214801`, "MIB2P_HIGH EUROPE", J9 1.18):

- `AndroidAuto2Subsystem`: the 18-argument constructor and the constructors of all 15 inner classes are identical to the stock Audi ones, and every method or field the stock constructor touches is also touched by the mod's constructor (the mod adds its cluster integration on top). The only apparent stock-only member is `addRequestModeChanges`, which the mod has too, minus the generic signature. `AndroidAuto2EventListener` has the stock constructor signature but not the stock constructor body: the mod's copy subscribes the DSI attributes {3, 5, 6, 7, 8}, the Audi stock one only {3, 5, 6}, and 7 and 8 are the next-turn event and the distance to the next turn. The first Audi package left that class out as a "pure stock copy" (a signature comparison cannot see the difference), which is why no `BAP_MANEUVER` line ever appeared; the class is back in the Android-Auto-only JAR. The stock classes are class-file version 46 and 48; the mod's and the stand-in are 48.
- `StorageMountHandler`: the `de/audi/app/car/adi` package does not exist in the Audi image, so the stand-in jar is required there.
- CarPlay: the full JAR's `carplay` package does not link against this image. `CarPlayDSIManager` carries 44 members the mod copy lacks, seven of its inner classes have different constructors, and the mod's `CarplayRequest`, `RequestModeChangeAudio` and `CarPlaySpeechRequestHandler` call constructors the Audi classes do not have. Leave `enable_carplay.txt` off on this firmware.
- Boot class path: `/mnt/app/eso/hmi/lsd/lsd.sh` runs `find $LSD_DIR/jars/ -name '*.zip' -or -name '*.jar'` and appends every hit to `-Xbootclasspath` ahead of `/ifs/lsd.jxe`, with `-noverify`. That is what makes the mod JAR and the stand-in jar shadow the stock classes on Audi exactly as on Porsche.
- Toolset: `grep` (no `-a`, no match inside binaries), `find`, `awk` and `sed` under `/mnt/app/armle/bin`, `wc` under `/mnt/app/armle/usr/bin`, `cut`, `head`, `sort`, `dd`, `pidin`, `slay`; missing `tr`, `sum`, `cmp`, `od`, `cksum`, `md5sum`, `unzip`, `strings`. The installer's probes, fallbacks and `skipped` semantics are built around that list.
- First live run on the e-tron: the shadowed class loaded with the stand-in, `CombiBAPServiceNavi` and `PartialPopupBAPService` were found, the car key is `5_1` (no `carConfig` entry, global values apply), drive side came out RHD from the GB country lookup, the phone accepted the injected cluster display and streamed H.264, and the daemon found displays `id=1 2820x720` (both MMI screens as one surface) and `id=2 1920x722` (the virtual cockpit), bound its window there (`auto=ok`) and decoded and posted frames at 10 fps. Google Maps appeared in the cockpit. The Porsche boot splash (`splashscreen_000.canim`) is absent on Audi, which only costs the splash. `/tmp` is RAM (`/dev/shmem`), so copy the logs to the card before switching off. The HMI's `DSIMapViewerControl` instance 3 and `IMapClusterService` were not found by the release JAR's one-shot lookup (no `KOMBI_MAP:` lines); the hand-back class added since tracks the service by name instead, see [Handing the cockpit back](#handing-the-cockpit-back-to-the-audi-map-when-android-auto-ends).

### Install on an Audi

Do it in two passes. The first pass installs everything in diagnostic mode: the JAR runs turn-by-turn only (`enableMapRender` is set to `false` in the installed config), the Android Auto hook loads and logs but does not inject the cluster service, and Android Auto otherwise behaves as stock. That pass answers the three questions that matter (does the shadowed Java class load on Audi firmware, do the arrows reach the virtual cockpit over BAP, does the hook resolve its symbols) with the smallest possible blast radius. It does not remove every risk: the hook's `routeMessage` interposer reads the receiver's `shared_ptr<IoBuffer>` layout on every incoming message regardless of the diagnostic switch, so a layout mismatch can still crash `gal` in this pass (that is what the rollback paths are for). The second pass goes live with the video path.

1. Extract the **Audi** zip, `builds/ClusterIntegration_v0034_beta2_candidate_90d0b76_audi.zip`, to an empty FAT32 SD card (not the Porsche zip, and not a Porsche card with the `modkit/` scripts copied over it: the installer needs the `Update/aa_only/` and `Update/audi/` folders that only the Audi zip and the tracked `modkit/Mods/` tree contain). Then create an empty file `Mods/ClusterIntegration/diag.txt`. For a right-hand-drive car, copy `Mods/ClusterIntegration/config_overrides.example.txt` to `config_overrides.txt` in the same folder and uncomment `forceRHD=true` (it fixes the roundabout arrow correction and Waze keep-lane side regardless of what the car reports). Android Auto must already be activated on the unit.
2. Follow the normal Installation steps above. After the reboot, pull the card and read `Logs/ClusterIntegration.log`:
   - `Head unit: release=MH2p_ER_AUG35_P2873 oem=AU type=G35 region=ER sw=2873 force=0` (your values will differ). `Aborting` means the gate refused, `ERROR` means the preflight or a backup check refused.
   - `tools missing:` lists which of the probed commands (`grep find awk sed cut head wc sum cmp diff od dd`) the unit lacks; an e-tron on P2873 prints `sum cmp diff od` (it also has no `tr`, `cksum`, `md5sum`, `unzip` or `strings`, which the installer does not need), and its `wc` lives under `/mnt/app/armle/usr/bin`, which the installer now adds to its PATH. `file compare:` names the tool used to compare files: a real comparator, `wc` on an e-tron (byte, line and word counts plus the modification time for the already-current check; backups then log `backup verified: by size, line and word counts`), or `size only` when even `wc` is missing. `binary search:` names the command that passed a self-test for finding a class name inside a jar on this unit (`grep -a`, `grep` or `awk`), or `none`: the e-tron's `grep` has no `-a` and does not match inside binary files, and with `none` the class and symbol checks below are reported as `skipped` rather than as failures.
   - every `install:` line names a file that was written; `Backups:` names the folder holding the originals; `diag mode: ON` confirms the staged mode.
   - `stock AA class: AndroidAuto2Subsystem found in: ...` shows where the installer sees the stock class the mod shadows (`lsd/lsd.jar`, `/ifs/lsd.jxe` or a plugin jar); it is the control for the next line. `hmi class check: StorageMountHandler NOT found in ...` is the expected Audi result and is followed by `stand-in class: ON`; `found in` means the image has the real class and the stand-in is left out; `skipped` or an unreliable result (control class not seen either) also ends in `stand-in class: ON`, because the stand-in is the safe default on Audi (`no_stub.txt` turns it off). On Porsche the line is informational.
   - `hook symbols: 14/14 present in ...` means the Android Auto receiver on your unit exports everything the hook interposes. Fewer means the missing hooks will silently do nothing; `skipped` means the library was not found or no command on the unit can search a binary file (`binary search: none`).
3. Put the card back in, connect the phone, start navigation in Google Maps or Waze and drive a little. In this pass the virtual cockpit should already show Android Auto's turn arrows and distances through BAP (no map video yet). Then read the logs: `cluster.log` on the card must contain `SYS: Android Auto Cluster Integration Initialized`, `SYS: CombiBAPServiceNavi service AVAILABLE` and `DSI_IN:` lines; `/tmp/gal_preload.log` (SSH) must contain `gal diag mode:` and `gal preload: /mnt/app/eso/bin/apps/cluster/gal_cluster.so`; `/tmp/gal_cluster.log` must contain a `symbols: populate_sd=... sd_serialize=...` line with non-zero addresses and no crash. If Android Auto itself no longer starts, run `rollback.sh` (a `gal_exit:` with a non-zero code right after the preload line means the runtime linker refused the hook; no `SYS:` lines at all means the shadowed Java class did not load). With a route running, `DSI_IN: TURN_EVENT` and `DSI_IN: DISTANCE` lines must appear before any `BAP_MANEUVER` / `BAP_DISTANCE`; if they do not, the HMI is not delivering the navigation attributes (check that the installed JAR contains `AndroidAuto2EventListener.class`, and with `GAL_CLUSTER_SD_LOG=1` in `gal_env.txt` the hook logs `sdresp nav:` lines saying whether the head unit advertises a navigation-status service to the phone at all).
4. Optional but recommended before going live: compare the shadowed classes against your unit's own with `javap`. The diagnostic install stages any small plugin jar that contains them in `Mods/ClusterIntegration/Update/Backup/hmi_reference/` on the card and, when it can search the image and finds the classes in `/mnt/app/eso/hmi/lsd/lsd.jar` (109 MB on an e-tron, not copied automatically), prints that path. On an e-tron the search is skipped (`binary search: none`) and the classes are in that `lsd.jar`; copy it over SSH into a folder of its own on the card (`mkdir /fs/sdb0/stockjars; cp /mnt/app/eso/hmi/lsd/lsd.jar /fs/sdb0/stockjars/`), the unit has no `unzip` to extract on that side. On a PC with a JDK, run `modkit/check_hmi_signatures.sh Mods/ClusterIntegration/Update/ClusterIntegration_v0034_beta2_candidate_90d0b76.jar stockjars` (the full JAR, so every shadowed class is compared); `MATCH` on `AndroidAuto2Subsystem` means the Audi firmware constructs the class exactly the way the mod's copy expects, `MISMATCH` shows the differing constructor and means the mod JAR will not load on this firmware without a rebuild, and the `PRESENT` / `ABSENT` line says whether the stand-in jar is needed (`UNKNOWN` means the folder does not hold the unit's HMI classes). For an e-tron P2873 image this has been done (see [Verified against an e-tron P2873 image](#verified-against-an-e-tron-p2873-image)).
5. Go live: delete `Mods/ClusterIntegration/diag.txt` from the card and run the installation again. It is idempotent: it removes the marker and puts the shipped `cluster_config.json` (video path enabled) back. Reconnect the phone and start navigation.

To get back into diagnostic mode later, put `diag.txt` back and run the installer again; it is the only way that also switches the installed config to turn-by-turn only.

### First-boot checklist

Logs are written to the SD card when `enableExternalLogging` is `true` (the default). With SSH access the same files are under `/tmp`.

| Log | Where | What to look for |
|---|---|---|
| `cluster.log` | SD root, or `/tmp/cluster.log` | `SYS: CombiBAPServiceNavi ...` lines at boot prove the JAR loaded on Audi firmware. `CAR_VARIANT: no entry for X_Y` gives your car's `carClass_generation` key. `DSI_IN:` lines prove Android Auto events reach the bridge. |
| `cluster_daemon.log` | SD root, or `/tmp/cluster_daemon.log` | `detect_disp: disp[n] id=.. size=..` lists every display the head unit drives. `display size: WxH (... auto=ok ...)` proves displayable 33 exists and reports the cluster video resolution; `auto=fail` means it was not found. `[daemon] start:` / `prepare` lines show the Java side driving the mirror. `NvMedia loaded OK` and `BeginSequence:` prove the H.264 decode path works. |
| `gal_preload.log` | `/tmp` (SSH only) | `gal preload: /mnt/app/eso/bin/apps/cluster/gal_cluster.so` proves the wrapper injected the hook into the Android Auto process (`error preload:` means the file was missing); `gal diag mode:` shows the staged mode is active. |
| `gal_cluster.log` | `/tmp` (SSH only; written in diagnostic mode, or with `GAL_CLUSTER_LOG=1` exported in the `gal` wrapper — the shipped v0034 hook reads `GAL_CLUSTER_LOG`, the repo source reads `GAL_CLUSTER_LOG_ALL`) | `symbols: populate_sd=... sd_serialize=...` with non-zero addresses proves the interposed symbols resolved. In live mode `cluster service built`, `sdresp: HYBRID` and `fake endpoint installed` prove the phone was offered the cluster display, and `cluster endpoint: onChannelOpened ch=14` proves it accepted it (the `svc_id=` printed by `handleChannelOpenReq` is layout-derived and may be wrong on Audi). Leave `GAL_CLUSTER_DECODE` unset: the in-hook decoder uses Porsche-only offsets; decoding happens in the `cluster` daemon. |

If the turn-by-turn arrows work but the map video does not, the BAP path is fine and the problem is the video path (`gal_cluster.so`, `cluster` daemon, or displayable 33). If Android Auto itself stops working after install, the shadowed `AndroidAuto2Subsystem` class does not match the Audi firmware; uninstall as described below.

### Tuning for your car

Per-car values live in `cluster_config.json`. A copy at the SD card root (`/fs/sda0/cluster_config.json`) overrides the installed one for every reader while the card is inserted, which is handy for trying zoom and pan values without reflashing. It also silently overrides everything the installer wrote, including `config_overrides.txt` values and diagnostic mode's turn-by-turn-only setting, so use one mechanism or the other (the installer warns if it finds a root copy) and remove the root file when you are done. Take the key from the `CAR_VARIANT` log line and add an entry next to the Porsche ones (v0034 schema shown; older builds used a flat `mirrorCarConfig` block):

```json
"carConfig": {
  "X_Y": {
    "name": "e-tron GE", "bargraphMode": "always", "aaClusterMode": "h264",
    "mirror":   { "mode": "fill",   "zoomX": 1.0, "zoomY": 1.0, "panX": 0.0, "panY": 0.0 },
    "gal_h264": { "codecRes": 720,  "mode": "letter", "zoomX": 1.0, "zoomY": 1.0, "panX": 0.0, "panY": 0.0 }
  }
}
```

For a right-hand-drive car, set `forceRHD=true` through `config_overrides.txt` (or `"forceRHD": true` in the `config` block): drive side is otherwise read from the car's climate-control master position, with the country table as fallback, and it decides the roundabout angle correction and the Waze keep-lane side. Units follow the car's own km/mi setting; `imperialSmallUnit="yards"` only matters if the country lookup fails (GB already maps to yards). Without a car entry the global `config.mirror` and `config.gal_h264` values apply, which is a reasonable first try. The e-tron panel is 1920x720, but the size of the map window the MMI streams to it is unknown, so expect to adjust `gal_h264.mode` / zoom / pan. Note that the native `gal_cluster.so` picks its own per-car settings by Porsche part-number prefix (it queries the head unit's part number and knows 9Y1/9YA/992/971/95B), so on an Audi it uses its global or compiled defaults regardless of the `carConfig` key; the Java side still honours your entry. Fit and framing are tuned with `gal_h264.mode`, `zoomX`/`zoomY`, `panX`/`panY` and `codecRes` (720 or 480); `cluster capture=test verbose=1 zoomX=.. panX=..` over SSH draws a calibration pattern with the same numbers.

If the daemon logs `auto=fail`, the QNX display whose integer id is `33` was not found. On the Audi image analysed above the cluster is listed as display 4 on `LVDS2`, so this may well happen, and it is not by itself fatal: the daemon's H.264 window is bound by name to displayable `33` (the id the Audi HMI itself uses for the cluster map) and sized to the video stream, and the auto-detected size only affects the test pattern and splash images. Try navigation with the phone before concluding. Only if the window reports `got_visible=1` yet nothing appears on the cluster is the named binding wrong too, and that needs a rebuild of `src/cluster.c` with a configurable displayable (`xres=`/`yres=` cannot fix it: they only size the test pattern and the blit rectangle inside the video-sized window, and values larger than the stream break the blit). `cluster capture=display verbose=1` lists every display with its id and size (Ctrl-C to stop).

### Keeping the map in the cockpit while navigating (the compass)

On the e-tron the map shows in the virtual cockpit while Android Auto is connected, but as soon as navigation starts the cockpit falls back to its compass. The stock `AndroidAuto2NavHandler` answers the phone's navigation-focus request by handing the HMI's NAVI application to the device (`requestDSIUpdate(NAVI, DEVICE)`), and the cockpit's navigation view then has no native map to show. LawPaul's [MH2p_NaviCompassIgnore](https://github.com/LawPaul) ModKit mod ("allows showing internal maps in instrument cluster when phone navigation is running") replaces that handler with one that still tells the phone it has focus but never moves the NAVI application, so the cockpit keeps its map, which is the window this mod's daemon draws into. It also stubs the CarPlay `AppState` classes for the same effect on CarPlay. Its classes do not overlap with this mod's jars, and this mod receives the phone's focus request through its own DSI listener, so the turn-by-turn side keeps working. Put both mods on the same card (`Mods/NavCompassIgnore` next to `Mods/ClusterIntegration`); the ModKit installs each. Its installer is Audi-only and its uninstaller just deletes `NaviCompass.jar`.

### Handing the cockpit back to the Audi map when Android Auto ends

On the e-tron the cockpit went black after Android Auto disconnected and stayed black until the next drive. Two things cause that, both visible in the unit's own `lsd.jar`:

- The release JAR looks the navigation bundle's `IMapClusterService` up once, in the `AndroidAuto2Subsystem` constructor, through the terminal-mode `IServiceManager.getServiceReferences(Class)`. On the e-tron that found nothing, and the release cluster integration never calls the service when the session ends anyway (its `wakeNativeNavCluster` was dropped from the shipped class). The stock navigation code reaches the same service with an OSGi `ServiceTracker` on the class *name* (`de.audi.tghu.navi.app.cluster.MapClusterServiceProxy`), which works regardless of which bundle starts first.
- The stock service (`de.audi.tghu.navi.app.cluster.MapClusterService`) implements `switchKombiMapToHiddenContext()` as `kombiMap.switchToHiddenContext()` + `exitMapScreen()` and `switchKombiMapToAShownContext()` as `kombiMap.startActivity(Intent.AUTO)` + `enterMapScreen()`, both guarded against repeats, so a bare "show" while the HMI believes the map is already shown does nothing.

`nav/KombiMapGuard` does the job for both cars. It is Bhushan Ahire's class from the Q7 (PR #11), which hides the native map while the video renders (`suspendMapViewer` + `viewSetVisible(false)` on `DSIMapViewerControl` instance 3, `switchKombiMapToHiddenContext()`) and restores it afterwards, merged with the e-tron work: a `ServiceTracker` on the `IMapClusterService` name next to the retried service-manager lookups, the show 1.2 s after the video stops (once the mod's window is gone), `notifyViewSizeChanged(true)` after the show, and a one-off inventory of the registered map/cluster services. Everything goes through reflection inside a catch-all, so a missing class costs the hand-back, never Android Auto. What `/tmp/cluster.log` shows:

- at HMI start: `KOMBI_MAP: kombi-guard 2026-10-18a started`, `KOMBI_MAP: tracking de.audi.tghu.navi.app.cluster.IMapClusterService by name (...)`, then `KOMBI_MAP: IMapClusterService registered (tracker, class=...)` or `... found (service manager)` and `KOMBI_MAP: DSIMapViewerControl(KOMBI=3) found` as the navigation comes up; one `KOMBI_MAP: coding navMapTransmissionMode=...` line (3 = virtual cockpit);
- when the video starts: `KOMBI_MAP: AA video rendering, hiding native cockpit map (viewer=... mapCluster=...)`, followed by one `KOMBI_MAP: service: ...` line per registered OSGi service whose name mentions Map, Kombi, Cluster, Combi, Zoom or navi (with `DEVICE_INSTANCE` / `DEVICE_NAME` where set), the inventory to read if a lookup failed;
- when it stops: `KOMBI_MAP: AA video stopped, showing native cockpit map in 1200 ms`, then `native kombi map viewer woken`, `IMapClusterService.switchKombiMapToHiddenContext() invoked`, `...switchKombiMapToAShownContext() invoked`, `...notifyViewSizeChanged(true) invoked`. If the cockpit still stays black after those lines, the hand-back reaches the HMI but the map window is not rebuilt; the next lever is the display composition itself (see the A7 notes in PR #12).

The steering-wheel zoom is the same service in the other direction (`changeZoomLevel(int)` fires the HMI's `RemoteZoomView`, which drives the hidden Audi map); routing it to the phone's map is not done yet.

### Changing the cockpit loading splash

For about two seconds after Android Auto connects, while the H.264 decoder warms up, the cockpit shows a splash: in the release it is fifthBro's credit card (`modkit/splash/shipped_fifthbro_1280x720.png`). It is compiled into the `cluster` daemon as a zlib stream (`src/boot_canim_data.h`, the PCM's "canim" format: a 56-byte header and raw RGB pixels), and there is no QNX toolchain here to rebuild the daemon, so `modkit/splash/canim_tool.py` swaps the stream inside the shipped binary instead: a same-length overwrite at the stream's one offset, padded with zeros (the daemon's `uncompress()` stops at the stream's own end marker, so the length constant in the code stays right), verified by decompressing the patched file. Nothing else in the binary changes; re-encoding the shipped image gives a byte-identical binary.

To use your own: design a 1920x1080 PNG on `modkit/splash/template_etron_1920x1080.png` (the red lines are rows 358-1079, the band the cockpit shows with the e-tron recipe `fill` / `panY=0.248`; the inner guides mark a 1280-wide area clear of the housing), save it as `modkit/splash/splash.png`, and `build_sd_package.sh` patches the daemon in the package (`SPLASH_PNG=<file>` overrides the path; without a file the daemon ships as released). The image must compress to no more than the original stream, 45,954 bytes: flat colours, text and simple shapes fit (a dark card with text is 10-45 KB), photographs and noisy gradients do not, and the tool refuses an oversize image rather than shipping a broken daemon. `canim_tool.py preview splash.png out.png` shows the band as the cockpit will. The daemon's other two pictures, the idle logo and the after-disconnect splash loaded from `/mnt/app/eso/hmi/splashscreen/splashscreen_000.canim` (absent on Audi), are left alone: the latter would hold the cluster map slot after Android Auto ends and defeat the hand-back above.

Upstream's licence (CC BY-NC-SA 4.0) asks for attribution; replacing the splash is fine as long as the credit in this README stays.

### Fitting the map to the e-tron's cockpit

The daemon sizes its window to the cluster display it detects (1920x722 on the e-tron) and blits the decoded frame into it according to `gal_h264.mode`. The phone can only stream 16:9 frames, so the default `letter` mode pillarboxes them: 722 x 16/9 = 1283 pixels wide, centred, which is the narrow box seen on the first e-tron runs. The settings that fill the panel, all from the card without reflashing:

- `gal_h264.codecRes=1080`, `gal_h264.mode="fill"` and `gal_h264.panY=0` in `config_overrides.txt`, with `GAL_CLUSTER_RES=1080` in `gal_env.txt`, and the cluster entry the package build writes into `gal_cluster.so` from `modkit/template/template.txt`. The phone streams 1920x1080 (confirmed from the SPS it sends), `fill` crops the centre 722 rows (179-900) and shows them pixel for pixel across the full width, and the entry tells the phone exactly that: `height_margin=358` with margins top 179 / bottom 180, so it lays its whole cluster UI out inside the band, plus content insets bottom 195 (the Audi info bar) and left/right 160 (the curved housing) that it keeps the car marker, turn card and ETA out of. These are the Q7 values from PR #11, verified on the same 1920x722 cockpit; the bottom inset is the knob if the car marker still sits too low on an e-tron. Leave `zoomX`, `zoomY` and `panX` at their defaults; `zoomY` on top of `letter` is what produced the squashed look.
- What did not work, for the record: `GAL_CLUSTER_INSET_TOP=358` with `panY=0.248`. The hook reads the `GAL_CLUSTER_INSET_*` variables and logs them, but sends the phone a fixed 54-byte entry with zero margins, so the phone laid its UI out for the full 1080 rows: the turn card ended up at the top of the frame (hence the pan to the bottom band) and the car marker at the bottom, under the Audi info bar. Bhushan Ahire found this on a Q7 (PR #11); it is confirmed against the v0034 source (`memcpy` of `dhu_cluster_service`, one byte patched for the resolution) and binary. `modkit/template/cluster_template_tool.py decode` on a `/tmp/aa_sdresp_*.bin` dump (`GAL_CLUSTER_SD_LOG=1`) shows what the phone was actually sent.
- The same with `codecRes` 720 and insets of 120: the centre 481 rows of a 1280x720 frame, upscaled 1.5x. Less sharp, less bandwidth.
- `gal_h264.mode="stretch"`: full width by distorting the frame. Only for a quick look.

`gal_env.txt` lines are copied to `/mnt/app/eso/bin/apps/cluster/gal_env` (recorded in the manifest) and exported by the `gal` wrapper before `gal.real` starts; `gal_env.example.txt` ships next to the overrides example. Re-run the installer after every change (it backs up and replaces the config, and `gal` has to restart to pick up the environment). The hook's own log (`GAL_CLUSTER_LOG=1`) shows what was negotiated: `insets: top=180 ... bottom=180` and `codec_res=3(1080p)` in the `sdresp:` line; the daemon's `cluster_daemon.log` shows `display size: 1920x722 (... auto=ok ...)` and `BeginSequence: 1920x1080`.

### Iterating over SSH instead of rebooting

With root SSH on the unit (LawPaul's `mh2p-ssh-access` mod) the card can stay in the slot and most changes apply without the ModKit boot cycle:

1. Edit `Mods/ClusterIntegration/config_overrides.txt` or `gal_env.txt` on the card from the unit (`cat > /fs/sdb0/Mods/ClusterIntegration/gal_env.txt <<'EOF' ... EOF`), or on a PC.
2. Run `ksh /fs/sdb0/Mods/ClusterIntegration/Update/reinstall.sh`. It is `install.sh` with the same gate, backups, manifest and marker files, so the log is the same as the ModKit's.
3. The installer stops `gal` and the daemon. Reconnect the phone: the HMI starts a new `gal`, which reads the new `gal_env` and the new config, and `/tmp/gal_preload.log` shows the `gal env:` lines it exported. The `gal` wrapper also starts the cluster daemon when it finds none running (the Persist script only starts it during a full boot), so after an HMI restart from the knob the map video comes back with the next Android Auto session; `cluster daemon: not running, started by the gal wrapper` in `gal_preload.log` says it did.

A changed JAR (a new package) still needs a restart of the HMI, because it loads the jars at start. Restart the MMI by holding the on/off knob on the centre console for about 10 seconds, or lock the car and let it sleep. Do not use the unit's `shutdown` command without `-b`: on this QNX image it halts the HMI processes and leaves the operating system running, so the screens stay dark until the MMI is restarted by the knob or a power cycle (seen on an e-tron). `/tmp` is RAM, so copy the logs to the card before switching off.

Emulating the head unit on a PC is not realistic: the HMI is a QNX 6.6 image for the unit's NVIDIA Tegra board (the QNX Screen compositor, the NvMedia H.264 decoder, the cluster LVDS link, the DSI middleware and the Android Auto receiver are all tied to that hardware and to the car's bus), there is no QEMU board support for it, and the pieces this mod exercises are exactly the hardware-bound ones. A full backup is worth having regardless: over SSH, `mount` lists the partitions (the app partition is `/dev/mnanda0t177.1`), and `ssh root@<unit> "dd if=/dev/mnanda0t177.1 bs=65536" > mnt_app.img` on a PC copies one (slow over the car's Wi-Fi; a USB stick in the unit, `/fs/usb0_0`, is faster but FAT32 caps a file at 4 GB, so split with `dd` `count=`/`skip=`). The mod's own changes are already backed up on the card by the installer.

### CarPlay on Audi

Turn-by-turn from CarPlay needs the `dio_manager` hook, which is opt-in on Audi (`enable_carplay.txt`). Before enabling it, run a diagnostic-mode pass with it enabled: the wrapper exports `DIO_CLUSTER_LOG=1`, and the shipped hook writes `dio_cluster.log` to the SD card root with `IDENTIFY orig` / `IDENTIFY new` dumps and the phone's `ACCEPTED` / `REJECTED` answer. A rejected Identify on every connection means the Audi head unit already advertises route guidance or the layout differs; disable the hook by deleting `enable_carplay.txt` and running the installer again (it puts the stock `dio_manager` back) rather than leaving CarPlay broken. `uninstall.txt` removes the whole mod instead. The hook also only triggers on wireless CarPlay sessions hosted by `dio_manager` that stream location to the phone; wired sessions live in another process and never reach it. On an e-tron P2873 the Java side is already known not to fit (the full JAR's CarPlay classes do not link against that image, see the verification section), so until a JAR built against the Audi CarPlay classes exists this is Porsche-only in practice.

### Known unknowns

- Whether other Audi firmware builds construct `AndroidAuto2Subsystem` the way the mod's copy expects. On P2873 the constructor and all 15 inner classes match the unit's own `lsd.jar` (see the verification section above); other builds are unverified, and a mismatch raises a linkage error that nothing catches, leaving Android Auto dead until the JAR is removed (rollback). The mod's classes also reference about 140 framework classes outside the packages compared so far (`de.audi.app.terminalmode.*`, `de.audi.atip.*`, `de.audi.mib.system.*`, `de.audi.tghu.navi.app.cluster.IMapClusterService`, `org.dsi.ifc.*`); those are shared VAG framework code and expected to match, but have not been checked member by member.
- Whether the Audi build of `gal` / `libautoreceiver.so` lays out `MessageRouter` and `shared_ptr<IoBuffer>` the way the Porsche one does (the installer's symbol check covers names, not layouts). A layout mismatch can crash `gal` and take Android Auto down until rollback; missing symbols only leave the cluster blank.
- Whether service ids 14 and 21, which the hook adds to the phone's service discovery, are unused in the Audi receiver's own list. A clash makes the phone reject the session (`gal` restarts in a loop). The diagnostic first boot with `GAL_CLUSTER_SD_LOG=1` dumps the stock list as `/tmp/aa_sdresp_*.bin` for checking.
- Whether the Audi cluster video link is displayable `33` and what resolution it has.
- Which Audi firmware versions carry the Android Auto receiver this hook was built against. `P2873` is the closest match to the Porsche builds; the 27xx e-tron builds are accepted by the gate but unverified.
- What LawPaul's e-tron "extra steps" for Android Auto are, and whether they change anything this mod relies on.
- The `carClass`/`generation` values for the e-tron (read them from the log and please report them back).
- The shipped `cluster`, `gal_cluster.so` and most JAR classes in `builds/` are newer than the sources in `src/` and `lsd/` (extra log lines, the `carConfig` schema, config reading in the hook, zoom fields in `AndroidAutoClusterIntegration`). A rebuild from this repository would regress them, so the Audi port reuses the release binaries and classes unchanged, except `AndroidAuto2Subsystem` (verified equal to its source and rebuilt with the hand-back wiring) and the classes this fork adds.

### Backups and rollback

The installer never overwrites a file without first copying it to `Mods/ClusterIntegration/Update/Backup/` on the SD card and verifying the copy: size always, content too when the unit has `cmp`, `diff`, `sum`, `cksum`, `md5sum` or `od`, and otherwise byte, line and word counts from `wc` (the e-tron's case: the log says `file compare: wc` and `backup verified: by size, line and word counts`; with no `wc` either it says `by size only`). A copy that fails that check is discarded and the file is not touched. The same comparison decides whether a file on the unit is already current: with only the `wc` counts available, the unit's copy must also carry the same modification time as the card file (every copy is made with `cp -p`), so an edited or rebuilt file on the card is always installed even when its size and counts happen to match. What ends up where:

| Original | Kept on the head unit as | Copy on the SD card |
|---|---|---|
| `/mnt/app/eso/bin/apps/gal` | `gal.real` (the wrapper execs it) | `Backup/gal.real` and `Backup/gal.original.<timestamp>` |
| `/mnt/app/eso/bin/apps/dio_manager` | `dio_manager.real` | `Backup/dio_manager.real` and `Backup/dio_manager.original.<timestamp>` |
| an older `ClusterIntegration_*.jar` or cluster file being replaced | removed | `Backup/<name>.backup.<timestamp>` |

Everything else the mod installs (the JAR, the Audi stand-in jar, `cluster`, the two `.so` files, `cluster_config.json`, the `diag_mode` marker and the `gal_env` file when present) is new on a stock unit and is listed as `add` in `Backup/manifest.txt`; rollback deletes it. The manifest has one line per action (`add`, `replace`, `swap`, `remove`, `restore`) with the backup path, appended on every run.

To roll back:

- **With the ModKit:** put an empty `uninstall.txt` in `Mods/ClusterIntegration/` on the SD card and boot with it inserted. `uninstall.sh` restores `gal` and `dio_manager` from their `.real` originals (falling back to `Backup/*.real` on the card if `.real` is missing), removes the added files (backing each one up as `*.removed.<timestamp>`), and records what it did in the manifest.
- **Over SSH:** `ksh /fs/sda0/Mods/ClusterIntegration/Update/rollback.sh` does the same without a reboot cycle (the card may be on `/fs/sdb0` or `/fs/usb0_0` on your unit).
- **Boot loop or dead Android Auto:** the ModKit runs a `failsafe.sh` from the root of the SD card early in every boot. A ready-made one ships as `Mods/ClusterIntegration/failsafe.sh` (inert there); copy it to the card's root, boot once with the card in, then delete it from the root again or it rolls back on every boot. Output goes to `Logs/ClusterIntegration-failsafe.log`.

Keep the SD card: it is the only place the timestamped history lives. A factory firmware update rewrites `/mnt/app` and removes the mod along with the `.real` files anyway.

---

## Configuration

The config file `androidauto_cluster_config.json` is embedded in the JAR. To override without reflashing, place the file on a USB stick or SD card — the app checks these paths first:

```
/fs/usb0_0/androidauto_cluster_config.json
/fs/usb1_0/androidauto_cluster_config.json
/fs/sda0/androidauto_cluster_config.json
/fs/sdb0/androidauto_cluster_config.json
```

### Logging

| Key | Type | Default | Description |
|---|---|---|---|
| `enableFileLogging` | bool | `true` | Master switch for all file logging. |
| `enableFileHashing` | bool | `false` | Write a second log with road names/music hashed for privacy. Requires `enableFileLogging`. |
| `enableExternalLogging` | bool | `false` | Write logs to USB/SD if present; falls back to `logFilePath`. |
| `logFilePath` | string | `/tmp/androidauto_cluster.log` | Plain log file path. |
| `hashedLogFilePath` | string | `/tmp/androidauto_cluster_hashed.log` | Hashed log file path. |
| `logFileSize` | int (MB) | `50` | Max file size before deletion and restart. Range: 1–100. |

### Features

| Key | Type | Default | Description |
|---|---|---|---|
| `enableRoundaboutLatching` | bool | `true` | Cache and hold roundabout exit direction across ENTER→CONTINUE→EXIT events to prevent arrow flickering. |
| `enableHeartbeat` | bool | `true` | Periodically resend last maneuver+distance to prevent native nav from overwriting AA data. |
| `heartbeatInterval` | int (ms) | `2000` | Heartbeat period. Range: 100–10000. |
| `maneuverStateMask` | int | `0` | Bitmask for `updateManeuverState` calls. `0` = disabled. bit0=state1 FOLLOW (>500m), bit1=state2 PREPARE (200–500m), bit2=state3 DISTANCE (50–200m), bit3=state4 CALL_FOR_ACTION (<50m). Falls back to nearest lower enabled state. Example: `15` (0b1111) = all states. |

### Units and Display

| Key | Type | Default | Description |
|---|---|---|---|
| `forceImperial` | bool | `false` | Always use miles/yards, ignoring car settings. For testing on metric testbenches. |
| `forceRHD` | bool | `false` | Always treat vehicle as right-hand drive, overriding all detection. |
| `metricUnitThreshold` | int (m) | `100` | Below this, display switches from km to m. Range: 50–5000. |
| `imperialUnitThreshold` | int (m) | `161` | Below this (~0.1 mi), display switches from miles to yards. Range: 50–5000. |
| `destinationDisplayDuration` | int (ms) | `5000` | How long to hold the arrival maneuver on screen before clearing. Range: 0–10000. |

### Bargraph

| Key | Type | Default | Description |
|---|---|---|---|
| `bargraphMode` | string | `"auto"` | `"auto"` — detect car variant at runtime (Cayenne E3/911 992/Panamera G2 → `"always"`, Macan → `"distance"`). `"always"` — send both text and bargraph. `"distance"` — text only. `"dynamic"` — text when far, bargraph only within `dynamicBargraphDistance`. Explicit JSON values override auto-detection. |
| `dynamicBargraphDistance` | int (m) | `100` | In `"dynamic"` mode: distance below which bargraph replaces text. Range: 10–500. |
| `dynamicBargraphPercent` | int (%) | `50` | In `"dynamic"` mode: for short maneuvers (<2x threshold), switch point as % of initial distance. Range: 10–90. |

### Dynamic Thresholds

Controls how aggressively distance updates are sent per proximity zone. Each zone has a **boundary** (upper edge in metres), **distance** threshold (minimum change to trigger a send), and **rateLimit** (minimum ms between sends). `now` has no boundary — catch-all below `veryClose.boundary`.

| Zone | Default boundary | Default distance | Default rateLimit |
|---|---|---|---|
| `veryFar` | 5000 m | 100 m | 2000 ms |
| `far` | 1000 m | 50 m | 500 ms |
| `approaching` | 500 m | 25 m | 250 ms |
| `near` | 200 m | 15 m | 200 ms |
| `close` | 100 m | 15 m | 150 ms |
| `veryClose` | 50 m | 10 m | 120 ms |
| `now` | — | 5 m | 100 ms |

```json
"dynamicThresholds": {
  "veryFar":    { "boundary": 5000, "distance": 100, "rateLimit": 2000 },
  "far":        { "boundary": 1000, "distance": 50,  "rateLimit": 500  },
  "approaching":{ "boundary": 500,  "distance": 25,  "rateLimit": 250  },
  "near":       { "boundary": 200,  "distance": 15,  "rateLimit": 200  },
  "close":      { "boundary": 100,  "distance": 15,  "rateLimit": 150  },
  "veryClose":  { "boundary": 50,   "distance": 10,  "rateLimit": 120  },
  "now":        {                    "distance": 5,   "rateLimit": 100  }
}
```

### Countries

List of country overrides for when locale cannot be detected from platform services. Countries not listed default to LHD metric. `forceImperial` and `forceRHD` override this table entirely.

```json
{ "code": "GB", "name": "United Kingdom", "rhd": true,  "imperial": true  }
{ "code": "US", "name": "United States",  "rhd": false, "imperial": true  }
{ "code": "DE", "name": "Germany",        "rhd": false, "imperial": false }
```

| Field | Type | Description |
|---|---|---|
| `code` | string | ISO 3166-1 alpha-2 country code |
| `name` | string | Human-readable name (informational only) |
| `rhd` | bool | `true` if vehicles drive on the left (right-hand drive countries) |
| `imperial` | bool | `true` if distances should be shown in miles/yards |
---

## Contributing
			
This project is the result of extensive reverse-engineering and testing on mh2p. Contributions welcome!

**Troubleshooting / bug reports**
- Format a FAT32 SD card
- Put SD in PCM before turning the ignition on
- Drive → afterwards when you turn the ignition off → pull SD card → look in the log for event that was wrong → match that event to the same one in the hashed log (time stamps can be useful)
- Share the hashed logs + expected vs actual cluster behaviour

**Known limitations**
- RHD/LHD and metric/imperial still requires testing
- Roundabouts limited (Waze lacks exit angles so they can be wrong)
- Data granularity and slow update rate limit accuracy
- Some glitches are inherent to Android Auto.

---

## Changelog

### v1_main — Beta candidate
Testing compatibility across Porsche Cayenne, Macan, Panamera and 911.

---

## Credits
- **LukaDev** — Managing screens in VW/MIB2 and CarPlay RGHI and GAL hacking: https://github.com/luka-dev/mib2q-carplay-rgi/
- **One1Blt** — Android Auto/VNC to MIB2 rendering: https://github.com/OneB1t/VcMOSTRenderMqb
- **adi961** — Turn-by-turn to VC integration: https://github.com/adi961/mib2-android-auto-vc
- **LawPaul** — MH2P Modkit: https://lawpaul.github.io/MH2p_SD_ModKit_Site/
- **litdreams10** — General platform knowledge, Android Auto testing
- **Bhushan Ahire (bhushangahire)** — Audi Q7 P2711 profile: `KombiMapGuard`, the decoder ring-start and single-daemon fixes, and the finding that the hook's inset variables never reached the phone, with the cluster entry that does: https://github.com/bhushangahire/mh2p-cluster
- **Treuce** — Audi A6 C8 P2873 testing of the Q7 binaries, the BAP guidance-type lead for the cockpit arrow, and the lifecycle design draft (PR #12)
- **tearfalls1987** — Audi A7 P2873 field notes and compatibility record (displayable 62 composition), cited in PR #12

---

*Not affiliated with Porsche, Volkswagen, Audi, or Google. This software is free and not for commercial use.*
