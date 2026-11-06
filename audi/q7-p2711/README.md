# Audi Q7 (MH2p, P2711): Android Auto map in the Virtual Cockpit

Google Maps from Android Auto, full width in the Virtual Cockpit. It shows the 3D driving view with the turn card, and the car marker stays above Audi's bottom info bar. It works over a cable and through wireless Android Auto adapters.

**Download:** `ClusterIntegration_v0034_q7_p2711_audi.zip` from the [v1.5 release](https://github.com/bhushangahire/mh2p-cluster/releases/tag/q7-p2711-v1.5) (or the [latest release](https://github.com/bhushangahire/mh2p-cluster/releases/latest)), or from [`builds/`](../../builds/ClusterIntegration_v0034_q7_p2711_audi.zip) in this repo (open it and click the download button).

> **v1.5:** stable Android Auto connection first. The `gal` wrapper starts AA straight away (same wrapper as v1.4.1) and nothing restarts or kills `gal.real`: the earlier v1.5 build held AA until navigation was ready, and when that wait ran past about 20 s the service manager killed the waiting wrapper, leaving a stray `gal.real` so every restart exited 1 and AA never connected. `Persist/kill_gal_watcher.sh` is removed. Kept: no stop splash (byte patch in `modkit/patches/cluster.patches.txt`), an unplug that only pauses AA stops the paused video, BAP route-guidance type 4, and the guard shows Audi's map again 5 s after AA stops. **Known issues:** on a cold boot AA can connect before Audi's navigation, and the cockpit video may stay black until AA reconnects; after unplugging the phone the cockpit can stay black instead of showing Audi's map.
>
> **v1.4.1** (pre-release, superseded by v1.5): after the automatic restart the guard connects Android Auto itself, the same call the tap on the device list makes, so no tap should be needed. Also: Q7 margins left 450 / density 215 (car marker mid-cockpit), Audi's map comes back after unplugging the phone instead of a black cockpit, and the restart logs are copied to `mh2p_tmp_logs/` on the USB stick next to `cluster.log`. [v1.4.1 release](https://github.com/bhushangahire/mh2p-cluster/releases/tag/q7-p2711-v1.4.1).
>
> **v1.4** reconnects Android Auto once on a cold boot so the cockpit map comes up without the airplane-mode trick. `KombiMapGuard` finds the navigation services (OSGi ServiceTracker) and, if AA connected before them, asks `Persist/kill_gal_watcher.sh` to restart `gal.real` once. Known issue: after that restart the MMI may show its device list; tap your Android Auto device once.
>
> Keep `Mods/ClusterIntegration/config_overrides.txt` on the card (shipped since v1.4). Without it the cockpit falls back to `mode=letter` and the map draws boxed between the gauges.

> Don't use GitHub's green **Code → Download ZIP** button. That downloads the project's source code, which the car can't install.

**Tested on:**
- Car: 2020 Audi Q7 (US) with the Virtual Cockpit.
- Head unit: MH2p, firmware `MH2P_US_AUG35_P2711`.
- Phone: Samsung Galaxy, Google Maps.
- Connections: USB cable, AAWireless (DPI 150), and another wireless adapter.

Other MH2p Audis with the same 1920×722 cockpit should be close but are untested. Experimental: install only while parked, and keep the backups the installer makes.

## Install

**Requirements:** Android Auto already working on the car, and the car parked. Read the main README's Audi section first.

The zip contains everything for one SD card:

| Folder | What it is |
|---|---|
| `Data/`, `Meta/` | LawPaul's MH2p SD ModKit v2 loader, unmodified. It lets the head unit install the mods. |
| `Mods/ClusterIntegration/` | This mod. |
| `Mods/NavCompassIgnore/` | LawPaul's NavCompassIgnore, unmodified. Without it the cockpit switches to the compass once navigation starts. If you already have it installed, installing it again is harmless. |

1. Format an SD card as **FAT32**. 32 GB or smaller is easiest; for larger cards, Windows can't format FAT32, so use Rufus or Raspberry Pi Imager.
2. Extract the zip, then copy what's **inside** it to the **root** of the card. When you open the card you must see `Data`, `Meta` and `Mods` immediately, not inside another folder. "Extract All" usually creates a folder named after the zip; copy its contents, not the folder.
3. On a Mac, remove the hidden `._` files macOS adds, or the update may not start: `dot_clean -m /Volumes/<card name>`.
4. Start the engine, then insert the card (lock switch unlocked). The head unit reboots and the update starts by itself within about 10 seconds. Don't touch the screen. It reboots several times, and red engineering pages may appear.
5. When asked to remove the update media, remove the card. The head unit restarts normally.
6. Copy `Mods/ClusterIntegration/Update/Backup/` from the card somewhere safe. The installer saves every file it replaced there.
7. Plug in the phone and start Google Maps navigation. The cockpit map should appear on the first connection.

If you use a wireless adapter with its own DPI setting, keep it moderate (150 worked). Some custom values made the phone drop the cockpit display.

**If the update doesn't start:**
- Nothing happens, or "update not supported": usually `Data`/`Meta` aren't at the card root, the card isn't FAT32, or macOS `._` files are present (steps 1–3).
- "BEM level is set to LEVEL 1": the engine isn't running.
- Error partway through: reformat the card or try another card.
- Check the head unit is MH2p: the MMI version should start with `MH2P_`.

**Uninstall:** put an empty `uninstall.txt` in `Mods/ClusterIntegration/` (and in `Mods/NavCompassIgnore/` to remove that too) and install the card again. ClusterIntegration restores the backed-up originals.

## Emergency rollback (`failsafe.sh`)

If the head unit doesn't boot cleanly after installing this mod, there's an unattended rescue mechanism baked into the ModKit. The install card already ships `failsafe.sh` inside `Mods/ClusterIntegration/` — it does not run by itself. To arm it:

1. On a working computer, open the SD card.
2. **Copy `Mods/ClusterIntegration/failsafe.sh` to the ROOT of the SD card** (next to `Data/`, `Meta/`, `Mods/`).
3. Insert the card into the car and switch the ignition on. The ModKit's early-boot code runs `failsafe.sh` from the card root before any mod's Persist step, so it works even if our Persist script is what's breaking things.
4. Wait for the unit to come up. The script invokes the mod's `uninstall.sh`, which restores every file the installer replaced from its backups.
5. Remove the card and **delete the root-level `failsafe.sh` from the card** before using it again — otherwise it rolls back on every boot.
6. A log of what it did is written to `Logs/ClusterIntegration-failsafe.log` on the card.

Normal uninstall (when the head unit is working normally) is the standard ModKit path: put an empty `uninstall.txt` in `Mods/ClusterIntegration/` on the card and run the ModKit — same effect, no rush.

## Turning logs on (troubleshooting)

The zip writes no logs during normal use. To diagnose a problem, turn on what you need, re-run the ModKit install, and reproduce the problem. Turn it back off the same way afterwards.

| Log | How to turn it on | Where it goes |
|---|---|---|
| Installer | Always on | `Logs/ClusterIntegration.log` on the SD card, after each install |
| Java integration (session state, map hiding `KOMBI_MAP:`, turn events) | In `Mods/ClusterIntegration/config_overrides.txt`, change `enableExternalLogging=false` to `true` | `cluster.log` in the root of the USB stick in the car (it's always kept in RAM at `/tmp/cluster.log`) |
| Android Auto hook (service discovery, video channel) | Create `Mods/ClusterIntegration/gal_env.txt` with the two lines `GAL_CLUSTER_LOG=1` and `GAL_CLUSTER_LOG_ALL=1` (add `GAL_CLUSTER_SD_LOG=1` to also dump the service discovery) | RAM: `/tmp/gal_cluster.log`. Read it over SSH, or copy it to USB with `cp /tmp/*.log /fs/usb0_0/` |
| Cluster daemon (decoder, frame rate, `prepare`/`resume`/`stop` commands) | Create an empty `Mods/ClusterIntegration/daemon_log.txt` and re-run the ModKit install; the installer sets a marker that makes both daemon starts pass `verbose=2`. Delete the file and re-run to turn it off. | `cluster_daemon.log` in the root of the first writable USB stick (falls back to `/tmp`), capped at 1 MB |

With SSH access (LawPaul's `mh2p-ssh-access` mod) you can turn on the daemon log for one session without reinstalling: stop the running daemon with `slay cluster`, then run `/mnt/app/eso/bin/apps/cluster/cluster daemon verbose=2 &`, then reconnect the phone. A reboot returns to normal.

Useful things to look for:
- `[daemon] polling` appears **once** per boot in `cluster_daemon.log`. Twice means two daemons are running.
- `decode_fps=` shows the video frame rate.
- `KOMBI_MAP: AA video rendering, hiding native cockpit map` in `cluster.log` confirms the native map was hidden.

## What this changes from upstream v0034 Audi

| Problem on the Q7 | Fix | Source |
|---|---|---|
| The native Audi cockpit map keeps drawing over the AA video (displayable 33). | `KombiMapGuard` suspends the native kombi map viewer while the AA video renders, and wakes it afterwards. | `lsd/.../nav/KombiMapGuard.java`, started from `AndroidAuto2Subsystem` |
| Black cockpit until a reconnect: the decoder started at the ring's current write position and skipped the session's SPS/PPS/IDR. | Decode from the ring start. | `src/cluster.c` |
| Map needed several reconnects: the gal wrapper and the Persist script each started a cluster daemon, and the two stole each other's commands. | Persist starts the daemon only when none is running. | `modkit/Mods/ClusterIntegration/Persist/install.sh` |
| Car marker hidden under Audi's bottom bar, turn card clipped by the curved edge. The hook sends a fixed 54-byte cluster template (`dhu_cluster_service[]`), so `GAL_CLUSTER_INSET_*` never reaches the phone. | Template rewritten in place for the Q7 cockpit (below). | `gal_cluster.so` at file offset `0x7384` |
| Settings | `codecRes=1080`, `mode="fill"`, `panY=0.0`, Java log to USB off. | `Mods/ClusterIntegration/config_overrides.txt` in the zip |
| Every user got a `cluster_daemon.log` on their USB stick: both places that start the daemon passed `verbose=2`. | Start the daemon without `verbose`; nothing is written to USB. | `Persist/install.sh`, `modkit/Mods/ClusterIntegration/Update/gal` |

**Cockpit template values:**
- `display_type`: CLUSTER (3D driving view; AUXILIARY gives a flat 2D map).
- Stream: 1080p.
- `height_margin`: 358. The daemon's `fill` crop shows rows 179–900, which is exactly the active area.
- UI margins: top 179, bottom 180.
- Content insets: bottom 195 (Audi's info bar), left and right 160 (curved edges).
- Density: 200.

The template bytes:

```
0a34080e1a30222a 0801 1001 20e602 28c801 38f403 40904e 48c801 5003
5a13 0a06 08b301 10b401 1209 10c301 18a001 20a001 3001 3801
```

The `cluster` daemon in the zip is upstream's build with the `src/cluster.c` change applied as two instructions (file offset `0x66ec`: `mov.w r11,#0`, `mov.w r4,#0`). The jar is upstream's Android-Auto-only jar rebuilt with `KombiMapGuard` (ECJ, `-source 1.5 -target jsr14`).

## Known limits

- **Android Auto only.** This build targets Android Auto. CarPlay is **not enabled** (`enable_carplay.txt` is not set). Upstream's Audi CarPlay hook patches iAP2 Identify requests with Porsche-derived object layouts and has broken CarPlay on untested Audi firmware (see the main repo's Audi section). CarPlay users should wait for Q7-specific CarPlay testing or use upstream's default build. The cockpit-framing fixes here (insets, DPI, car centering) are in `gal_cluster.so`, which only hooks Android Auto's `gal` process — CarPlay goes through `dio_manager` and would need equivalent framing patches we have not built or tested.
- **HUD:** no arrows or distance on the head-up display, only the street name. With the cockpit coded for the map (`navMapTransmissionMode=3`), the head unit drops the BAP arrow data, and the HUD arrow renderer in `navStartup` only draws while Audi's own route guidance is active. Running Audi native navigation alongside Google Maps gives you Audi's HUD arrows and junction views, with Google in the cockpit — a working daily workaround.
- **Center screen:** while the cockpit map is active, it shows Google's route overview. That's Google's design for cars with a cluster display.
- **Frame rate:** about 10–15 fps while the map rotates. The phone's encoder limits this; the head unit decodes every frame.
- **Native map:** the Audi navigation map is hidden while Android Auto video runs in the cockpit, and comes back when AA disconnects.

## Credits

- **fifthBro:** the original MH2p cluster integration (hook, daemon, Java integration). https://fifthbro.github.io
- **jonny190/mh2p-cluster:** the Audi package this builds on, with Jonathan Davey and jakublamik. https://github.com/jonny190/mh2p-cluster
- **LawPaul:** MH2p SD ModKit (the zip's `Data/` and `Meta/` are his signed ModKit v2, unmodified) and NavCompassIgnore (`Mods/NavCompassIgnore/`, unmodified from [LawPaul/MH2p_NavCompassIgnore](https://github.com/LawPaul/MH2p_NavCompassIgnore) at `1dc404c`), both CC BY-NC-SA 4.0; also SSH access. https://lawpaul.github.io/MH2p_SD_ModKit_Site/
- **luka-dev:** mib2q-carplay-rgi, navigation event research used upstream. https://github.com/luka-dev/mib2q-carplay-rgi
- **Q7 P2711 fixes and profile:** Bhushan Ahire.

## License

Same as the rest of this repository: [CC BY-NC-SA 4.0](../../LICENSE.md). Non-commercial use only. Changes from upstream are listed above.

The zip contains no Audi, Harman or Google files. The ModKit loader and NavCompassIgnore in it are LawPaul's work, included unmodified under their CC BY-NC-SA 4.0 license. Not affiliated with or endorsed by Audi, Volkswagen Group, Harman or Google. "Audi", "Android Auto" and "Google Maps" are trademarks of their owners and are used only to describe compatibility. Use at your own risk; modifying the head unit may affect your warranty.
