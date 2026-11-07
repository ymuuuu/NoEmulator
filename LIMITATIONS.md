# What NoEmulator does not hide

Measured on the reference device, a rooted Android 16 Pixel 9 x86_64 AVD.

| Signal | Why it stays | What you can do |
|---|---|---|
| **GL renderer** says `Android Emulator OpenGL ES Translator` | The GL driver answers inside the app's own process | Put the app on ANGLE ([ANGLE.md](ANGLE.md)). ANGLE then says `llvmpipe`, and its shading language version always names ANGLE |
| **`ro.boot.qemu.virtiowifi`** readable early in boot | The emulated Wi-Fi needs it to start | Nothing. It is deleted once `wlan0` appears (9.3 s on the reference device, 30 s cap) |
| **Hardware is x86_64**: `uname()`, the ABI list, `/proc/cpuinfo` (`AuthenticAMD`, `hypervisor` flag) | Not spoofed. The build claims a Pixel 8 on hardware no Pixel 8 has | Nothing yet |
| **ARM translator**, when ARM apps are on | It cannot be fully hidden while it runs | Off by default: ARM-only apps then fail with `UnsatisfiedLinkError`. Turn on **Run ARM apps** in the WebUI (or `native_bridge keep`) and reboot. Apps then read no `ro.dalvik.vm.native.bridge` and no ABI list keys, arm64 apps read `aarch64` from `uname()`, and the ELF headers of `libc.so`, `linker64` and `libandroid_runtime.so` read arm64. What stays: the bridge in every app's memory map, renamed `libsysglue.so`. Do not run Treat Wheel or BreWheel then, it hangs apps |
| **Frida cannot attach** to apps, when ARM apps are on | The `linker64` and `libc.so` header redirects hand Frida the arm64 files, and its bootstrapper or agent crashes. Root processes and Settings (uid 1000) attach fine | Turn **Run ARM apps** off while you use Frida. *Untested:* turning "Umount modules" off in KernelSU for that one app |
| **Host clipboard sync** off | It needs `ro.boot.qemu`, which is deleted | Turn on **Sync the host clipboard** (or `boot_qemu keep`) and reboot. Apps then see `Build.IS_EMULATOR` as true |
| **Device name** back to `sdk_gphone64_x86_64` after a settings reset | Root cannot replace the default the system set | Reboot; the name is written again |
| **Root** | Out of scope: NoEmulator hides the emulator, not KernelSU or SUSFS | Use a root-hiding module |
| **Most property changes apply to everyone**, `adb shell` included | The module edits the real property areas. Only the ABI and bridge keys and seven `init.svc.*` keys are hidden from apps alone | Read `module/artifacts.conf` and your user config to know which values are real |
| **37 emulator-named properties** seen from `adb shell` | `init.svc.*`, `init.svc_debug_pid.*` and `ro.boottime.*` names of the emulator's services, set by init. The seven `init.svc.*` keys apps can read are hidden from apps | Nothing. An app started during boot, or within about 5 seconds of a service state change, can read an old service state |
| **Emulator-named HAL files** in `/vendor/lib64/hw`, for an app with "Umount modules" off | They are hidden only from apps KernelSU umounts modules for. `mapper.ranchu.so` is unlisted but still opens | Keep "Umount modules" on for detector apps |
