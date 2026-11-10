# P2711 cold-start candidate 1: validation

Status: host-tested experimental SD package, not vehicle-validated.
Target: supplied MH2p_ER_AUG35_P2711 HMI, based on original Q7 P2711 v1.5.

- 15 Java gate host-fixture assertions passed under JVM bytecode verification.
  Stock Audi classes were inspected/used for compilation, never executed.
- All 104 existing integration methods preserve their exact attributes and
  bytecode. Only a private sender wrapper is added, delegating to the new gate.
- New/changed runtime classes use Java 1.4 class-file version 48 and contain no
  StringBuilder/invokedynamic introduced by the build.
- Only one complete SD ZIP payload differs from v1.5: the existing AA-only JAR.
  Its integration class is instrumented, KombiMapGuard is rebuilt, and
  Mh2pVideoGate is added. Every other JAR entry is preserved.
- Installer, uninstaller, failsafe, SSH rollback, gal wrapper, configs, native
  hook/daemon, NavCompassIgnore, Data and Meta preserve their original bytes.
- Five isolated restoration-function tests passed (normal .real restoration,
  SD fallback, leaving originals unchanged, reporting missing originals, and
  backup before JAR removal). These do not establish complete QNX recovery.
- ZIP CRC check and shell syntax checks passed.

## Read-only inspection evidence

Supplied stock HMI SHA-256:
96a49c355e5704db7713e4d5485495b631a5b54859d136f5d8ae9067ece718d8

Original v1.5 complete SD ZIP SHA-256:
7b703cf9978611e2efaab6bdd85a8248d16c7bd30ca5c19f211c0651ca7283fd

Stock MapClusterService holds the cockpit AbstractMap in its kombiMap field.
Its OSGi wrapper delegates through AbstractNaviServiceWrapper.get().
AbstractMap.mapDrawn is volatile. The CtxShown first-draw callback invokes
notifyMapFirstDrawn() and mapInitialized(); isInitialized() is a pure field read.
The gate checks both stock flags, rather than inferring readiness from service
registration or sleeping for five seconds.

The exact shipped ARM/Thumb daemon was disassembled, rather than assuming its
source is current. g_render_stage is at 0x080601f0. In cb_begin_sequence the
visibility value is 0 when this stage is 0 (PREPARE), stored at 0x0804d874 and
passed to screen_set_window_property_iv with property 0x33 (VISIBLE) at
0x0804d8ae-0x0804d8b6. In cb_display_picture, the stage loaded through the
literal at 0x0804cfe0 is compared with 1 at 0x0804cf94; the branch at
0x0804cfa2 reaches screen_post_window only for RENDERING. The warm decoder
therefore consumes the ring without posting AA frames while the gate waits.
The existing no-stop-splash byte patch remains present in the unchanged daemon.

## Practical limits

This gates AA presentation; it does not delay the phone's secondary-stream
negotiation. Invisible warm decoding avoids introducing buffer wrap from a
long readiness wait, but does not fix every existing native startup race or
provide decoder health acknowledgements. Vehicle logs must confirm the native
map initializes, PREPARE consumes frames, and resume produces a visible map.

Despite the screenshot's navigation-database warning, the owner confirmed that
the stock cockpit map works. If that map fails to initialize on a later boot,
the strict gate intentionally keeps AA secondary video hidden while leaving
the main AA screen available.

The separate black screen after unplug remains outside this first fix.
The unchanged rollback cannot guarantee recovery for every MMI failure, and
its final Done message alone does not establish successful restoration.
