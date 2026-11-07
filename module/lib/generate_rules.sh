#!/usr/bin/env sh
# Turn artifacts.conf into the commands that apply it.
#
# Printing the commands rather than running them is what makes this testable on a
# host with no device, and it is also what `noemulator --dry-run` shows. Nothing
# here touches the device.
#
# Usage: generate_rules.sh <artifacts.conf> [user config]
# Writes one command per line to stdout. Exits non-zero on an unrecognised directive.
#
# The 'device' line in artifacts.conf is replaced by the lines of a device preset,
# devices/<codename>.conf next to it: the user config's choice when it can be
# applied, the shipped default otherwise. A choice that cannot be applied is named
# on stderr and the config stays valid, because an invalid config applies nothing
# at all (ADR 0034). The running Android release is read with getprop, or from
# NOEMULATOR_ANDROID_RELEASE when that is set.
#
# The user config is read after the shipped list, in the same syntax and under the
# same checks, so a row it sets twice across the two files fails as it would in
# one. A user config that does not exist is no user config: the shipped list alone
# is what a device runs until the user makes a choice.

set -eu

SHIPPED_CONFIG="${1:?usage: generate_rules.sh <artifacts.conf> [user config]}"
USER_CONFIG="${2:-}"

# Rules go to the /proc nodes rather than through ksu_susfs, because the
# prerequisite publishes that CLI in its service.sh, which runs after
# post-fs-data. The nodes exist as soon as the kernel module is loaded.
SUSFS_KSTAT_NODE=/proc/susfs_kstat
RESETPROP=/data/adb/ksu/bin/resetprop

# The eleven stat fields after the inode, left as they are.
KSTAT_DEFAULTS=' default default default default default default default default default default default'

TAB=$(printf '\t')
NL='
'

case "$SHIPPED_CONFIG" in
    */*) DEVICE_DIR=${SHIPPED_CONFIG%/*}/devices ;;
    *) DEVICE_DIR=devices ;;
esac

# Set while a device preset is read, which holds a narrower set of directives.
in_preset=""
shipped_device_seen=""

# Every 'setting' namespace and key seen so far, one per line. A second line for
# the same row would have two values fight over it, and the record keeps one
# 'written' per row (docs/review/0003-triage.md, finding 9).
settings_seen=""

# Some deletes are the user's choice to skip, so they are held back until both
# files are read: the 'keep' directive may come after them, in the user config.
# One '<group> <command>' line per held delete, and one line per kept group.
# ARM translation is one group (docs/adr/0023-the-native-bridge-is-a-user-choice.md),
# the host clipboard another (docs/adr/0024-keeping-ro-boot-qemu-is-a-user-choice.md).
held_deletes=""
kept_groups=""

# A redirect may need the native bridge, and the 'keep' that turns it on may come
# later, in the user config. One fully built command per held line, printed after
# the held deletes and only when the group is kept.
held_redirects=""

# The renamed bridge is held the same way, and only one name may be given across
# both files: a second would point the property at a file the installer did not
# stage.
held_native_bridge_name=""
native_bridge_name_seen=""

# The uname machine spoof is held the same way, and given at most once across both
# files: the node takes one machine, and a second line would leave two markers
# fighting over it.
held_uname_machine=""
uname_machine_seen=""

# The app property view keys are held the same way, and one key may be given only
# once across both files: the second line would delete the same key from the same
# area again and be counted twice in the log.
held_app_delprops=""
app_delprop_seen=""

# Trim surrounding whitespace from $line: a line of spaces is blank, and an
# indented directive is still a directive.
#
# Done with builtins, not sed. This script runs at post-fs-data, where forking
# toybox sed once per line segfaulted on the target; a generator that forks per
# line would be wasteful even where it works.
trim_line() {
    while :; do
        case $line in
            ' '*|"$TAB"*) line=${line#?} ;;
            *) break ;;
        esac
    done
    while :; do
        case $line in
            *' '|*"$TAB") line=${line%?} ;;
            *) break ;;
        esac
    done
}

# directive_arguments <config> <directive>: the argument of every line of
# <config> that holds <directive>, one per line. Read before the config is
# generated, because the preset a 'device' line chooses is emitted in the
# shipped list's place, ahead of the user config's own setprops.
directive_arguments() {
    while IFS= read -r line || [ -n "$line" ]; do
        trim_line
        case "$line" in
            "$2 "*) echo "${line#"$2" }" ;;
        esac
    done < "$1"
}

# chosen_device <default>: the preset to apply, <default> unless the user config
# chooses another that can be applied. A choice that cannot is named on stderr.
chosen_device() {
    device_choice=""
    if [ -n "$USER_CONFIG" ] && [ -r "$USER_CONFIG" ]; then
        device_choice=$(directive_arguments "$USER_CONFIG" device)
    fi
    device_reason=""
    case "$device_choice" in
        '') echo "$1"; return 0 ;;
        *"$NL"*) device_reason="is given more than once" ;;
        *[!a-z0-9]*) device_reason="is not a preset name" ;;
    esac
    if [ -z "$device_reason" ] && [ ! -r "$DEVICE_DIR/$device_choice.conf" ]; then
        device_reason="has no preset"
    fi
    if [ -z "$device_reason" ]; then
        device_release=$(directive_arguments "$DEVICE_DIR/$device_choice.conf" android)
        running_release=${NOEMULATOR_ANDROID_RELEASE-$(getprop ro.build.version.release 2>/dev/null || :)}
        if [ "$device_release" != "$running_release" ]; then
            device_reason="is for Android $device_release, and this device runs Android ${running_release:-unknown}"
        fi
    fi
    if [ -n "$device_reason" ]; then
        echo "device: '$(printf '%s' "$device_choice" | tr '\n' ' ')' $device_reason; the default, $1, applies" >&2
        echo "$1"
        return 0
    fi
    echo "$device_choice"
}

# generate_from <config>. The name is copied before the loop: the redirect and
# uname_machine branches reuse the positional parameters to split their argument.
generate_from() {
    CONFIG=$1
    [ -r "$CONFIG" ] || { echo "cannot read $CONFIG" >&2; exit 1; }

    line_number=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))

        trim_line

        case "$line" in
            ''|'#'*) continue ;;
        esac

        directive=${line%% *}
        argument=${line#* }

        # The user config's device line was read by chosen_device, which names a
        # choice it cannot apply instead of failing: a typo in it must not turn
        # off every other rule.
        if [ "$directive" = device ] && [ "$CONFIG" = "$USER_CONFIG" ]; then
            continue
        fi

        if [ "$directive" = "$argument" ]; then
            echo "$CONFIG:$line_number: '$directive' needs an argument" >&2
            exit 1
        fi

        if [ -n "$in_preset" ]; then
            case "$directive" in
                setprop|setting|android) ;;
                *)
                    echo "$CONFIG:$line_number: a device preset holds only setprop, setting and android lines" >&2
                    exit 1
                    ;;
            esac
        fi

        case "$directive" in
            hide)
                # A call to the helper post-fs-data.sh defines, which skips a path
                # this image does not have instead of logging it as a failed rule.
                echo "noemulator_hide '$argument'"
                ;;
            relabel)
                # 'relabel <path> <context>'. One SELinux label on one path, set by
                # the helper post-fs-data.sh defines. Both are checked here because
                # both are quoted into the emitted line.
                set -- $argument
                if [ "$#" -ne 2 ]; then
                    echo "$CONFIG:$line_number: 'relabel' needs <path> <context>" >&2
                    exit 1
                fi
                case "$1" in
                    /*[!A-Za-z0-9._/:,@-]*|/) relabel_path_ok=0 ;;
                    /*) relabel_path_ok=1 ;;
                    *) relabel_path_ok=0 ;;
                esac
                if [ "$relabel_path_ok" -eq 0 ]; then
                    echo "$CONFIG:$line_number: '$1' is not a plain absolute path" >&2
                    exit 1
                fi
                case "$2" in
                    u:object_r:*:s0) relabel_type=${2#u:object_r:}; relabel_type=${relabel_type%:s0} ;;
                    *) relabel_type="" ;;
                esac
                case "$relabel_type" in
                    ''|*[!a-z0-9_]*)
                        echo "$CONFIG:$line_number: '$2' is not a u:object_r:<type>:s0 context" >&2
                        exit 1
                        ;;
                esac
                echo "noemulator_relabel '$1' '$2'"
                ;;
            kstat_inode)
                # 'kstat_inode <path> <inode>'. Apps that stat the path read this inode;
                # the other eleven stat fields stay live ('default'), so the mtime still
                # moves as files come and go. The node takes the same twelve fields as
                # the CLI (susfs4ksu-lkm-x64 kernel/susfs_kstat.c, parse_override).
                kstat_path=${argument%% *}
                kstat_inode=${argument#* }
                case "$kstat_path" in
                    /*) ;;
                    *)
                        echo "$CONFIG:$line_number: kstat_inode needs an absolute path, not '$kstat_path'" >&2
                        exit 1
                        ;;
                esac
                case "$kstat_path" in
                    *[!A-Za-z0-9._/-]*)
                        echo "$CONFIG:$line_number: '$kstat_path' is not a plain path" >&2
                        exit 1
                        ;;
                esac
                case "$kstat_inode" in
                    *[!0-9]*|''|0)
                        echo "$CONFIG:$line_number: kstat_inode needs <path> <inode>, an inode above 0" >&2
                        exit 1
                        ;;
                esac
                echo "echo 'add_sus_kstat_statically $kstat_path $kstat_inode$KSTAT_DEFAULTS' > $SUSFS_KSTAT_NODE"
                ;;
            redirect)
                # 'redirect <target> <replacement> <uid_scheme> [flag...]'. The work
                # of making sure the replacement exists belongs to the applier, not
                # here: this script runs on a host with no device. It emits a call to
                # the helper post-fs-data.sh defines, which refuses to write a rule
                # whose replacement is missing -- an open redirected at nothing is
                # ENOENT, and ENOENT on a device node is what boot-looped v0.1.0
                # (docs/adr/0010-emulator-device-nodes-stay-visible.md).
                #
                # A flag changes how the rule is written or whether it is emitted:
                #   app_only            the kernel applies it to the app process alone
                #   any_label           skip the SELinux label match
                #   keep_ident          a served fd reports the target's identity
                #   needs_native_bridge emit only when native_bridge keep is set
                set -- $argument
                if [ "$#" -lt 3 ]; then
                    echo "$CONFIG:$line_number: 'redirect' needs <target> <replacement> <uid_scheme>" >&2
                    exit 1
                fi
                redirect_target=$1
                redirect_replacement=$2
                redirect_scheme=$3
                shift 3
                case "$redirect_scheme" in
                    [0-4]) ;;
                    *)
                        echo "$CONFIG:$line_number: uid_scheme must be 0-4, not '$redirect_scheme'" >&2
                        exit 1
                        ;;
                esac

                # Each flag at most once. A repeat is a mistake, not a no-op: the
                # line would not say what its author thought it did.
                redirect_seen=" "
                for redirect_flag in "$@"; do
                    case "$redirect_flag" in
                        app_only|any_label|keep_ident|needs_native_bridge) ;;
                        *)
                            echo "$CONFIG:$line_number: unknown redirect flag '$redirect_flag'" >&2
                            exit 1
                            ;;
                    esac
                    case "$redirect_seen" in
                        *" $redirect_flag "*)
                            echo "$CONFIG:$line_number: redirect flag '$redirect_flag' is given twice" >&2
                            exit 1
                            ;;
                    esac
                    redirect_seen="$redirect_seen$redirect_flag "
                done

                # Only the flags the applier acts on are printed, in a fixed order.
                # needs_native_bridge is the generator's business and is consumed here.
                redirect_flags=""
                case "$redirect_seen" in *" app_only "*) redirect_flags=app_only ;; esac
                case "$redirect_seen" in
                    *" any_label "*) redirect_flags="${redirect_flags:+$redirect_flags }any_label" ;;
                esac
                case "$redirect_seen" in
                    *" keep_ident "*) redirect_flags="${redirect_flags:+$redirect_flags }keep_ident" ;;
                esac
                redirect_command="noemulator_redirect '$redirect_target' '$redirect_replacement' '$redirect_scheme'"
                if [ -n "$redirect_flags" ]; then
                    redirect_command="$redirect_command '$redirect_flags'"
                fi

                case "$redirect_seen" in
                    *" needs_native_bridge "*) held_redirects="$held_redirects$redirect_command$NL" ;;
                    *) echo "$redirect_command" ;;
                esac
                ;;
            angle)
                # 'angle <package>'. Runs the named package on ANGLE instead of the
                # emulator's GL driver, so glGetString reports no emulator token.
                # Applied from service.sh, not post-mount: `settings` talks to a
                # system service that does not exist before boot completes.
                #
                # One package per line. The applier accumulates them, because the two
                # settings keys are comma-separated lists and writing one package would
                # drop the rest.
                case "$argument" in
                    *[!A-Za-z0-9._]*|'')
                        echo "$CONFIG:$line_number: '$argument' is not a package name" >&2
                        exit 1
                        ;;
                esac
                echo "noemulator_angle '$argument'"
                ;;
            delprop)
                keep_group=""
                case "$argument" in
                    ro.dalvik.vm.native.bridge|ro.enable.native.bridge.exec) keep_group=native_bridge ;;
                    ro.boot.qemu) keep_group=boot_qemu ;;
                esac
                if [ -n "$keep_group" ]; then
                    held_deletes="$held_deletes$keep_group $RESETPROP -d $argument$NL"
                else
                    echo "$RESETPROP -d $argument"
                fi
                ;;
            native_bridge_name)
                # 'native_bridge_name <file>'. The name zygote loads the kept bridge
                # under. Held until both files are read, because the 'keep' that
                # turns it on may come later, and dropped when the group is not
                # kept: without the bridge the property is deleted as before.
                #
                # The file sits in /system/lib64, so a slash would leave it, and a
                # quote would break out of the emitted command the applier evals.
                case "$argument" in
                    lib*.so) ;;
                    *)
                        echo "$CONFIG:$line_number: native_bridge_name needs a library file name like libfoo.so, not '$argument'" >&2
                        exit 1
                        ;;
                esac
                native_bridge_file=${argument#lib}
                native_bridge_file=${native_bridge_file%.so}
                case "$native_bridge_file" in
                    *[!A-Za-z0-9_]*)
                        echo "$CONFIG:$line_number: native_bridge_name needs a plain file name matching lib[A-Za-z0-9_]*.so, not '$argument'" >&2
                        exit 1
                        ;;
                esac
                if [ -n "$native_bridge_name_seen" ]; then
                    echo "$CONFIG:$line_number: native_bridge_name is given twice" >&2
                    exit 1
                fi
                native_bridge_name_seen=yes
                held_native_bridge_name="noemulator_native_bridge_name '$argument'$NL"
                ;;
            uname_machine)
                # 'uname_machine <machine> <marker_path>'. uname() answers <machine>
                # to a process that maps <marker_path>, and the kernel's own answer
                # to every other. Held until both files are read, because the
                # 'keep' that turns it on may come later, and dropped when the
                # group is not kept: without the bridge no arm64 app runs at all.
                #
                # Both values go into a node line inside a command the applier
                # evals, so neither may carry a quote. The marker is an absolute
                # path with no '..', because the kernel resolves it to the file it
                # matches a process's maps against.
                set -- $argument
                if [ "$#" -ne 2 ]; then
                    echo "$CONFIG:$line_number: 'uname_machine' needs <machine> <marker_path>" >&2
                    exit 1
                fi
                uname_machine_name=$1
                uname_machine_marker=$2
                case "$uname_machine_name" in
                    ''|*[!A-Za-z0-9_]*)
                        echo "$CONFIG:$line_number: uname_machine needs a machine of [A-Za-z0-9_], not '$uname_machine_name'" >&2
                        exit 1
                        ;;
                esac
                if [ "${#uname_machine_name}" -gt 64 ]; then
                    echo "$CONFIG:$line_number: uname_machine needs a machine of at most 64 characters" >&2
                    exit 1
                fi
                case "$uname_machine_marker" in
                    /*) ;;
                    *)
                        echo "$CONFIG:$line_number: uname_machine needs an absolute marker path, not '$uname_machine_marker'" >&2
                        exit 1
                        ;;
                esac
                case "$uname_machine_marker" in
                    *..*)
                        echo "$CONFIG:$line_number: uname_machine marker may not contain '..', not '$uname_machine_marker'" >&2
                        exit 1
                        ;;
                    *[!A-Za-z0-9_./-]*)
                        echo "$CONFIG:$line_number: '$uname_machine_marker' is not a plain path" >&2
                        exit 1
                        ;;
                esac
                if [ -n "$uname_machine_seen" ]; then
                    echo "$CONFIG:$line_number: uname_machine is given twice" >&2
                    exit 1
                fi
                uname_machine_seen=yes
                held_uname_machine="noemulator_uname_machine '$uname_machine_name' '$uname_machine_marker'$NL"
                ;;
            app_delprop)
                # 'app_delprop <key> [needs_native_bridge]'. Omit the key from a
                # copy of its property area, and give app processes that copy.
                # Root, adb shell and zygote keep the real area (ADR 0029). With
                # the flag the line is held until both files are read, because
                # the 'keep' that turns it on may come later, and dropped when the
                # group is not kept: the ABI and bridge keys describe nothing an
                # app can use without the bridge. Without it the key is hidden
                # either way (ADR 0032).
                #
                # The key reaches a command the applier evals, so it is a plain
                # property name and nothing else.
                set -- $argument
                app_delprop_key=$1
                case "$#:${2-}" in
                    1:|2:needs_native_bridge) ;;
                    *)
                        echo "$CONFIG:$line_number: 'app_delprop' takes <key> and an optional needs_native_bridge" >&2
                        exit 1
                        ;;
                esac
                case "$app_delprop_key" in
                    *[!A-Za-z0-9._-]*|'')
                        echo "$CONFIG:$line_number: '$app_delprop_key' is not a property name" >&2
                        exit 1
                        ;;
                esac
                case "$NL$app_delprop_seen" in
                    *"$NL$app_delprop_key$NL"*)
                        echo "$CONFIG:$line_number: app_delprop $app_delprop_key is given twice" >&2
                        exit 1
                        ;;
                esac
                app_delprop_seen="$app_delprop_seen$app_delprop_key$NL"
                if [ "$#" -eq 2 ]; then
                    held_app_delprops="${held_app_delprops}noemulator_app_delprop '$app_delprop_key'$NL"
                else
                    echo "noemulator_app_delprop '$app_delprop_key'"
                fi
                ;;
            device)
                # 'device <codename>', the shipped default. The user config's
                # line never reaches here.
                case "$argument" in
                    *[!a-z0-9]*)
                        echo "$CONFIG:$line_number: '$argument' is not a preset name" >&2
                        exit 1
                        ;;
                esac
                if [ -n "$shipped_device_seen" ]; then
                    echo "$CONFIG:$line_number: device is given twice" >&2
                    exit 1
                fi
                shipped_device_seen=yes
                if [ ! -r "$DEVICE_DIR/$argument.conf" ]; then
                    echo "$CONFIG:$line_number: no preset $DEVICE_DIR/$argument.conf" >&2
                    exit 1
                fi
                device_applied=$(chosen_device "$argument")
                shipped_line_number=$line_number
                in_preset=yes
                generate_from "$DEVICE_DIR/$device_applied.conf"
                in_preset=""
                CONFIG=$SHIPPED_CONFIG
                line_number=$shipped_line_number
                ;;
            android)
                # 'android <release>'. Read by chosen_device; here it only has to
                # be in a preset, and be a release number.
                if [ -z "$in_preset" ]; then
                    echo "$CONFIG:$line_number: 'android' belongs in a device preset" >&2
                    exit 1
                fi
                case "$argument" in
                    *[!0-9]*)
                        echo "$CONFIG:$line_number: '$argument' is not an Android release" >&2
                        exit 1
                        ;;
                esac
                ;;
            native_bridge|boot_qemu)
                # '<group> keep'. The only value: a typo must not silently mean
                # "hide", or the user loses what they turned the switch on for.
                if [ "$argument" != keep ]; then
                    echo "$CONFIG:$line_number: $directive takes only 'keep', not '$argument'" >&2
                    exit 1
                fi
                kept_groups="$kept_groups$directive$NL"
                ;;
            delprop_after_wifi)
                # 'delprop_after_wifi <property>'. Deleted once wlan0 exists, not at
                # post-fs-data. The emulated Wi-Fi reads ro.boot.qemu.virtiowifi when
                # its HAL starts at 8.5s; deleting it at 5s leaves the AVD with no
                # wlan0 at all, which is both a lost feature and a contradiction a
                # detector scores (docs/adr/0016-delete-the-wifi-property-late.md).
                case "$argument" in
                    *[!A-Za-z0-9._-]*|'')
                        echo "$CONFIG:$line_number: '$argument' is not a property name" >&2
                        exit 1
                        ;;
                esac
                echo "noemulator_delprop_after_wifi '$argument'"
                ;;
            delprop_once_set)
                # 'delprop_once_set <property>'. For a property a vendor service sets
                # after post-fs-data, where a plain delprop finds nothing to delete.
                # Waits for it to be set, gives its readers time to read it, then
                # deletes (docs/adr/0020-delete-vendor-qemu-properties-once-set.md).
                case "$argument" in
                    *[!A-Za-z0-9._-]*|'')
                        echo "$CONFIG:$line_number: '$argument' is not a property name" >&2
                        exit 1
                        ;;
                esac
                echo "noemulator_delprop_once_set '$argument'"
                ;;
            setting)
                # 'setting <namespace> <key> <value>'. Writes a settings row after boot
                # and records what it replaced; lib/setting_record.sh is the applier.
                # The value is the rest of the line, spaces included, quoted the same
                # way setprop's is.
                namespace=${argument%% *}
                key_value=${argument#* }
                key=${key_value%% *}
                value=${key_value#* }
                if [ "$namespace" = "$key_value" ] || [ "$key" = "$value" ]; then
                    echo "$CONFIG:$line_number: 'setting' needs <namespace> <key> <value>" >&2
                    exit 1
                fi
                case "$namespace" in
                    global|secure|system) ;;
                    *)
                        echo "$CONFIG:$line_number: namespace must be global, secure or system, not '$namespace'" >&2
                        exit 1
                        ;;
                esac
                case "$key" in
                    *[!A-Za-z0-9_.]*|'')
                        echo "$CONFIG:$line_number: '$key' is not a settings key" >&2
                        exit 1
                        ;;
                esac
                case "$value" in
                    *\'*)
                        echo "$CONFIG:$line_number: a value may not contain a single quote" >&2
                        exit 1
                        ;;
                esac
                case "$NL$settings_seen" in
                    *"$NL$namespace $key$NL"*)
                        echo "$CONFIG:$line_number: 'setting $namespace $key' is set twice" >&2
                        exit 1
                        ;;
                esac
                settings_seen="$settings_seen$namespace $key$NL"
                echo "noemulator_setting '$namespace' '$key' '$value'"
                ;;
            setprop)
                name=${argument%% *}
                value=${argument#* }
                if [ "$name" = "$value" ]; then
                    echo "$CONFIG:$line_number: 'setprop $name' needs a value" >&2
                    exit 1
                fi
                # The emitted command is eval'd, and a value may contain a space
                # (ro.product.model=Pixel 8), so it is single-quoted. A value carrying a
                # single quote would break out of that quoting; no property needs one.
                case "$value" in
                    *\'*)
                        echo "$CONFIG:$line_number: a value may not contain a single quote" >&2
                        exit 1
                        ;;
                esac
                echo "$RESETPROP $name '$value'"
                ;;
            *)
                echo "$CONFIG:$line_number: unknown directive '$directive'" >&2
                exit 1
                ;;
        esac
    done < "$CONFIG"
}

generate_from "$SHIPPED_CONFIG"
if [ -n "$USER_CONFIG" ] && [ -e "$USER_CONFIG" ]; then
    generate_from "$USER_CONFIG"
fi
while IFS=' ' read -r group delete_command; do
    [ -n "$group" ] || continue
    case "$NL$kept_groups" in
        *"$NL$group$NL"*) ;;
        *) echo "$delete_command" ;;
    esac
done <<HELD
$held_deletes
HELD

# The held redirects go last, for the same reason: the keep that emits them may
# come from either file. A line whose group is not kept is dropped, not retried.
while IFS= read -r held_redirect; do
    [ -n "$held_redirect" ] || continue
    case "$NL$kept_groups" in
        *"${NL}native_bridge$NL"*) echo "$held_redirect" ;;
    esac
done <<HELD
$held_redirects
HELD

# The bridge name goes last, for the same reason: the keep that emits it may come
# from either file.
while IFS= read -r held_bridge_name; do
    [ -n "$held_bridge_name" ] || continue
    case "$NL$kept_groups" in
        *"${NL}native_bridge$NL"*) echo "$held_bridge_name" ;;
    esac
done <<HELD
$held_native_bridge_name
HELD

# The uname machine line goes last for the same reason: the keep that emits it may
# come from either file.
while IFS= read -r held_uname; do
    [ -n "$held_uname" ] || continue
    case "$NL$kept_groups" in
        *"${NL}native_bridge$NL"*) echo "$held_uname" ;;
    esac
done <<HELD
$held_uname_machine
HELD

# The app property view keys follow, for the same reason.
while IFS= read -r held_app_delprop; do
    [ -n "$held_app_delprop" ] || continue
    case "$NL$kept_groups" in
        *"${NL}native_bridge$NL"*) echo "$held_app_delprop" ;;
    esac
done <<HELD
$held_app_delprops
HELD
