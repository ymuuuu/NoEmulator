#!/system/bin/sh
# Give app processes their own copy of a property area, with keys deleted.
#
# A property is not hidden by editing its value: detectors score a list that
# disagrees with itself. A key is omitted from a
# copy of the whole area instead, and app processes are given that copy
# (docs/adr/0029-app-property-view-by-area-swap.md). Root, adb shell and zygote
# keep the real area, which is why this is not a global delete.
#
# The kernel side is /proc/susfs_prop_view: it maps the copy over an app's
# inherited mapping of the area when the app takes its uid. /proc/susfs_open_redirect
# gives a program the app runs (getprop) the same copy, so the app's in-process
# read and its getprop read agree (docs/research/spike-app-property-view.md).
#
# Sourced by post-mount.sh, which builds and registers the copies, and by
# service.sh, which rebuilds them once boot has finished. A copy is frozen when
# the kernel opens it, and another module may write one of these areas from its
# own service.sh. post-mount has to run after every module's post-fs-data
# property writes, because KernelSU does not sort those scripts; post-mount is
# still before zygote.
#
# A line starting 'failed: ' is one the WebUI counts as a failed rule and health
# names (lib/options_webui.sh): an area the view was meant to cover and does not.
# A skip that is not a failure has no prefix: no prop_view node on public susfs,
# or a key refused because apps cannot read its area.
#
# Nothing here touches the real area. Every resetprop call runs inside one private
# mount namespace and dies with it, so no resetprop is called outside that
# namespace in this library.

# Where the copies live. /dev is tmpfs, and a copy relabelled to its area's type is
# one an app's getprop may read through the redirect; under /data/adb
# (adb_data_file) it may not (ADR 0029). Writing a plain file here from inside the
# private namespace works: only the mounts are private. Being tmpfs is also what
# removes them on uninstall (uninstall.sh).
NOEMULATOR_PROP_VIEW_DIR=/dev/.prop_view

# stat is called as toybox explicitly. At post-mount the shell resolves stat to
# busybox, whose stat has no %C, and chcon would be checked against the literal
# letter C (module/post-mount.sh).
NOEMULATOR_PROP_VIEW_STAT=/system/bin/toybox

NOEMULATOR_PROP_VIEW_MOUNT=/data/adb/ksu/bin/busybox
NOEMULATOR_PROP_VIEW_RESETPROP=/data/adb/ksu/bin/resetprop

NOEMULATOR_PROP_VIEW_NODE=/proc/susfs_prop_view
NOEMULATOR_PROP_VIEW_REDIRECT_NODE=/proc/susfs_open_redirect
NOEMULATOR_PROP_VIEW_HIDE_NODE=/proc/susfs_path

# Only an area an app can read normally may be swapped. Redirecting one it cannot
# read is itself visible: with vendor_default_prop redirected, vdinfos listed 48
# hidden keys (docs/research/spike-app-property-view.md). A fixed list, because
# whether an app may read an area is not decided from property_contexts at boot.
# init_service_status_private_prop is granted to every core domain, apps
# included, and a real phone's apps read it (docs/research/spike-init-svc-props.md).
noemulator_prop_view_context_allowed() {
    case "$1" in
        build_prop|default_prop|build_vendor_prop|dalvik_config_prop) return 0 ;;
        init_service_status_private_prop) return 0 ;;
    esac
    return 1
}

# Areas whose keys keep changing after boot: init writes init.svc.<name> each
# time a service starts or stops. Their copy is not built at post-mount, where
# most services have not started, and is rebuilt by the watcher below when the
# real area changes (docs/adr/0032-a-view-of-the-init-service-states.md).
NOEMULATOR_PROP_VIEW_LIVE_CONTEXTS="init_service_status_private_prop"

# How often the watcher compares the live areas with what their copies were
# built from, in seconds. An app started within this long of a service change
# can still get the old state.
NOEMULATOR_PROP_VIEW_WATCH_INTERVAL=5

# Pick a property of <context> that is not being deleted, for resetprop to find
# the area by. A property with a value is preferred, since that is one the rebuild
# is known to have read; any other in the same area is the fallback.
noemulator_prop_view_anchor() {
    prop_view_anchor_context="$1"
    prop_view_anchor_deleted="$2"
    prop_view_anchor=""
    prop_view_anchor_with_value=""

    # The full listing is '[<name>]: [<context>]', one property per line.
    while IFS= read -r prop_view_anchor_line; do
        case "$prop_view_anchor_line" in
            '['*']: ['*']') ;;
            *) continue ;;
        esac
        prop_view_anchor_name=${prop_view_anchor_line#\[}
        prop_view_anchor_name=${prop_view_anchor_name%%]: [*}
        prop_view_anchor_line_context=${prop_view_anchor_line#*]: [}
        prop_view_anchor_line_context=${prop_view_anchor_line_context%]}
        [ "$prop_view_anchor_line_context" = "u:object_r:$prop_view_anchor_context:s0" ] || continue
        case "$prop_view_anchor_deleted" in
            *" $prop_view_anchor_name "*) continue ;;
        esac
        [ -n "$prop_view_anchor" ] || prop_view_anchor="$prop_view_anchor_name"
        if [ -n "$(getprop "$prop_view_anchor_name" 2>/dev/null)" ]; then
            prop_view_anchor_with_value="$prop_view_anchor_name"
            break
        fi
    done <<ANCHORS
$prop_view_all_contexts
ANCHORS

    if [ -n "$prop_view_anchor_with_value" ]; then
        echo "$prop_view_anchor_with_value"
    else
        echo "$prop_view_anchor"
    fi
}

# Group the keys in <rules file> by area. $prop_view_contexts holds the areas a
# copy can be built for, $prop_view_deleted the keys to remove, and the file
# named by $prop_view_keys gets one '<context> <key>' line each. An absent or
# unlisted context is skipped with a log line: a view of an area an app cannot
# read is itself visible.
noemulator_prop_view_group() {
    prop_view_group_rules="$1"

    prop_view_all_contexts=$(getprop -Z 2>/dev/null)
    prop_view_contexts=""
    prop_view_deleted=" "
    while IFS= read -r prop_view_rule; do
        [ -n "$prop_view_rule" ] || continue
        prop_view_key=$(echo "$prop_view_rule" | cut -d"'" -f2)
        case "$prop_view_key" in
            ''|*[!A-Za-z0-9._-]*)
                echo "app property view: '$prop_view_key' is not a property name; skipped"
                continue
                ;;
        esac

        # getprop -Z prints just the context, 'u:object_r:<ctx>:s0'.
        prop_view_context=$(getprop -Z "$prop_view_key" 2>/dev/null)
        prop_view_context=${prop_view_context#u:object_r:}
        prop_view_context=${prop_view_context%:s0}
        [ -n "$prop_view_context" ] || prop_view_context="no context"
        if ! noemulator_prop_view_context_allowed "$prop_view_context"; then
            echo "app property view: $prop_view_key is in $prop_view_context, which apps cannot be given a view of; skipped"
            continue
        fi

        prop_view_deleted="$prop_view_deleted$prop_view_key "
        echo "$prop_view_context $prop_view_key" >> "$prop_view_keys"
        case " $prop_view_contexts " in
            *" $prop_view_context "*) ;;
            *) prop_view_contexts="$prop_view_contexts$prop_view_context " ;;
        esac
    done < "$prop_view_group_rules"
}

# Take the live areas out of $prop_view_contexts, into $prop_view_deferred, so
# post-mount builds no copy of them. Each one deferred is logged.
noemulator_prop_view_defer_live() {
    prop_view_deferred=""
    prop_view_kept_contexts=""
    for prop_view_context in $prop_view_contexts; do
        case " $NOEMULATOR_PROP_VIEW_LIVE_CONTEXTS " in
            *" $prop_view_context "*)
                prop_view_deferred="$prop_view_deferred$prop_view_context "
                echo "app property view: $prop_view_context: built once boot is up"
                ;;
            *) prop_view_kept_contexts="$prop_view_kept_contexts$prop_view_context " ;;
        esac
    done
    prop_view_contexts="$prop_view_kept_contexts"
}

# A failed build leaves nothing registered, so the copies it wrote are dropped.
# At post-mount the copies are the view directory itself; on a refresh they are
# a staging directory, and the live copies stay.
noemulator_prop_view_build_cleanup() {
    rm -rf "$prop_view_copies" "$prop_view_dir/.scratch"
}

# Build every copy in one private mount namespace, so no mount here is visible
# outside it. Each area is rebuilt once all its keys are gone. copy dir <1> is
# where the copies are written: the live directory at post-mount, a staging
# directory on a refresh.
noemulator_prop_view_build() {
    prop_view_copies="$1"
    prop_view_built_contexts=""

    # unshare -m alone keeps shared mount propagation: measured, the first
    # attempt's bind reached init's namespace and any process opening an area in
    # the next minute got the edited copy. make-rprivate comes first, before any
    # mount here.
    prop_view_script="$NOEMULATOR_PROP_VIEW_MOUNT mount --make-rprivate / || exit 1
$NOEMULATOR_PROP_VIEW_MOUNT mount -t tmpfs tmpfs '$prop_view_dir/.scratch' || exit 1
cp -R /dev/__properties__/. '$prop_view_dir/.scratch'/ || exit 1
$NOEMULATOR_PROP_VIEW_MOUNT mount --bind '$prop_view_dir/.scratch' /dev/__properties__ || exit 1"

    for prop_view_context in $prop_view_contexts; do
        prop_view_anchor=$(noemulator_prop_view_anchor "$prop_view_context" "$prop_view_deleted")
        case "$prop_view_anchor" in
            ''|*[!A-Za-z0-9._-]*)
                echo "failed: app property view: $prop_view_context: no key left to rebuild the area from"
                continue
                ;;
        esac

        prop_view_script="$prop_view_script
prop_view_context_ok=1"

        # A key the area does not hold yet is already absent from the copy: an
        # init service that has not started has no init.svc key. getprop lists a
        # key with an empty value too, so only a key that is there and would not
        # go fails the area.
        while IFS=' ' read -r prop_view_key_context prop_view_key; do
            [ "$prop_view_key_context" = "$prop_view_context" ] || continue
            prop_view_script="$prop_view_script
$prop_view_resetprop -n -d '$prop_view_key' || ! getprop | grep -qF '[$prop_view_key]: ' || prop_view_context_ok=0"
        done < "$prop_view_keys"

        # -n keeps the property service out of it; -c -Z <anchor> rebuilds the area
        # holding the anchor, which removes the names the deletes orphaned; --force
        # is what the spike measured. A key that would not go, or an area that would
        # not rebuild, leaves a copy that says something the real area does not, so
        # that context is skipped rather than registered.
        prop_view_script="$prop_view_script
if [ \"\$prop_view_context_ok\" -eq 1 ] && $prop_view_resetprop -n -c -Z '$prop_view_anchor' --force; then
    cp /dev/__properties__/u:object_r:$prop_view_context:s0 '$prop_view_copies/$prop_view_context' || { rm -f '$prop_view_copies/$prop_view_context'; echo 'failed: app property view: $prop_view_context: the copy could not be written'; }
else
    echo 'failed: app property view: $prop_view_context: could not remove every key'
fi"
        prop_view_built_contexts="$prop_view_built_contexts$prop_view_context "
    done

    if [ -z "$prop_view_built_contexts" ]; then
        noemulator_prop_view_build_cleanup
        return 1
    fi

    if ! unshare -m sh -c "$prop_view_script"; then
        echo "failed: app property view: the private mount namespace failed"
        noemulator_prop_view_build_cleanup
        return 1
    fi
    rm -rf "$prop_view_dir/.scratch"
}

# The problem with a copy, or nothing when there is none. The label is read back
# rather than trusted, as every replacement in post-mount.sh is: an app denied
# the copy is worse than no rule at all. The size has to match the real area,
# because a copy taken while the area changed does not say what the area says.
noemulator_prop_view_copy_problem() {
    prop_view_check_context="$1"
    prop_view_check_copy="$2"
    prop_view_check_real="/dev/__properties__/u:object_r:$prop_view_check_context:s0"

    chcon "u:object_r:$prop_view_check_context:s0" "$prop_view_check_copy"
    chmod 0444 "$prop_view_check_copy"
    prop_view_label=$("$NOEMULATOR_PROP_VIEW_STAT" stat -c '%C' "$prop_view_check_copy" 2>/dev/null)
    if [ "$prop_view_label" != "u:object_r:$prop_view_check_context:s0" ]; then
        echo "the copy is $prop_view_label, not u:object_r:$prop_view_check_context:s0"
        return 0
    fi

    prop_view_real_size=$("$NOEMULATOR_PROP_VIEW_STAT" stat -c '%s' "$prop_view_check_real" 2>/dev/null)
    prop_view_copy_size=$("$NOEMULATOR_PROP_VIEW_STAT" stat -c '%s' "$prop_view_check_copy" 2>/dev/null)
    if [ -z "$prop_view_real_size" ] || [ "$prop_view_copy_size" != "$prop_view_real_size" ]; then
        echo "the copy is $prop_view_copy_size bytes, not $prop_view_real_size"
    fi
}

# Check each copy and give it its two node rules.
noemulator_prop_view_register() {
    for prop_view_context in $prop_view_built_contexts; do
        prop_view_real="/dev/__properties__/u:object_r:$prop_view_context:s0"
        prop_view_copy="$prop_view_dir/$prop_view_context"

        if [ ! -f "$prop_view_copy" ]; then
            echo "failed: app property view: $prop_view_context: no copy was built"
            continue
        fi

        prop_view_problem=$(noemulator_prop_view_copy_problem "$prop_view_context" "$prop_view_copy")
        if [ -n "$prop_view_problem" ]; then
            echo "failed: app property view: $prop_view_context: $prop_view_problem"
            continue
        fi

        # The redirect first: an app process that already has the area mapped gets
        # the copy from the kernel rule, and one that opens it later gets the same
        # copy from the redirect. A refused write skips the whole context.
        if ! echo "add_open_redirect $prop_view_real $prop_view_copy 3" > "$NOEMULATOR_PROP_VIEW_REDIRECT_NODE" 2>/dev/null; then
            echo "failed: app property view: $prop_view_context: open redirect refused"
            continue
        fi
        if ! echo "add $prop_view_real $prop_view_copy" > "$NOEMULATOR_PROP_VIEW_NODE" 2>/dev/null; then
            echo "failed: app property view: $prop_view_context: prop view refused"
            continue
        fi

        prop_view_count=$(grep -c "^$prop_view_context " "$prop_view_keys")
        echo "app property view: $prop_view_context: $prop_view_count key(s) hidden from apps"
    done
}

# noemulator_app_property_view <rules file>. The file holds one
# "noemulator_app_delprop '<key>'" line per key, as generate_rules.sh emits it.
noemulator_app_property_view() {
    prop_view_rules="$1"
    prop_view_dir="$NOEMULATOR_PROP_VIEW_DIR"
    prop_view_resetprop="$NOEMULATOR_PROP_VIEW_RESETPROP"

    if [ ! -e "$NOEMULATOR_PROP_VIEW_NODE" ] || [ ! -e "$NOEMULATOR_PROP_VIEW_REDIRECT_NODE" ]; then
        echo "app property view: susfs has no prop_view node; skipped"
        return 0
    fi

    rm -rf "$prop_view_dir"
    if ! mkdir -p "$prop_view_dir/.scratch"; then
        echo "failed: app property view: cannot create $prop_view_dir"
        return 0
    fi
    chmod 0711 "$prop_view_dir"
    prop_view_keys="$prop_view_dir/.keys"
    : > "$prop_view_keys"

    # Group the keys by area; a key in an area apps cannot read is refused there.
    noemulator_prop_view_group "$prop_view_rules"
    noemulator_prop_view_defer_live

    # Nothing an app may be given a view of: no copy to build. A live area still
    # needs the hidden directory, which service.sh builds its copy into.
    if [ -z "$prop_view_contexts" ]; then
        rm -f "$prop_view_keys"
        rm -rf "$prop_view_dir/.scratch"
        if [ -n "$prop_view_deferred" ]; then
            noemulator_prop_view_hide
        else
            rm -rf "$prop_view_dir"
        fi
        return 0
    fi

    noemulator_prop_view_build "$prop_view_dir" || return 0
    noemulator_prop_view_register
    rm -f "$prop_view_keys"
    noemulator_prop_view_hide
}

# noemulator_app_property_view_refresh <rules file>. Rebuild every copy from the
# real areas and hand the new copies to the kernel.
#
# Why: a copy is frozen when the node opens it at registration. COPG-VD's
# service.sh writes ro.build.version.security_patch into build_prop after
# post-mount, so Java reads the new value and an app's native read of the area
# reads the old one; vdinfos scores that as a MISMATCH. Service time is after
# boot, so every module that writes a property from a service.sh has had its say.
#
# Apps started from now on get the new copies. An app already running keeps the
# copy the kernel mapped into it at setresuid until it restarts: clear changes
# what the next setresuid sees, not what is already mapped. A write that lands
# after this point goes stale the same way.
noemulator_app_property_view_refresh() {
    prop_view_rules="$1"
    prop_view_dir="$NOEMULATOR_PROP_VIEW_DIR"
    prop_view_resetprop="$NOEMULATOR_PROP_VIEW_RESETPROP"

    if [ ! -e "$NOEMULATOR_PROP_VIEW_NODE" ] || [ ! -e "$NOEMULATOR_PROP_VIEW_REDIRECT_NODE" ]; then
        echo "app property view refresh: susfs has no prop_view node; skipped"
        return 0
    fi

    # post-mount leaves the view directory only when it set up a view: copies it
    # registered, or the hidden directory a live area's copy goes into. No
    # directory means a failed or empty post-mount, so there is nothing to refresh.
    if [ ! -d "$prop_view_dir" ]; then
        echo "app property view refresh: post-mount set up no view; skipped"
        return 0
    fi

    prop_view_copies="$prop_view_dir/.new"
    rm -rf "$prop_view_copies"
    if ! mkdir -p "$prop_view_copies" "$prop_view_dir/.scratch"; then
        echo "failed: app property view refresh: cannot create $prop_view_copies"
        return 0
    fi
    # No chmod of the directory here: it is hidden already, and sus_path widened
    # its mode when it was added. A chmod now would bring EACCES back (#107).
    prop_view_keys="$prop_view_dir/.new.keys"
    : > "$prop_view_keys"

    noemulator_prop_view_group "$prop_view_rules"
    if [ -z "$prop_view_contexts" ]; then
        rm -rf "$prop_view_copies" "$prop_view_keys"
        echo "app property view refresh: no key to build a copy for; skipped"
        return 0
    fi

    # What the live areas hold as this build reads them. The watcher compares
    # against it, so a change that lands while the copies are built is caught on
    # its next pass rather than lost.
    noemulator_prop_view_live_sum > "$prop_view_dir/.live_sum"

    if ! noemulator_prop_view_build "$prop_view_copies"; then
        rm -f "$prop_view_keys"
        echo "app property view refresh: the copies could not be rebuilt; the old copies are kept"
        return 0
    fi

    # Each staged copy is checked before it is moved over the live one, which is
    # the file the kernel rule and the redirect already point at. A copy that
    # fails keeps the live one: it is what the kernel is serving now, and an
    # unlabelled or short file under the live name would be worse.
    noemulator_prop_view_install

    # Both nodes resolve a copy when its rule is added: the prop view rule holds
    # the file open, and the redirect keeps its inode to rewrite the app's maps
    # line. A copy moved into place is a new inode, so both rules are added
    # again for every live copy, including the ones this pass kept. Measured:
    # without it the app's maps named /dev/.prop_view/<area>.
    noemulator_prop_view_replace

    rm -rf "$prop_view_copies" "$prop_view_keys"
    echo "app property view refresh: done; $prop_view_refreshed refreshed, $prop_view_kept kept, $prop_view_added area(s) registered"
}

# Move each good staged copy over its live path. mv within the same tmpfs is a
# rename: a reader that already has the live path open keeps the old file, and
# one that opens it later gets the new one, never a half-written file.
noemulator_prop_view_install() {
    prop_view_refreshed=0
    prop_view_kept=0
    for prop_view_context in $prop_view_built_contexts; do
        prop_view_copy="$prop_view_copies/$prop_view_context"
        prop_view_live="$prop_view_dir/$prop_view_context"

        if [ ! -f "$prop_view_copy" ]; then
            echo "failed: app property view: $prop_view_context: no copy was built; the old copy is kept"
            prop_view_kept=$((prop_view_kept + 1))
            continue
        fi
        prop_view_problem=$(noemulator_prop_view_copy_problem "$prop_view_context" "$prop_view_copy")
        if [ -n "$prop_view_problem" ]; then
            echo "failed: app property view: $prop_view_context: $prop_view_problem; the old copy is kept"
            prop_view_kept=$((prop_view_kept + 1))
            continue
        fi

        if ! mv -f "$prop_view_copy" "$prop_view_live"; then
            echo "failed: app property view: $prop_view_context: the new copy could not be moved into place; the old copy is kept"
            prop_view_kept=$((prop_view_kept + 1))
            continue
        fi
        prop_view_refreshed=$((prop_view_refreshed + 1))
        echo "app property view: $prop_view_context: copy refreshed"
    done
}

# Drop the prop view node's entries and add every live copy back to both nodes.
# A refused add leaves that area without a view until the next boot's
# post-mount, and is logged rather than retried.
#
# An app that takes its uid between the clear and an area's add gets the real
# area, and the watcher makes this happen on every rebuild. So every prop view
# add comes first, straight after the clear, and the redirects after: measured
# on the reference AVD, 12 ms from the clear to the fifth add this way, 109 ms
# with each area's redirect written in between. A redirect is replaced with a
# del and an add of its own, which leaves the other areas' redirects in place.
noemulator_prop_view_replace() {
    prop_view_added=0
    if ! echo "clear" > "$NOEMULATOR_PROP_VIEW_NODE" 2>/dev/null; then
        echo "failed: app property view refresh: clear refused; the node keeps its old entries"
        return 0
    fi

    prop_view_swapped=""
    for prop_view_live in "$prop_view_dir"/*; do
        [ -f "$prop_view_live" ] || continue
        prop_view_context=${prop_view_live##*/}
        if echo "add /dev/__properties__/u:object_r:$prop_view_context:s0 $prop_view_live" > "$NOEMULATOR_PROP_VIEW_NODE" 2>/dev/null; then
            prop_view_swapped="$prop_view_swapped$prop_view_context "
        else
            echo "failed: app property view: $prop_view_context: prop view refused"
        fi
    done

    for prop_view_context in $prop_view_swapped; do
        prop_view_real="/dev/__properties__/u:object_r:$prop_view_context:s0"
        echo "del $prop_view_real" > "$NOEMULATOR_PROP_VIEW_REDIRECT_NODE" 2>/dev/null
        if ! echo "add_open_redirect $prop_view_real $prop_view_dir/$prop_view_context 3" > "$NOEMULATOR_PROP_VIEW_REDIRECT_NODE" 2>/dev/null; then
            echo "failed: app property view: $prop_view_context: open redirect refused; a program the app runs reads the real area"
            continue
        fi
        prop_view_added=$((prop_view_added + 1))
    done
}

# An app could otherwise find the view by name: opening the directory answers
# EACCES where a missing path answers ENOENT, and a copy opens by its path.
# Measured on #107. The redirect still reaches the copies: susfs exempts its own
# open of a redirect target from the hide.
noemulator_prop_view_hide() {
    if ! echo "add $prop_view_dir" > "$NOEMULATOR_PROP_VIEW_HIDE_NODE" 2>/dev/null; then
        echo "failed: app property view: hiding $prop_view_dir refused; apps can find it by name"
    fi
}

# One checksum line per live area that exists, in a fixed order.
noemulator_prop_view_live_sum() {
    for prop_view_sum_context in $NOEMULATOR_PROP_VIEW_LIVE_CONTEXTS; do
        prop_view_sum_area="/dev/__properties__/u:object_r:$prop_view_sum_context:s0"
        [ -f "$prop_view_sum_area" ] && md5sum "$prop_view_sum_area"
    done
}

# noemulator_app_property_view_watch <rules file>. Rebuild the copies whenever a
# live area changes, for as long as the device is up. Run in the background from
# service.sh, after the first refresh.
#
# Why: init rewrites a service's key each time it starts or stops, and a copy
# keeps the state it was built with. Measured on the reference AVD: heapprofd
# ran while an app started afterwards still read it stopped
# (docs/research/spike-init-svc-props.md). A rebuild serves new apps only; one
# already running keeps the copy it was swapped at setresuid.
#
# Returns at once when no live area has a copy, so a config without such keys
# starts no loop. The rules file is read on every rebuild, so it must outlive
# this loop.
noemulator_app_property_view_watch() {
    prop_view_watch_rules="$1"
    prop_view_watch_live=""
    for prop_view_watch_context in $NOEMULATOR_PROP_VIEW_LIVE_CONTEXTS; do
        [ -f "$NOEMULATOR_PROP_VIEW_DIR/$prop_view_watch_context" ] &&
            prop_view_watch_live=yes
    done
    [ -n "$prop_view_watch_live" ] || return 0

    while sleep "$NOEMULATOR_PROP_VIEW_WATCH_INTERVAL"; do
        # Gone once the module is uninstalled: nothing left to rebuild from.
        [ -f "$prop_view_watch_rules" ] || return 0
        [ "$(noemulator_prop_view_live_sum)" = "$(cat "$NOEMULATOR_PROP_VIEW_DIR/.live_sum" 2>/dev/null)" ] &&
            continue
        echo "app property view: a live area changed; rebuilding"
        noemulator_app_property_view_refresh "$prop_view_watch_rules"
    done
}
