# Changelog

<!-- Each release's section becomes its GitHub release notes, and the part between
the tg markers is the Telegram summary. Use absolute links: the notes are read on
the release page. -->

## v0.8.0

<!--tg-->
Hides more from apps: the emulator's service states, its HAL file names and the ARM
translator's properties, plus a choice of five Pixel identities. Needs
susfs4ksu-lkm-x64 v0.0.8.
<!--/tg-->

- **Pick the phone:** Pixel 8 (default), 7 Pro, 8 Pro, 9 Pro or 9 Pro XL, under
  **Phone to claim** in the Options tab or with `device <codename>` in the user config.
- **App-only property hiding:** the emulator's `init.svc.*` service states are hidden
  from apps, kept current as services change. Root and `adb shell` still see them.
- **Emulator-named HAL files** in `/vendor/lib64/hw` (audio, sensors, mapper, Vulkan)
  are hidden from apps.
- **Battery:** the `power_supply` directory is relabelled as on a phone, so apps find it.
- **With Run ARM apps on:** apps no longer read the native bridge property or the ABI
  list keys, arm64 apps read `aarch64` from `uname()`, the bridge loads as
  `libsysglue.so`, and `libc.so`, `linker64` and `libandroid_runtime.so` read arm64. The
  `libc.so` redirect keeps the original file's identity, so Native Detector reports no
  inconsistent mount.
- Home, health and the log export show the app property view.
- Requires susfs4ksu-lkm-x64 v0.0.8. On v0.0.7 the rules that need it are skipped with
  a warning. Known limits, including Frida with Run ARM apps on:
  [LIMITATIONS.md](https://github.com/ymuuuu/NoEmulator/blob/main/LIMITATIONS.md).

Checked on the reference AVD with susfs4ksu-lkm-x64 v0.0.8 and Run ARM apps on: Native
Detector, Duck Detector and vdinfos the same as before the release.

## v0.7.0

<!--tg-->
First public release. Hides an Android Studio emulator from emulator detection with
SUSFS kernel rules instead of hooks. Needs KernelSU-Next and susfs4ksu-lkm-x64 v0.0.7.
<!--/tg-->

- Hides the emulator from apps with SUSFS kernel rules: a coherent Pixel 8 build
  identity, emulator properties deleted, emulator device nodes and the gralloc mapper
  redirected to neutral names, the GPU driver presented as `mali`.
- WebUI in the KernelSU manager: Home (did the last boot work, failed rules, full log),
  ANGLE (hide the GL renderer per app), Options (Run ARM apps, Sync the host clipboard,
  Reboot now), About (version check, credits).
- The module card shows `✅ Working.` or `❌ Needs attention:` after each boot.
- Bug reports: **Action** or the Log page saves a redacted report to `/sdcard/Download`.
- Requires susfs4ksu-lkm-x64 v0.0.7 or later. Known limits: [LIMITATIONS.md](https://github.com/ymuuuu/NoEmulator/blob/main/LIMITATIONS.md).
