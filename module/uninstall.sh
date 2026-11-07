#!/system/bin/sh
# Hand off the state that outlives the module.
#
# Everything else NoEmulator does dies with it. The susfs rules live in the
# kernel and are gone at the next boot; the cloned device nodes and the app
# property view's copies (/dev/.prop_view) are in tmpfs, and ksud prunes a
# removed module before any module's stage script runs, so the boot that runs
# this never builds the copies again (KernelSU-Next userspace/ksud/src/
# init_event.rs:71, module.rs:427); the staged libraries are inside the module tree; the property edits are
# applied per boot and are not persisted anywhere. Acceptance criterion 11 was
# measured passing on all of that.
#
# The `angle` and `setting` directives are the exceptions. Both write Android's
# settings database, which is not part of the module tree: removing the module
# would leave packages on ANGLE forever (issue #25) and settings rows holding
# values NoEmulator chose (issue #28).
#
# This script cannot undo it. Measured on the target: ksud runs uninstall.sh at
# uptime 6.76s with sys.boot_completed unset, then deletes this directory.
# `settings` is a client of system_server, which does not exist that early --
# `settings get` answered rc=20. What this script can do, and the only thing it
# does, is copy the knowledge out before the directory goes and start something
# that will still be alive when the framework is.
#
# Nothing to undo stages nothing and leaves no trace of having run.

MODDIR=${0%/*}
# Overridable so the suite can run this script on a host; the defaults are the
# only values used on a device.
NOEMULATOR_CLEANUP_DIR=${NOEMULATOR_CLEANUP_DIR:-/data/adb/noemulator-angle-cleanup}
NOEMULATOR_CLEANUP_HOOK=${NOEMULATOR_CLEANUP_HOOK:-/data/adb/service.d/noemulator-angle-cleanup.sh}

NOEMULATOR_RESTORE_DIR=${NOEMULATOR_RESTORE_DIR:-/data/adb/noemulator-setting-restore}
NOEMULATOR_RESTORE_HOOK=${NOEMULATOR_RESTORE_HOOK:-/data/adb/service.d/noemulator-setting-restore.sh}

. "$MODDIR/lib/user_config.sh"

# Staged from the record, not from the config, and before anything that reads
# the config. The record is what says which rows this module wrote; the config
# may no longer name a key it set, or may not parse at all (finding 2, finding 5).
noemulator_stage_setting_restore() {
    # A missing library would end the whole script at the `.`, angle cleanup
    # included, so it is checked rather than trusted.
    [ -r "$MODDIR/lib/setting_record.sh" ] || return 0
    . "$MODDIR/lib/setting_record.sh"
    for setting_stage_file in "$NOEMULATOR_SETTING_RECORD_DIR"/*; do
        [ -f "$setting_stage_file" ] && break
    done
    [ -f "$setting_stage_file" ] || return 0

    mkdir -p "$NOEMULATOR_RESTORE_DIR" "${NOEMULATOR_RESTORE_HOOK%/*}" || return 0
    cp "$MODDIR/lib/setting_record.sh" "$MODDIR/lib/setting_restore.sh" "$NOEMULATOR_RESTORE_DIR/" || return 0
    chmod 0700 "$NOEMULATOR_RESTORE_DIR"

    cat > "$NOEMULATOR_RESTORE_HOOK" <<HOOK
#!/system/bin/sh
# Staged by NoEmulator's uninstall.sh. Removes itself once every settings row
# it was left to restore has been restored.
exec sh $NOEMULATOR_RESTORE_DIR/setting_restore.sh
HOOK
    chmod 0700 "$NOEMULATOR_RESTORE_HOOK"

    sh "$NOEMULATOR_RESTORE_DIR/setting_restore.sh" &
}

# Each staging step returns rather than exiting, so that one with nothing to do
# does not stop the next from running. The angle step used to end the script
# when the config named no package -- which is what ships -- and anything placed
# after it would never have run (docs/review/0003-triage.md, finding 2).
noemulator_stage_angle_cleanup() {
    # artifacts.conf and lib/ are still readable here; measured, and the reason
    # this runs before the delete rather than after. Failure to read the config
    # is not fatal: there is nothing left to uninstall either way, and aborting a
    # removal over it would strand the module.
    angle_stage_rules="$(sh "$MODDIR/lib/generate_rules.sh" "$MODDIR/artifacts.conf" "$NOEMULATOR_USER_CONFIG" 2>/dev/null)" || return 0

    angle_stage_packages=$(
        echo "$angle_stage_rules" |
            sed -n "s/^noemulator_angle '\\(.*\\)'$/\\1/p" |
            tr '\n' ',' | sed 's/,$//'
    )

    [ -n "$angle_stage_packages" ] || return 0

    mkdir -p "$NOEMULATOR_CLEANUP_DIR" "${NOEMULATOR_CLEANUP_HOOK%/*}" || return 0
    cp "$MODDIR/lib/angle_settings.sh" "$MODDIR/lib/angle_cleanup.sh" "$NOEMULATOR_CLEANUP_DIR/" || return 0
    echo "$angle_stage_packages" > "$NOEMULATOR_CLEANUP_DIR/packages"
    chmod 0700 "$NOEMULATOR_CLEANUP_DIR"

    # The hook is what makes the retry real: ksud runs /data/adb/service.d on
    # every boot, so a device powered off before the framework came up still
    # gets the setting corrected. The cleanup deletes this file and its own
    # directory once the write succeeds.
    cat > "$NOEMULATOR_CLEANUP_HOOK" <<HOOK
#!/system/bin/sh
# Staged by NoEmulator's uninstall.sh. Removes itself once the ANGLE selection
# it was left to correct has been corrected.
exec sh $NOEMULATOR_CLEANUP_DIR/angle_cleanup.sh
HOOK
    chmod 0700 "$NOEMULATOR_CLEANUP_HOOK"

    # Also start it now, so the usual case is fixed within a minute of this boot
    # rather than at the next one. Backgrounded: this script is holding up the
    # removal, and the cleanup waits for the framework.
    sh "$NOEMULATOR_CLEANUP_DIR/angle_cleanup.sh" &
}

noemulator_stage_setting_restore
noemulator_stage_angle_cleanup

# Last, because the angle staging above reads it. Removal means removal: a
# reinstall starts from the defaults (spec #59, Q8).
rm -f "$NOEMULATOR_USER_CONFIG"
