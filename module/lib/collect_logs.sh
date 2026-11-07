#!/system/bin/sh
# Write one text file a user can attach to a bug report, and print its path.
#
# Run by the WebUI's Export button (options_webui.sh export) and by action.sh,
# the module card's Action button in the KernelSU manager.
#
# The file goes to a public issue tracker, so anything that identifies the user
# or their machine is redacted before it is written: the host timezone the
# emulator passes through, the ADB public key, and serial numbers, including the
# one inside persist.adb.wifi.guid. Redaction is by property name, so a value is
# never inspected and a new identifier under a known name is still caught. Times
# are UTC, here and in apply.log's headers, because a local time's zone name
# says the same thing the timezone property does.

set -u

LOGS_DIR=${0%/*}
LOGS_MODULE=${NOEMULATOR_LOGS_MODULE:-$LOGS_DIR/..}
LOGS_MODULES_ROOT=${NOEMULATOR_LOGS_MODULES_ROOT:-/data/adb/modules}
LOGS_OUT_DIR=${NOEMULATOR_LOGS_OUT_DIR:-/sdcard/Download}

. "$LOGS_DIR/user_config.sh"

# Two forms carry a value: getprop's '[name]: [value]' and the user config's
# 'setprop name value'. A name is redacted on any of these fragments.
#
# awk rather than sed: measured 2026-10-20, the manager's busybox sed segfaults
# on these patterns over a real report, as two -e expressions or with
# [[:space:]], and the export was left as an empty file.
noemulator_logs_redact() {
    awk -v secret='timezone|pubkey|adb[._]key|serial|guid' '
        /^\[/ && index($0, "]: [") {
            name = substr($0, 2, index($0, "]: [") - 2)
            if (tolower(name) ~ secret) { print "[" name "]: [redacted]"; next }
        }
        $1 == "setprop" && tolower($2) ~ secret { print $1, $2, "redacted"; next }
        { print }
    '
}

noemulator_logs_section() {
    printf '\n===== %s =====\n' "$1"
}

noemulator_logs_report() {
    echo "NoEmulator log export, $(date -u)"

    noemulator_logs_section 'versions'
    sed -n 's/^\(version\|versionCode\)=/NoEmulator \1 /p' "$LOGS_MODULE/module.prop"
    echo "kernel $(uname -r) $(uname -m)"
    echo "android $(getprop ro.build.version.release) sdk $(getprop ro.build.version.sdk)"
    [ -x /data/adb/ksud ] && echo "ksud $(/data/adb/ksud -V 2>&1)"

    noemulator_logs_section 'modules'
    for logs_module in "$LOGS_MODULES_ROOT"/*/; do
        [ -f "$logs_module/module.prop" ] || continue
        logs_state=enabled
        [ -f "$logs_module/disable" ] && logs_state=disabled
        echo "$(sed -n 's/^id=//p' "$logs_module/module.prop") $(sed -n 's/^version=//p' "$logs_module/module.prop") $logs_state"
    done

    noemulator_logs_section 'apply.log'
    cat "$LOGS_MODULE/apply.log" 2>&1

    noemulator_logs_section "user config ($NOEMULATOR_USER_CONFIG)"
    cat "$NOEMULATOR_USER_CONFIG" 2>/dev/null || echo '(none)'

    noemulator_logs_section 'susfs redirects'
    cat /proc/susfs_open_redirect 2>&1

    # The app property view's rules and its swapped and failed counters. A swap
    # that fails inside an app is counted here and nowhere in apply.log.
    noemulator_logs_section 'susfs prop view'
    cat /proc/susfs_prop_view 2>&1

    noemulator_logs_section 'emulator properties still set'
    getprop | grep -iE 'qemu|goldfish|ranchu|emulator|native\.bridge|ro\.hardware' || echo '(none)'
}

mkdir -p "$LOGS_OUT_DIR" || exit 1
logs_file="$LOGS_OUT_DIR/noemulator-logs-$(date -u +%Y%m%d-%H%M%S).txt"
noemulator_logs_report 2>&1 | noemulator_logs_redact > "$logs_file" || exit 1
echo "$logs_file"
