#!/system/bin/sh
# Apply the artifact rules, before zygote starts.
#
# This stage matters: the detector compares a snapshot taken at app startup against
# the main process, and deleting ro.dalvik.vm.native.bridge only stops the bridge
# loading if it happens before zygote reads it.

MODDIR=${0%/*}
exec >"$MODDIR/apply.log" 2>&1

echo "NoEmulator $(date -u)"

# Self-disable after a boot that never completed.
#
# v0.1.0 boot-looped a tester's device, and a module distributed to other people
# must not need a working adb to recover from that. service.sh clears this marker
# once sys.boot_completed is set, so finding it here means the previous boot
# applied these rules and never came up.
BOOT_MARKER="$MODDIR/booting"
if [ -f "$BOOT_MARKER" ]; then
    rm -f "$BOOT_MARKER"
    : > "$MODDIR/disable"
    echo "previous boot did not complete; NoEmulator disabled itself"
    sh "$MODDIR/lib/module_status.sh" "Disabled itself: the last boot did not complete. Re-enable it to try again."
    exit 1
fi
: > "$BOOT_MARKER"

# KernelSU runs each module's post-fs-data.sh in directory order, unsorted and one
# at a time (ksud module.rs, foreach_module), so susfs_lkm_x64's loader may not
# have run yet. Measured 2026-10-20: after a reinstall of that module, this script
# ran first and applied nothing. Its loader is safe to run early: it does nothing
# when susfs is already up, and honours its own disable and remove flags.
SUSFS_LOADER=/data/adb/modules/susfs_lkm_x64/post-fs-data.sh
if [ ! -e /proc/susfs_path ] && [ -f "$SUSFS_LOADER" ]; then
    echo "susfs not loaded yet; running its loader first"
    sh "$SUSFS_LOADER"
fi

if [ ! -e /proc/susfs_path ]; then
    echo "susfs not loaded; nothing applied"
    exit 1
fi

. "$MODDIR/lib/user_config.sh"
RULES="$(sh "$MODDIR/lib/generate_rules.sh" "$MODDIR/artifacts.conf" "$NOEMULATOR_USER_CONFIG")" || {
    echo "artifacts.conf or the user config is invalid; nothing applied"
    exit 1
}

# Point the kept native bridge at the name the installer staged.
#
# Zygote loads the file ro.dalvik.vm.native.bridge names, and every app's
# /proc/self/maps carries that name, so the stock name is an artifact. The name is
# set only when the copy is in this module: a property naming a file that does not
# exist makes every ARM app fail to start. This runs here rather than later
# because zygote reads the property once, at start.
noemulator_native_bridge_name() {
    bridge_name_file="$1"
    bridge_name_staged="$MODDIR/system/lib64/$bridge_name_file"

    if [ ! -e "$bridge_name_staged" ]; then
        echo "native bridge: no staged $bridge_name_file; the name is left as it is"
        return 0
    fi

    /data/adb/ksu/bin/resetprop ro.dalvik.vm.native.bridge "$bridge_name_file"
}

# Hide a path from the apps KernelSU umounts modules for. A path this image does
# not have is skipped, not failed: there is nothing to hide, and the node refuses
# the write. The node's verb is 'add', not the CLI's 'add_sus_path'
# (susfs4ksu-lkm-x64 PROC_INTERFACES.en.md, /proc/susfs_path). The CLI spelling
# returns EINVAL, which cost a boot to find.
noemulator_hide() {
    hide_path="$1"

    if [ ! -e "$hide_path" ]; then
        echo "hide: no $hide_path; skipped"
        return 0
    fi

    echo "add $hide_path" > /proc/susfs_path
}

# stat is called as toybox explicitly. busybox stat has no %C and prints the
# literal letter 'C', which is what left the v0.4.0 nodes mislabelled.
NOEMULATOR_STAT=/system/bin/toybox

# Set one SELinux label on one path. A path this image does not have is skipped,
# as for hide. The label is read back, because a chcon that reports success on a
# path whose label did not change would leave the artifact with nothing failing.
noemulator_relabel() {
    relabel_path="$1"
    relabel_context="$2"

    if [ ! -e "$relabel_path" ]; then
        echo "relabel: no $relabel_path; skipped"
        return 0
    fi

    chcon "$relabel_context" "$relabel_path" || return 1
    relabel_now=$("$NOEMULATOR_STAT" stat -c '%C' "$relabel_path" 2>/dev/null)
    [ "$relabel_now" = "$relabel_context" ] && return 0
    echo "relabel: $relabel_path reads '$relabel_now', not $relabel_context"
    return 1
}

# Each rule logs its own failure rather than aborting the run: a device node that
# is absent on this image should not stop the property rules being applied.
#
# The redirects are left to post-mount.sh. The module's /vendor overlay is not
# mounted yet at this stage, so a redirect naming a file inside it finds nothing
# and is skipped; measured, that is what made v0.4.0's mapper rule fail. By
# post-mount the overlay is up and zygote still does not exist.
echo "$RULES" | grep -v -e '^noemulator_redirect ' -e '^noemulator_angle ' \
    -e '^noemulator_delprop_after_wifi ' -e '^noemulator_delprop_once_set ' \
    -e '^noemulator_uname_machine ' -e '^noemulator_app_delprop ' \
    -e '^noemulator_setting ' | while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    eval "$rule" || echo "failed: $rule"
done

# Deleting a property leaves its name orphaned in the raw property area. Rebuilding
# the areas removes that residue; measured in docs/research/spike-property-mechanism.md.
/data/adb/ksu/bin/resetprop -c --force

echo "done"
