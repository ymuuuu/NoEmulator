#!/system/bin/sh
# Clear the boot marker that post-fs-data.sh sets, once the system is actually up,
# and finish the stages that need a booted system: the settings rows and the app
# property view refresh.
#
# A marker still present at the next post-fs-data means the rules applied and the
# boot never finished, and the module disables itself. Giving up after four minutes
# rather than waiting forever is deliberate: a boot that slow has failed, and the
# marker should survive to trigger the self-disable.
#
# The redirects were applied from this script in v0.4.1 and landed 20 seconds
# after post-mount, by which time a detector that was already running had opened
# the goldfish nodes under their real names. They are applied from post-mount.sh
# now, before zygote exists. The property view's copies are built there too; they
# are rebuilt from here because a copy is frozen when it is registered and another
# module may write the area from its own service.sh.

MODDIR=${0%/*}

attempts=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 120 ] || exit 1
    sleep 2
done

rm -f "$MODDIR/booting"

# Put the packages named by 'angle' directives on ANGLE, and write the rows named
# by 'setting' directives.
#
# These are the rules that have to run after boot: `settings` is a client of
# system_server, which does not exist at post-mount. Everything else is applied
# earlier, from post-fs-data.sh and post-mount.sh.
#
# The two keys are comma-separated lists read at app start, so a package added
# here takes effect the next time that app launches -- no reboot needed, and no
# race of the kind that made v0.4.1's redirects miss
# (docs/adr/0013-apply-redirects-at-post-mount.md). An app already running keeps
# the driver it loaded.
exec >>"$MODDIR/apply.log" 2>&1

noemulator_angle_packages=""

noemulator_angle() {
    # Accumulated rather than written per call: writing one package would drop
    # every other one, because the setting is a single comma-separated list.
    if [ -z "$noemulator_angle_packages" ]; then
        noemulator_angle_packages="$1"
    else
        noemulator_angle_packages="$noemulator_angle_packages,$1"
    fi
}

# The two settings keys are a shared surface: lib/angle_settings.sh adds to them
# here and removes from them at uninstall, and both have to agree about the
# format. v0.4.6 wrote the package list straight, which replaced whatever was
# there -- a package the user had put on ANGLE themselves was dropped for as
# long as NoEmulator was installed (issue #25).
. "$MODDIR/lib/angle_settings.sh"

noemulator_apply_angle() {
    [ -n "$noemulator_angle_packages" ] || return 0

    noemulator_angle_add "$noemulator_angle_packages" || {
        echo "angle: could not write the settings keys"
        return 1
    }
    echo "angle: $noemulator_angle_packages"
}

. "$MODDIR/lib/user_config.sh"
NOEMULATOR_RULES="$(sh "$MODDIR/lib/generate_rules.sh" "$MODDIR/artifacts.conf" "$NOEMULATOR_USER_CONFIG")" || {
    echo "artifacts.conf or the user config is invalid; no angle or setting rules applied"
    exit 1
}

echo "$NOEMULATOR_RULES" | grep '^noemulator_angle ' > "$MODDIR/angle.rules"
while IFS= read -r noemulator_rule; do
    [ -n "$noemulator_rule" ] || continue
    eval "$noemulator_rule"
done < "$MODDIR/angle.rules"
rm -f "$MODDIR/angle.rules"

noemulator_apply_angle

# A restore staged by an uninstall that was reinstalled over before it ran must
# not run now: the module owns the rows again, and the record it would work
# from is still in place (finding 7).
rm -f /data/adb/service.d/noemulator-setting-restore.sh
rm -rf /data/adb/noemulator-setting-restore

# Each row is decided on its own: a key whose read fails is skipped this boot and
# the rest still apply. The pipe's subshell is harmless here, unlike for angle,
# because nothing accumulates across lines.
. "$MODDIR/lib/setting_record.sh"

echo "$NOEMULATOR_RULES" | grep '^noemulator_setting ' | while IFS= read -r noemulator_rule; do
    eval "$noemulator_rule"
done

# A key with a record that the config no longer sets is put back, as uninstall
# would, so a release that stops setting a key does not strand its value.
noemulator_setting_restore_unconfigured "$(noemulator_setting_ids "$NOEMULATOR_RULES")"

# The once-set deletions wait up to NOEMULATOR_ONCE_SET_TIMEOUT plus a settle
# period after post-mount (lib/delete_once_set.sh), so 60 seconds after boot
# covers them; a boot where they never log 'done' is flagged as unfinished.
noemulator_status_waited=0
while ! grep -q '^delprop_once_set done' "$MODDIR/apply.log" &&
    [ "$noemulator_status_waited" -lt 60 ]; do
    noemulator_status_waited=$((noemulator_status_waited + 2))
    sleep 2
done

# Rebuild every app property view copy now that boot is up and the late
# deletions above have landed. A copy is frozen when post-mount registers it, and
# COPG-VD's service.sh writes ro.build.version.security_patch into build_prop
# after that: Java sees the new value, an app's native read of the area does not,
# and vdinfos scores that MISMATCH. This still misses a write that lands after
# this point, and an app started before it keeps the old copy until it restarts.
#
# The init service states keep changing after this, so the watcher rebuilds
# whenever their area does, for the rest of the boot. It reads the rules file on
# each rebuild, so the file stays; the next post-mount writes it afresh.
echo "$NOEMULATOR_RULES" | grep '^noemulator_app_delprop ' > "$MODDIR/app_property_view.rules"
if [ -s "$MODDIR/app_property_view.rules" ]; then
    . "$MODDIR/lib/app_property_view.sh"
    noemulator_app_property_view_refresh "$MODDIR/app_property_view.rules"
    noemulator_app_property_view_watch "$MODDIR/app_property_view.rules" &
else
    rm -f "$MODDIR/app_property_view.rules"
fi

# Flag the module card once the last stage has had its chance to finish.
sh "$MODDIR/lib/module_status.sh"
