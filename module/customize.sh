#!/system/bin/sh
# Refuse to install where NoEmulator cannot work, and stage the files the rules name.
#
# A module that installs cleanly and then hides nothing is the worst outcome: the
# user ships an emulator believing it is covered. Every check aborts rather than warn.

abort_with() {
    ui_print "! $1"
    abort   "! NoEmulator not installed."
}

# stat is called as toybox explicitly. The installer's shell resolves `stat` to
# busybox, whose stat has no %C: it prints the literal letter 'C'. That is what
# left the v0.4.0 replacement nodes mislabelled and blocked the boot.
NOEMULATOR_STAT=/system/bin/toybox

# Staged file and the SELinux label it must carry, one 'path label' per line.
# Labels are applied at the end rather than per file: set_perm_recursive puts the
# module tree's default label back over the whole overlay, so a label set before
# the last recursive pass is lost. v0.4.1 shipped with both staged libraries
# reading u:object_r:system_file:s0 for exactly that reason.
NOEMULATOR_STAGED_LABELS="$TMPDIR/noemulator_staged_labels"

# Where a path on the live filesystem is served from inside the module.
#
# KernelSU serves $MODPATH/system over /system and $MODPATH/vendor over /vendor.
# Staging a /vendor file under $MODPATH/system/vendor also works, but the
# installer then relocates that subtree to $MODPATH/vendor and the file loses the
# label set on it. Writing it where it will finally live avoids the move.
noemulator_overlay_path() {
    echo "$MODPATH$1"
}

noemulator_stage_file() {
    stage_source="$1"
    stage_destination="$2"

    stage_label=$("$NOEMULATOR_STAT" stat -c '%C' "$stage_source" 2>/dev/null)
    case "$stage_label" in
        *:*:*:*) ;;
        *) abort_with "Could not read the SELinux label of $stage_source." ;;
    esac

    mkdir -p "${stage_destination%/*}"
    cp "$stage_source" "$stage_destination" || abort_with "Could not copy $stage_source."
    printf '%s %s\n' "$stage_destination" "$stage_label" >> "$NOEMULATOR_STAGED_LABELS"
}

# A library an app maps carries same_process_hal_file, not the module tree's
# default. An app that is allowed the original and denied the copy is the whole
# failure, so the label is read back and a mismatch aborts the install rather
# than shipping a module whose rules point at a file nothing may open.
noemulator_apply_staged_labels() {
    [ -s "$NOEMULATOR_STAGED_LABELS" ] || return 0

    for overlay_root in "$MODPATH/system" "$MODPATH/vendor"; do
        [ -d "$overlay_root" ] && set_perm_recursive "$overlay_root" 0 0 0755 0644
    done

    while read -r staged_path staged_label; do
        set_perm "$staged_path" 0 0 0644 "$staged_label"
        [ "$("$NOEMULATOR_STAT" stat -c '%C' "$staged_path")" = "$staged_label" ] ||
            abort_with "$staged_path did not take the label $staged_label."
    done < "$NOEMULATOR_STAGED_LABELS"
}

# Present the Vulkan HAL under the name artifacts.conf claims.
#
# artifacts.conf repoints ro.hardware.vulkan, and libvulkan.so then opens
# /vendor/lib64/hw/vulkan.<variant>.so. The variant is read back out of
# artifacts.conf rather than written here as well, so the two cannot drift.
#
# The source is found by looking, not by assuming it is called 'ranchu' -- an
# image that ships the HAL under another name still has to work. The file the
# module is about to install is skipped, so a reinstall does not copy its own
# output over itself.
#
# Names are prefixed because this runs inside the installer's own shell, where a
# function has no scope of its own and a bare 'source' or 'target' would overwrite
# whatever the caller is holding.
install_vulkan_hal() {
    vulkan_variant=$(sed -n 's/^[[:space:]]*setprop[[:space:]][[:space:]]*ro\.hardware\.vulkan[[:space:]][[:space:]]*//p' "$MODPATH/artifacts.conf")
    [ -n "$vulkan_variant" ] || abort_with "artifacts.conf has no 'setprop ro.hardware.vulkan' line."

    vulkan_target="vulkan.$vulkan_variant.so"
    vulkan_source=""
    for vulkan_candidate in /vendor/lib64/hw/vulkan.*.so; do
        [ -f "$vulkan_candidate" ] || continue
        if [ "${vulkan_candidate##*/}" != "$vulkan_target" ]; then
            vulkan_source="$vulkan_candidate"
            break
        fi
    done
    [ -n "$vulkan_source" ] || abort_with "No Vulkan HAL in /vendor/lib64/hw to rename."

    noemulator_stage_file "$vulkan_source" \
        "$(noemulator_overlay_path "/vendor/lib64/hw/$vulkan_target")"

    ui_print "- Vulkan HAL ${vulkan_source##*/} installed as $vulkan_target"
}

# Present the kept ARM native bridge under the name artifacts.conf claims.
#
# Zygote loads the library ro.dalvik.vm.native.bridge names, and every app maps it,
# so the stock name is an artifact in /proc/self/maps. The name is read back out of
# artifacts.conf rather than written here as well, so the property and the file
# cannot drift.
#
# The copy is staged whether or not `native_bridge keep` is set now: the user can
# turn ARM apps on later in the WebUI, and that must not need a reinstall. An image
# without the bridge still installs; the rename is then skipped, and post-fs-data
# leaves the property alone because the staged copy is absent.
install_native_bridge_copy() {
    bridge_name=$(sed -n 's/^[[:space:]]*native_bridge_name[[:space:]][[:space:]]*//p' "$MODPATH/artifacts.conf")
    [ -n "$bridge_name" ] || return 0

    bridge_source=/system/lib64/libndk_translation.so
    if [ ! -f "$bridge_source" ]; then
        ui_print "- No $bridge_source on this image; native bridge rename skipped"
        return 0
    fi

    noemulator_stage_file "$bridge_source" \
        "$(noemulator_overlay_path "/system/lib64/$bridge_name")"

    ui_print "- Native bridge ${bridge_source##*/} installed as $bridge_name"
}

# Present the EGL driver under the name artifacts.conf claims.
#
# libEGL.so opens libEGL_<value>.so, libGLESv1_CM_<value>.so and
# libGLESv2_<value>.so from /vendor/lib64/egl, where <value> is ro.hardware.egl.
# A value with no matching files aborts every GL process, so all three are staged
# or the install stops. The stock suffix is found by looking, as for the Vulkan
# HAL, and the module's own output is skipped on a reinstall.
install_egl_driver() {
    egl_variant=$(sed -n 's/^[[:space:]]*setprop[[:space:]][[:space:]]*ro\.hardware\.egl[[:space:]][[:space:]]*//p' "$MODPATH/artifacts.conf")
    [ -n "$egl_variant" ] || return 0

    egl_suffix=""
    for egl_candidate in /vendor/lib64/egl/libEGL_*.so; do
        [ -f "$egl_candidate" ] || continue
        egl_candidate_suffix=${egl_candidate##*/libEGL_}
        egl_candidate_suffix=${egl_candidate_suffix%.so}
        if [ "$egl_candidate_suffix" != "$egl_variant" ]; then
            egl_suffix="$egl_candidate_suffix"
            break
        fi
    done
    [ -n "$egl_suffix" ] || abort_with "No EGL driver in /vendor/lib64/egl to rename."

    for egl_library in libEGL libGLESv1_CM libGLESv2; do
        [ -f "/vendor/lib64/egl/${egl_library}_$egl_suffix.so" ] ||
            abort_with "/vendor/lib64/egl/${egl_library}_$egl_suffix.so is missing."
        noemulator_stage_file "/vendor/lib64/egl/${egl_library}_$egl_suffix.so" \
            "$(noemulator_overlay_path "/vendor/lib64/egl/${egl_library}_$egl_variant.so")"
    done

    ui_print "- EGL driver '$egl_suffix' installed as '$egl_variant'"
}

# Install a copy of every library an artifacts.conf redirect points at.
#
# A 'redirect' whose replacement is a device node has that node made for it at
# post-mount, from the target's own major and minor. A replacement that is a
# library has no such source: the file has to exist on disk before the rule is
# written, or the rule is skipped. Copying it here, through the module's overlay,
# is what makes it exist.
#
# A replacement the image itself carries is left alone. The ELF-header rules point
# at the image's real arm64 libraries, and copying the x86_64 target over one would
# replace the file the rule exists to serve (ADR 0026). A replacement the installed
# NoEmulator delivers also exists during an update, and is staged again: the old
# module's copy goes away at the reboot.
#
# The pairs are read out of artifacts.conf for the same reason the Vulkan variant
# is: the name is written once, and a rule and its file cannot disagree.
# The lines are read from a file rather than straight off a pipe: a pipeline runs
# its loop in a subshell, where abort_with can only kill the subshell and the
# install carries on as if the copy had worked.
install_redirect_libraries() {
    redirect_lines="$TMPDIR/noemulator_redirect_lines"
    sed -n 's/^[[:space:]]*redirect[[:space:]][[:space:]]*//p' "$MODPATH/artifacts.conf" > "$redirect_lines"

    # redirect_rest absorbs the uid_scheme and the flags after it, so a line with
    # trailing fields does not spill them into redirect_replacement.
    # shellcheck disable=SC2034
    while read -r redirect_target redirect_replacement redirect_rest; do
        case "$redirect_replacement" in
            /vendor/lib*/*|/system/lib*/*) ;;
            *) continue ;;
        esac
        if [ -e "$redirect_replacement" ] &&
            [ ! -e "/data/adb/modules/noemulator$redirect_replacement" ]; then
            ui_print "- ${redirect_replacement##*/} is already on the image; not staged"
            continue
        fi
        [ -f "$redirect_target" ] || {
            ui_print "- No $redirect_target on this image; its redirect will be skipped"
            continue
        }

        noemulator_stage_file "$redirect_target" \
            "$(noemulator_overlay_path "$redirect_replacement")"

        ui_print "- ${redirect_target##*/} also installed as ${redirect_replacement##*/}"
    done < "$redirect_lines"
}

ui_print "- NoEmulator $(grep_prop version "$MODPATH/module.prop")"

if [ "$ARCH" != "x64" ]; then
    abort_with "This build is x86_64 only. Detected architecture: $ARCH"
fi

# The kernel module creates these nodes when it loads. Their presence is the only
# check that does not depend on the prerequisite's CLI, which it publishes later in
# its own service.sh.
if [ ! -e /proc/susfs_path ]; then
    abort_with "susfs4ksu-lkm-x64 is not loaded. Install it first, reboot, then install NoEmulator."
fi

ui_print "- susfs kernel module present"

# v0.0.7 added the no_reverse flag the redirects ask for (ADR 0025). An older
# build still works, with "Umount modules" off per detector app, so this warns
# rather than aborts. The version is read from the loader module's own
# module.prop; a kernel module loaded some other way has none, and is not judged.
NOEMULATOR_SUSFS_PROP=/data/adb/modules/susfs_lkm_x64/module.prop
if [ -f "$NOEMULATOR_SUSFS_PROP" ] &&
    [ "$(grep_prop versionCode "$NOEMULATOR_SUSFS_PROP")" -lt 7 ] 2>/dev/null; then
    ui_print "! susfs4ksu-lkm-x64 $(grep_prop version "$NOEMULATOR_SUSFS_PROP") is older than v0.0.7."
    ui_print "  Redirects then hide nothing from apps with \"Umount modules\" on."
    ui_print "  Update it, or turn \"Umount modules\" off for each detector app."
fi

# v0.0.8 added the app_only open-redirect flag. The libc.so ELF-header redirect
# needs it: without it, a program an app executes gets the arm64 libc and fails to
# link. Only that rule is skipped, so this warns rather than aborts. The user
# config is read later in the install, so the warning does not test for
# 'native_bridge keep' (ADR 0026).
if [ -f "$NOEMULATOR_SUSFS_PROP" ] &&
    [ "$(grep_prop versionCode "$NOEMULATOR_SUSFS_PROP")" -lt 8 ] 2>/dev/null; then
    ui_print "! susfs4ksu-lkm-x64 $(grep_prop version "$NOEMULATOR_SUSFS_PROP") is older than v0.0.8."
    ui_print "  The libc.so header redirect needs app_only and will be skipped."
    ui_print "  The uname machine spoof needs that same build's uname_machine node."
    ui_print "  Hiding properties from apps alone needs its prop_view node."
fi

# NoMount delivers a module's files by redirecting paths, so nothing NoEmulator
# installs appears in an app's mount table. KernelSU's own delivery mounts them, and a
# visible module mount is scored (ADR 0014). A warning, not an abort: the rules work
# whichever way the files arrive — only the mount artifact differs.
if [ -d /data/adb/modules/nomount ] && [ ! -f /data/adb/modules/nomount/disable ]; then
    ui_print "- NoMount present"
else
    ui_print "! NoMount is not installed or is disabled."
    ui_print "  The rules will still work. But KernelSU will deliver this module's files"
    ui_print "  by mounting them, and a detector scores a visible module mount."
    ui_print "  See the README."
fi

ui_print "- Known limits: x86_64 apps still read x86_64 from uname, root is not"
ui_print "  hidden, and ARM-only apps lose their native libraries unless you keep"
ui_print "  the native bridge. See the README."

# Choices an older version saved inside the module would be lost with the file
# this install replaces; move them to the user config first (spec #59).
. "$MODPATH/lib/user_config.sh"
sh "$MODPATH/lib/carry_over.sh" /data/adb/modules/noemulator "$MODPATH/artifacts.conf" |
    while IFS= read -r carry_report; do
        case "$carry_report" in
            'carried '*) ui_print "- Kept your choice: ${carry_report#carried }" ;;
            *) ui_print "! Not kept, add it to $NOEMULATOR_USER_CONFIG if still wanted: ${carry_report#not carried }" ;;
        esac
    done

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/post-mount.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/lib/generate_rules.sh" 0 0 0755

: > "$NOEMULATOR_STAGED_LABELS"
install_vulkan_hal
install_native_bridge_copy
install_egl_driver
install_redirect_libraries
noemulator_apply_staged_labels
