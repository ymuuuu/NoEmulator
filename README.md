# NoEmulator

Hides Android emulator artifacts from apps, using kernel rules rather than hooks.

**Status: early, but measured end to end.** Tested on one reference device, a rooted
Android 16 Pixel 9 x86_64 AVD (Android Studio emulator). It depends on the requirements
below, and some apps need a per-app setting. Read [LIMITATIONS.md](LIMITATIONS.md) before
installing.

## What it does

Apps can tell an emulator from a phone. On the reference device with nothing installed,
a detector finds 12 clear signals and 7 more worth reviewing: the build fingerprint says
`sdk_gphone64_x86_64`, `/dev/goldfish_pipe_dprctd` is open in the process, the ARM
translation layer is loaded, and 111 system properties mention the emulator.

Existing modules fix this by hooking into every app and rewriting what it reads.
That is detectable: compare a result from the C library against the same result from
a raw syscall and the two disagree. Detectors run that comparison today.

NoEmulator ships rules instead. The kernel answers both paths identically, so there
is nothing to compare. Nothing on disk is edited, so there is no edit mark to find.

- **Build identity:** the build properties name one Pixel coherently: fingerprint,
  device, build id and every partition's copy agree. The Pixel 8 by default; pick the
  Pixel 7 Pro, 8 Pro, 9 Pro or 9 Pro XL under **Phone to claim** in the WebUI's Options
  tab, or with a `device <codename>` line in the user config.
- **Emulator properties:** deleted, or given a Pixel value. The emulator's service
  states are hidden from apps alone.
- **Emulator-named HAL files** in `/vendor/lib64/hw`: hidden from apps.
- **Battery directory:** relabelled as on a phone, so apps find `power_supply`.
- **Emulator device nodes and the gralloc mapper:** redirected to neutral names, so an
  app's file descriptors and memory map carry no `goldfish` or `ranchu`. The device is
  the same, so graphics keep working.
- **GPU driver names:** the Vulkan and EGL drivers are presented under the name `mali`.
- **The ARM native bridge:** removed by default, so ARM-only apps break unless you turn
  on **Run ARM apps**. With it on, apps see the bridge's property and ABI keys hidden,
  arm64 apps read `aarch64` from `uname()`, and the bridge is loaded as `libsysglue.so`
  ([LIMITATIONS.md](LIMITATIONS.md)).

## Requirements

- **[susfs4ksu-lkm-x64](https://github.com/ymuuuu/susfs4ksu-lkm-x64) v0.0.8 or later installed and loaded.** NoEmulator does not bundle it and refuses to install without it. On v0.0.7 it installs with a warning, and the rules that need v0.0.8 are skipped: the app-only property hiding, the `uname()` answer and the `libc.so` header redirect.
- **x86_64.** The install aborts on other architectures.
- **KernelSU-Next**, which loads the susfs kernel module.
- **[NoMount](https://github.com/maxsteeel/nomount), recommended.**

## What it does not hide

See [LIMITATIONS.md](LIMITATIONS.md): the GL renderer until you name the app, the x86_64
hardware, the ARM translator when ARM apps are on, and a few more.

## Layout

| Path | What |
|---|---|
| `module/` | the KernelSU module: `artifacts.conf`, `customize.sh`, `post-fs-data.sh`, `post-mount.sh`, `service.sh`, `action.sh`, `lib/`, `webroot/` |
| `update.json` | the update channel `module.prop` names |
| `scripts/` | packaging and the pre-commit check |
| `tests/` | host tests for rule generation, no device needed |

## Configuration

The WebUI covers the common choices: open NoEmulator in the KernelSU manager. Its
**Options** tab has **Run ARM apps** and **Sync the host clipboard**; its **ANGLE** tab
hides the GL renderer per app ([ANGLE.md](ANGLE.md)).

Anything else goes in the user config, `/data/adb/noemulator-user.conf`, which updates
keep and uninstall removes. It takes the same directives as `module/artifacts.conf`,
which documents each one in its comments. A bad line stops every rule from applying, so
check a change first:

```sh
sh module/lib/generate_rules.sh module/artifacts.conf /data/adb/noemulator-user.conf
```

## Reporting a problem

Tap **Action** on NoEmulator's card in the KernelSU manager, or **Export for a bug
report** on the WebUI's Log page. Either saves `noemulator-logs-<UTC time>.txt` to
`/sdcard/Download`. It holds the versions of NoEmulator, the kernel, Android and `ksud`;
the installed modules; the last boot's `apply.log`; the user config; the susfs redirect
list; and the emulator properties still set. Values of properties named for a timezone,
an ADB key, a serial or a `guid` are replaced with `redacted`. Times are UTC. Read the
file, then attach it to a [bug report](https://github.com/ymuuuu/NoEmulator/issues/new/choose).

## Licence

GPL-3.0. See `LICENSE`.
