#!/usr/bin/env sh
# Tests for module/lib/generate_rules.sh.
#
# Runs on a host with no device, no root and no kernel module — that is the point of
# the generator being a separate, printing step. No test framework is installed, so
# assertions are plain shell.

set -u

REPO="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
GENERATE="$REPO/module/lib/generate_rules.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
checks=0

# --invariants runs only the checks that stand behind an [invariant] acceptance
# criterion in docs/specs/noemulator.md. Every other check still has its arguments
# evaluated, because later checks depend on the fixtures earlier ones build; it is
# only skipped as an assertion.
invariants_only=0
[ "${1:-}" = "--invariants" ] && invariants_only=1

compare() {
    description="$1"
    expected="$2"
    actual="$3"
    checks=$((checks + 1))
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$description"
    else
        printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' \
            "$description" "$expected" "$actual"
        failures=$((failures + 1))
    fi
}

check() {
    [ "$invariants_only" -eq 1 ] && return 0
    compare "$@"
}

# check_invariant <criterion> <description> <expected> <actual>
#
# A failure names the criterion it breaks, not just the line. Tag a check only
# when its own comment ties it to that criterion; a check that merely touches the
# same code is not an invariant.
check_invariant() {
    criterion="$1"
    shift
    compare "[criterion $criterion] $1" "$2" "$3"
}

config_with() {
    printf '%s\n' "$1" > "$WORK/conf"
    echo "$WORK/conf"
}

# --- one line per directive -------------------------------------------------

check 'hide emits a call to the post-fs-data helper' \
    "noemulator_hide '/dev/goldfish_sync'" \
    "$(sh "$GENERATE" "$(config_with 'hide /dev/goldfish_sync')")"

# The helper is run here with the node swapped for a file. The verb is the node's
# ('add'), not the CLI's ('add_sus_path'): an assertion that once encoded the CLI
# spelling passed, and the write failed with EINVAL on the device.
eval "$(sed -n '/^noemulator_hide()/,/^}/p' "$REPO/module/post-fs-data.sh" \
    | sed "s|/proc/susfs_path|$WORK/susfs_path|")"
: > "$WORK/hidden_file"
check 'the hide helper writes the node-syntax add for a path that exists' \
    "add $WORK/hidden_file" \
    "$(: > "$WORK/susfs_path"; noemulator_hide "$WORK/hidden_file"; cat "$WORK/susfs_path")"

# Another image may not ship every file the config names. The node refuses a path
# that does not exist, and a refused write is a failed rule that makes health read
# not working, for a file there was nothing to hide.
check 'the hide helper skips a missing path without writing or failing' \
    "rc=0 hide: no $WORK/no_such_file; skipped node=" \
    "$(: > "$WORK/susfs_path"; out="$(noemulator_hide "$WORK/no_such_file")"
       echo "rc=$? $out node=$(cat "$WORK/susfs_path")")"

check 'delprop emits a resetprop delete' \
    '/data/adb/ksu/bin/resetprop -d ro.boot.qemu' \
    "$(sh "$GENERATE" "$(config_with 'delprop ro.boot.qemu')")"

check 'setprop emits a resetprop write with the value quoted' \
    "/data/adb/ksu/bin/resetprop ro.hardware 'zuma'" \
    "$(sh "$GENERATE" "$(config_with 'setprop ro.hardware zuma')")"

# ro.product.model is 'Pixel 8'. The emitted command is eval'd, so a value with a
# space has to survive as one argument.
check 'a setprop value keeps its spaces' \
    "/data/adb/ksu/bin/resetprop ro.product.model 'Pixel 8'" \
    "$(sh "$GENERATE" "$(config_with 'setprop ro.product.model Pixel 8')")"

# --- what gets ignored ------------------------------------------------------

printf '# a comment\n\n   \n  hide /dev/x  \n' > "$WORK/mixed"
check 'comments, blank lines and whitespace-only lines are skipped, and a directive may be indented' \
    "noemulator_hide '/dev/x'" \
    "$(sh "$GENERATE" "$WORK/mixed")"

: > "$WORK/empty"
check 'an empty config produces no rules' '' "$(sh "$GENERATE" "$WORK/empty")"

printf '# only a comment\n' > "$WORK/only_comment"
check 'a comment-only config produces no rules' '' "$(sh "$GENERATE" "$WORK/only_comment")"

# --- failure paths ----------------------------------------------------------

sh "$GENERATE" "$(config_with 'frobnicate /dev/x')" >/dev/null 2>&1
check 'an unknown directive exits non-zero' '1' "$?"

check 'an unknown directive names the line' '1' \
    "$(sh "$GENERATE" "$(config_with 'frobnicate /dev/x')" 2>&1 >/dev/null | grep -c ":1: unknown directive 'frobnicate'")"

sh "$GENERATE" "$(config_with 'hide')" >/dev/null 2>&1
check 'a directive with no argument exits non-zero' '1' "$?"

sh "$GENERATE" "$(config_with 'setprop ro.hardware')" >/dev/null 2>&1
check 'setprop with a name but no value exits non-zero' '1' "$?"

# A single quote in the value would close the quoting the emitted command relies on.
sh "$GENERATE" "$(config_with "setprop ro.product.model Pixel'8")" >/dev/null 2>&1
check 'a setprop value containing a single quote is rejected' '1' "$?"

sh "$GENERATE" "$WORK/does_not_exist" >/dev/null 2>&1
check 'an unreadable config exits non-zero' '1' "$?"

sh "$GENERATE" >/dev/null 2>&1
check 'no argument is a usage error, exit 2' '2' "$?"

# --- the shipped config -----------------------------------------------------
# Guards against a typo in artifacts.conf reaching a device. The last two are
# regression guards for findings that cost a reboot to discover, not style checks;
# see docs/research/spike-loader-visibility.md. Do not delete them to simplify the
# suite.

sh "$GENERATE" "$REPO/module/artifacts.conf" >/dev/null 2>&1
check 'the shipped artifacts.conf is valid' '0' "$?"

# Hiding these three boot-loops the device: gfxstream opens them inside every app
# process, so ENOENT makes EGL init fail and libEGL dereferences the NULL extension
# string. Isolated to these rules alone, twice. A regression guard, not a style check.
check 'the shipped config hides no goldfish device node' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c "^noemulator_hide '/dev/goldfish")"

# Detectors list /vendor/lib64/hw and score each 'ranchu' name (ADR 0030). None of
# these five is opened by an app, which is what makes hiding them safe; a sixth
# name needs that measured first, as docs/research/spike-hal-listing.md did.
check 'the shipped config hides exactly the five ranchu HAL files' \
    "noemulator_hide '/vendor/lib64/hw/android.hardware.audio.legacy@7.1-impl.ranchu.so'
noemulator_hide '/vendor/lib64/hw/android.hardware.audio@7.1-impl.ranchu.so'
noemulator_hide '/vendor/lib64/hw/android.hardware.sensors@2.1-impl.ranchu.so'
noemulator_hide '/vendor/lib64/hw/mapper.ranchu.so'
noemulator_hide '/vendor/lib64/hw/vulkan.ranchu.so'" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep "^noemulator_hide '/vendor/lib64/hw/")"

# Deleting the property before zygote is what stops the bridge loading; hiding the
# library instead left /proc/self/maps and dl_iterate_phdr disagreeing.
check_invariant 1 'the shipped config deletes the native bridge property' '1' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c -- '-d ro.dalvik.vm.native.bridge$')"

# ro.kernel.qemu=1 is a direct emulator guest property to Duck Detector (#73).
check_invariant 1 'the shipped config deletes ro.kernel.qemu' '1' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c -- '-d ro.kernel.qemu$')"

# add_sus_map on a loaded library makes the linker and maps views disagree, which is
# the divergence a detector looks for. Measured: it turned a clean check into a hit.
check_invariant 2 'the shipped config adds no sus_map rule' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c 'add_sus_map')"

# Duck Detector scores these four on a 'goldfish', 'ranchu' or 'sdk_gphone' token
# (VirtualizationBuildProbe.kt, VirtualizationPropertyProbe.kt). They need a value,
# not a deletion, because an app reads them and an empty one is its own anomaly.
for shipped_identity in ro.build.fingerprint ro.product.model ro.product.board ro.hardware; do
    check_invariant 1 "the shipped config gives $shipped_identity a value" '1' \
        "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c "^/data/adb/ksu/bin/resetprop $shipped_identity ")"
done

# The identity has to agree with the running build: a fingerprint claiming a
# different Android release than ro.build.version.release is a contradiction a
# detector reads for free.
check 'the shipped fingerprint claims Android 16' '1' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c "resetprop ro.build.fingerprint 'google/shiba/shiba:16/")"

# The Vulkan HAL is renamed rather than hidden: add_sus_map on a loaded library is
# the divergence above. Both halves of the rename have to agree, and the variant
# has to carry no emulator token, or the file is renamed to another hit.
for shipped_vulkan in ro.hardware.vulkan ro.boot.hardware.vulkan; do
    check "the shipped config gives $shipped_vulkan a value" '1' \
        "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c "^/data/adb/ksu/bin/resetprop $shipped_vulkan ")"
done

# A real Pixel 8 has no ro.hardware.gralloc, and every reader treats absent the
# way it treats 'ranchu' (issue #30). A value here would be an attribute no Pixel
# carries, and 'minigbm' would switch the readers to an allocator the AVD does
# not have.
check 'the shipped config deletes ro.hardware.gralloc and gives it no value' 'deleted' \
    "$(rules="$(sh "$GENERATE" "$REPO/module/artifacts.conf")"
       if printf '%s\n' "$rules" | grep -q 'resetprop ro\.hardware\.gralloc '; then
           echo 'given a value'
       elif printf '%s\n' "$rules" | grep -qx '/data/adb/ksu/bin/resetprop -d ro\.hardware\.gralloc'; then
           echo deleted
       else
           echo kept
       fi)"

check 'the two Vulkan variant properties agree' '1' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | sed -n "s|^/data/adb/ksu/bin/resetprop ro\\.\\(boot\\.\\)\\{0,1\\}hardware\\.vulkan ||p" \
        | sort -u | wc -l | tr -d ' ')"

# No rule may set a property to a value that is itself a giveaway: renaming one
# hit into another costs a reboot to discover. 'generic' is in the list because
# emulator images name themselves generic_x86 and generic_system, and 'AOSP'
# because that is what this AVD answers for ro.soc.manufacturer where a real
# Pixel 8 answers 'Google'.
#
# Exactly one shipped value begins with one of these tokens, and it is verified
# real. A Pixel 8's system partition reports generic_system_google, because that
# partition genuinely carries the generic system image
# (docs/research/pixel8-partition-identity.md). The assertion is on the whole
# match set rather than on a count, so the exemption cannot quietly widen: a
# second token-prefixed value fails here even if it carries a different token.
check_invariant 1 'the only token-prefixed value is the real Pixel 8 system-partition name' \
    "/data/adb/ksu/bin/resetprop ro.product.system.name 'generic_system_google'" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | grep -E "resetprop [^ ]+ '(ranchu|goldfish|emulation|generic|AOSP)")"

# --- the identity agrees with itself ----------------------------------------
#
# These exist because the opposite shipped. Up to v0.4.7 the config set
# ro.build.fingerprint to google/shiba/shiba:16/CP1A.260505.005 while leaving
# ro.product.device at 'emu64xa' and ro.build.id at 'BE2A.250530.026.D1'. No
# emulator token was involved and nothing greps for one: a detector reads two
# fields and sees they disagree (issue #27).
#
# Every assertion below takes one side from the fingerprint and the other from a
# property written on its own line, so the two can only agree by being kept in
# step. Hardcoding both sides would assert nothing.

# Every preset is checked, not only the default: a dump-built preset is as able
# to disagree with itself as a hand-kept one (ADR 0034).
for identity_preset in $(cd "$REPO/module/devices" && ls *.conf | sed 's/\.conf$//'); do
printf 'device %s\n' "$identity_preset" > "$WORK/identity.conf"
identity_rules="$(NOEMULATOR_ANDROID_RELEASE=16 sh "$GENERATE" "$REPO/module/artifacts.conf" "$WORK/identity.conf")"

shipped_prop() {
    printf '%s\n' "$identity_rules" \
        | sed -n "s|^/data/adb/ksu/bin/resetprop $1 '\(.*\)'$|\1|p"
}

shipped_fingerprint="$(shipped_prop 'ro\.build\.fingerprint')"

# google/shiba/shiba:16/CP1A.260505.005/15081906:user/release-keys
fingerprint_rest="${shipped_fingerprint#*/}"
fingerprint_product="${fingerprint_rest%%/*}"
fingerprint_rest="${fingerprint_rest#*/}"
fingerprint_device="${fingerprint_rest%%:*}"
fingerprint_rest="${fingerprint_rest#*:}"
fingerprint_release="${fingerprint_rest%%/*}"
fingerprint_rest="${fingerprint_rest#*/}"
fingerprint_build_id="${fingerprint_rest%%/*}"
fingerprint_rest="${fingerprint_rest#*/}"
fingerprint_incremental="${fingerprint_rest%%:*}"

check "ro.product.device matches the device in the fingerprint ($identity_preset)" \
    "$fingerprint_device" "$(shipped_prop 'ro\.product\.device')"

# init's deprecated alias for ro.product.device. Letting it keep the AVD's value
# would leave Build.PRODUCT reading emu64xa next to a Pixel 8 fingerprint.
check "ro.build.product matches the product in the fingerprint ($identity_preset)" \
    "$fingerprint_product" "$(shipped_prop 'ro\.build\.product')"

check "ro.build.id matches the build in the fingerprint ($identity_preset)" \
    "$fingerprint_build_id" "$(shipped_prop 'ro\.build\.id')"

# What Settings shows and what the WebView and HTTP user agents print after
# 'Build/'. A stale value here is visible to any page the device loads.
check "ro.build.display.id matches the build in the fingerprint ($identity_preset)" \
    "$fingerprint_build_id" "$(shipped_prop 'ro\.build\.display\.id')"

check "ro.build.version.incremental matches the fingerprint ($identity_preset)" \
    "$fingerprint_incremental" "$(shipped_prop 'ro\.build\.version\.incremental')"

# A real device builds both of these out of the same fields, so they are the
# cheapest place for a hand-edited fingerprint to leave a contradiction.
check "ro.build.description restates the fingerprint ($identity_preset)" \
    "$fingerprint_product-user $fingerprint_release $fingerprint_build_id $fingerprint_incremental release-keys" \
    "$(shipped_prop 'ro\.build\.description')"

check "ro.build.flavor restates the fingerprint ($identity_preset)" \
    "$fingerprint_product-user" "$(shipped_prop 'ro\.build\.flavor')"

# Each partition keeps its own copy of the identity. A copy left behind is what
# vdinfos scored as eight BUILD and five FINGERPRINT specs.
#
# Two different bugs, so two kinds of check per family. A *count* catches a line
# dropped from the config; it cannot catch a line whose value was never updated.
# An earlier draft of this block asserted only the count, and a partition left
# reading sdk_gphone64_x86_64 passed the whole suite -- the exact defect the slice
# was opened for. Every family below is now asserted both ways.

# Distinct values a family takes across the six device partitions, one per line.
# 'system' is excluded throughout: a real Pixel 8 carries the generic image's
# identity there, and it is asserted on its own terms below. Collapsing with
# sort -u means agreement prints one line and any disagreement prints two, so the
# comparison is against the single expected value.
device_partition_values() {
    printf '%s\n' "$identity_rules" \
        | grep -E "^/data/adb/ksu/bin/resetprop ro\.product\.(odm|product|system_dlkm|system_ext|vendor|vendor_dlkm)\.$1 " \
        | sed "s|^.* '\(.*\)'$|\1|" \
        | sort -u
}

# Same, for the ro.<partition>.build.<field> spelling, which covers all seven.
partition_build_values() {
    printf '%s\n' "$identity_rules" \
        | grep -E "^/data/adb/ksu/bin/resetprop ro\.(odm|product|system|system_dlkm|system_ext|vendor|vendor_dlkm)\.build\.$1 " \
        | sed "s|^.* '\(.*\)'$|\1|" \
        | sort -u
}

for identity_family in model name device; do
    check "every device partition's $identity_family equals the base value ($identity_preset)" \
        "$(shipped_prop "ro\.product\.$identity_family")" \
        "$(device_partition_values "$identity_family")"
done

check "every device partition gets model, name and device ($identity_preset)" '18' \
    "$(printf '%s\n' "$identity_rules" \
        | grep -c -E "resetprop ro\.product\.(odm|product|system_dlkm|system_ext|vendor|vendor_dlkm)\.(model|name|device) ")"

# Six of the seven repeat the base fingerprint verbatim. Asserting the set rather
# than a count also closes a vacuous pass: with every fingerprint line deleted the
# old "no partition claims a different release" check had nothing to reject.
check "every device partition fingerprint equals the base fingerprint ($identity_preset)" \
    "$shipped_fingerprint" \
    "$(printf '%s\n' "$identity_rules" \
        | grep -E "^/data/adb/ksu/bin/resetprop ro\.(odm|product|system_dlkm|system_ext|vendor|vendor_dlkm)\.build\.fingerprint " \
        | sed "s|^.* '\(.*\)'$|\1|" \
        | sort -u)"

# The system partition names the generic image, not the device -- but it must
# still agree with the base on release, build and incremental, which is where a
# hand edit would leave it behind.
# The hand-kept Pixel 8 names the generic image there, as its Android 17 dump
# does; the Android 16 dumps name the device (docs/research/pixel-device-presets.md).
# Either way it must agree with the base on release, build and incremental.
system_fingerprint="$(shipped_prop 'ro\.system\.build\.fingerprint')"
case "$system_fingerprint" in
    google/generic_system_google/generic:*) system_expected="google/generic_system_google/generic:$fingerprint_release/$fingerprint_build_id/$fingerprint_incremental:user/release-keys" ;;
    *) system_expected=$shipped_fingerprint ;;
esac
check "the system partition fingerprint names the generic image or the device, at the same build ($identity_preset)" \
    "$system_expected" "$system_fingerprint"

check "all seven partitions carry a fingerprint ($identity_preset)" '7' \
    "$(printf '%s\n' "$identity_rules" \
        | grep -c -E "resetprop ro\.[a-z_]+\.build\.fingerprint ")"

check "every partition build.id equals the base build id ($identity_preset)" \
    "$fingerprint_build_id" "$(partition_build_values 'id')"

check "every partition incremental equals the base incremental ($identity_preset)" \
    "$fingerprint_incremental" "$(partition_build_values 'version\.incremental')"

for build_family in id version.incremental; do
    check "all seven partitions carry a build.$build_family ($identity_preset)" '7' \
        "$(printf '%s\n' "$identity_rules" \
            | grep -c -E "resetprop ro\.[a-z_]+\.build\.$build_family ")"
done

# The system partition is deliberately NOT given the device's values: a real
# Pixel 8 reports the generic system image there, and copying 'Pixel 8' into it
# would make this device disagree with every real one. This check exists to stop
# a future tidy-up of vdinfos' SPLIT verdict from doing exactly that
# (docs/adr/0018-mirror-a-real-pixel-8-partition-for-partition.md).
check "the system partition keeps the generic image name ($identity_preset)" 'Generic System' \
    "$(shipped_prop 'ro\.product\.system\.model')"

# A property set twice is ambiguous: the last resetprop wins, silently, and
# customize.sh reads ro.hardware.vulkan straight out of the config assuming one
# match. Counting distinct names against total setprop rules catches any
# duplicate, not only that one.
check "no property is set twice ($identity_preset)" \
    "$(printf '%s\n' "$identity_rules" | grep -c 'resetprop [^-]')" \
    "$(printf '%s\n' "$identity_rules" \
        | sed -n 's|^/data/adb/ksu/bin/resetprop \([^ -][^ ]*\) .*|\1|p' \
        | sort -u | wc -l | tr -d ' ')"

# device_name restates the model, so changing the model without the name would
# bring back the contradiction issue #28 removed.
check "device_name equals ro.product.model ($identity_preset)" \
    "$(shipped_prop 'ro\.product\.model')" \
    "$(printf '%s\n' "$identity_rules" \
        | sed -n "s|^noemulator_setting 'global' 'device_name' '\(.*\)'$|\1|p")"

# A preset is applied only on the release it names, so the name has to be the
# release its fingerprint claims.
check "the preset's android line is its fingerprint's release ($identity_preset)" \
    "$fingerprint_release" \
    "$(sed -n 's/^android //p' "$REPO/module/devices/$identity_preset.conf")"

# customize.sh stages the Vulkan HAL and the EGL driver under the names
# artifacts.conf gives, before any choice is read. A preset giving another name
# would point the property at a file nobody staged.
check "the preset names no Vulkan or EGL variant ($identity_preset)" '0' \
    "$(grep -c -E '^setprop ro\.(boot\.)?hardware\.(vulkan|egl) ' "$REPO/module/devices/$identity_preset.conf")"
done

# --- choosing a device preset (issue #133) ----------------------------------
#
# The user config's 'device' line replaces the shipped default with another
# preset. A choice that cannot be applied leaves the default in place and keeps
# the config valid, because an invalid config applies nothing at all (ADR 0034).

# device_rules <user config> [running release]: the rules, with stderr in
# $WORK/device.err.
device_rules() {
    printf '%s\n' "$1" > "$WORK/device.conf"
    NOEMULATOR_ANDROID_RELEASE=${2-16} sh "$GENERATE" "$REPO/module/artifacts.conf" "$WORK/device.conf" 2>"$WORK/device.err"
}
default_rules="$(sh "$GENERATE" "$REPO/module/artifacts.conf")"

check 'choosing the default preset changes nothing' \
    "$default_rules" "$(device_rules 'device shiba')"

check 'a chosen preset leaves no value of the default behind' '0 Pixel 8 Pro' \
    "$(rules="$(device_rules 'device husky')"
       printf '%s ' "$(printf '%s\n' "$rules" | grep -c -e shiba -e "'Pixel 8'")"
       printf '%s\n' "$rules" | sed -n "s|^/data/adb/ksu/bin/resetprop ro.product.model '\(.*\)'$|\1|p")"

for unapplied in 'device nosuch|16|has no preset' \
    'device Bad!|16|is not a preset name' \
    'device husky
device caiman|16|is given more than once' \
    'device husky|17|is for Android 16, and this device runs Android 17' \
    'device husky||is for Android 16, and this device runs Android unknown'; do
    unapplied_config=${unapplied%%|*}
    unapplied_rest=${unapplied#*|}
    unapplied_release=${unapplied_rest%%|*}
    unapplied_reason=${unapplied_rest#*|}
    check "an unapplied choice keeps every default rule and exits 0: $unapplied_reason" \
        "exit=0 same" \
        "$(rules="$(device_rules "$unapplied_config" "$unapplied_release")"
           echo "exit=$? $([ "$rules" = "$default_rules" ] && echo same)")"
    check "an unapplied choice is named on stderr: $unapplied_reason" '1' \
        "$(device_rules "$unapplied_config" "$unapplied_release" >/dev/null
           grep -c -F "$unapplied_reason; the default, shiba, applies" "$WORK/device.err")"
done

check "a user setprop still wins over the chosen preset's value" 'My Phone' \
    "$(device_rules 'device husky
setprop ro.product.model My Phone' \
        | sed -n "s|^/data/adb/ksu/bin/resetprop ro.product.model '\(.*\)'$|\1|p" | tail -n 1)"

# preset_fixture <shipped list> <preset>: a list with one preset, devices/x.conf.
preset_fixture() {
    rm -rf "$WORK/preset"
    mkdir -p "$WORK/preset/devices"
    printf '%s\n' "$1" > "$WORK/preset/artifacts.conf"
    printf '%s\n' "$2" > "$WORK/preset/devices/x.conf"
    sh "$GENERATE" "$WORK/preset/artifacts.conf" 2>"$WORK/preset.err" >/dev/null
    preset_exit=$?
    cat "$WORK/preset.err"
    echo "exit=$preset_exit"
}

check 'a preset holding another directive is rejected and names its line' \
    "$WORK/preset/devices/x.conf:2: a device preset holds only setprop, setting and android lines
exit=1" \
    "$(preset_fixture 'device x' 'android 16
hide /x')"

check "an 'android' line outside a preset is rejected and names its line" \
    "$WORK/preset/artifacts.conf:1: 'android' belongs in a device preset
exit=1" \
    "$(preset_fixture 'android 16' 'android 16')"

check 'a second shipped device line is rejected and names it' \
    "$WORK/preset/artifacts.conf:2: device is given twice
exit=1" \
    "$(preset_fixture 'device x
device x' 'android 16')"

check 'a shipped device line naming no preset is rejected' \
    "$WORK/preset/artifacts.conf:1: no preset $WORK/preset/devices/y.conf
exit=1" \
    "$(preset_fixture 'device y' 'android 16')"

# Two matching lines would make customize.sh build a filename out of both of them.
check 'the shipped config sets ro.hardware.vulkan exactly once' '1' \
    "$(grep -c '^[[:space:]]*setprop[[:space:]][[:space:]]*ro\.hardware\.vulkan[[:space:]]' "$REPO/module/artifacts.conf")"

# customize.sh reads the variant back out of artifacts.conf so the name is written
# once. If that expression breaks, the installer writes the HAL under a name the
# loader never opens and Vulkan falls back with no error anyone sees. The shipped
# expression is run here against the shipped config, not a copy of it.
# Read by the vulkan_variant expression that the next line evals out of
# customize.sh, which is why nothing in this file references it.
# shellcheck disable=SC2034
MODPATH="$REPO/module"
eval "$(grep -m1 '^[[:space:]]*vulkan_variant=' "$REPO/module/customize.sh")"

# Both sides of the next check are produced by an expression. If the one written
# here broke too, an empty string would equal an empty string and the check would
# pass while the installer named the file 'vulkan..so'.
check 'customize.sh extracts a non-empty variant' 'extracted' \
    "$([ -n "$vulkan_variant" ] && echo extracted)"

check "customize.sh extracts the variant the config sets" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | sed -n "s|^/data/adb/ksu/bin/resetprop ro\\.hardware\\.vulkan '\\(.*\\)'|\\1|p")" \
    "$vulkan_variant"

# The same for the EGL driver. A wrong name here is worse than for Vulkan: libEGL
# aborts every GL process when ro.hardware.egl names a driver with no files.
# shellcheck disable=SC2034
eval "$(grep -m1 '^[[:space:]]*egl_variant=' "$REPO/module/customize.sh")"

check 'customize.sh extracts a non-empty EGL variant' 'extracted' \
    "$([ -n "$egl_variant" ] && echo extracted)"

check 'customize.sh extracts the EGL variant the config sets' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | sed -n "s|^/data/adb/ksu/bin/resetprop ro\\.hardware\\.egl '\\(.*\\)'|\\1|p")" \
    "$egl_variant"

# A real Pixel 8 names one GPU driver for both (device/google/zuma/device.mk).
check 'the shipped EGL and Vulkan variants name the same driver' "$vulkan_variant" "$egl_variant"

# Staged labels are applied after the last recursive permission pass; a file
# staged after noemulator_apply_staged_labels would keep the module default label,
# and libEGL refuses a driver an app may not map.
check 'the EGL driver is staged before the labels are applied' 'before' \
    "$(egl_line="$(grep -n '^install_egl_driver$' "$REPO/module/customize.sh" | cut -d: -f1)"
       label_line="$(grep -n '^noemulator_apply_staged_labels$' "$REPO/module/customize.sh" | cut -d: -f1)"
       [ "$egl_line" -lt "$label_line" ] && echo before || echo after)"

check 'angle emits a call to the service helper' \
    "noemulator_angle 'com.example.app'" \
    "$(sh "$GENERATE" "$(config_with 'angle com.example.app')")"

# A package name reaches `settings put` inside an eval'd command. Anything that is
# not a package name does not belong in that string.
for bad_package in 'not a package' 'app;reboot' 'app$(id)'; do
    sh "$GENERATE" "$(config_with "angle $bad_package")" >/dev/null 2>&1
    check "angle rejects '$bad_package'" '1' "$?"
done

# ANGLE is a translation layer: naming a package by default would put an app the
# user never chose onto a different GL driver. The directive ships unused, as
# 'hide' does.
check 'the shipped config names no angle package' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c '^noemulator_angle ')"

# `settings` is a client of system_server, which does not exist at post-mount. The
# stage split is asserted the same way the redirects' is.
check 'service.sh is what applies the angle rules' '1' \
    "$(grep -c "grep '\^noemulator_angle '" "$REPO/module/service.sh")"

check 'post-fs-data applies no angle rule' '1' \
    "$(grep -c -- "-e '\^noemulator_angle '" "$REPO/module/post-fs-data.sh")"

# Regression guard, v0.4.3 (2026-10-17): `settings` wraps `cmd`, which hands its
# stdout and stderr to system_server over binder. service.sh's stdout is apply.log
# under /data/adb, which system_server may not open, so the call failed with
# "Failed transaction (2147483646)" and wrote nothing. Measured rc=2 that way and
# rc=0 with the output on /dev/null. Every settings call must redirect.
check 'every settings call sends its output to /dev/null' '0' \
    "$(grep 'settings put' "$REPO/module/service.sh" | grep -vc '>/dev/null 2>&1')"

# --- setting (issue #28) ------------------------------------------------------

check 'setting emits a call to the settings applier with the value quoted' \
    "noemulator_setting 'global' 'device_name' 'Pixel 8'" \
    "$(sh "$GENERATE" "$(config_with 'setting global device_name Pixel 8')")"

# Each malformed shape fails generation and names its line. The value reaches an
# eval'd command, so a quote must not get through; a duplicate row would have two
# values fight over one record (docs/review/0003-triage.md, finding 9).
for bad_setting in 'setting registry device_name Pixel 8' \
    'setting global device$name Pixel 8' \
    'setting global device_name' \
    "setting global device_name Pixel'8"; do
    check "setting rejects '$bad_setting' and names line 2" '1' \
        "$(printf '# first line\n%s\n' "$bad_setting" > "$WORK/conf"
           sh "$GENERATE" "$WORK/conf" 2>&1 >/dev/null | grep -c "^$WORK/conf:2: ")"
done

check 'a second setting line for the same row fails and names it' '1' \
    "$(sh "$GENERATE" "$(config_with 'setting global device_name A
setting secure device_name B
setting global device_name C')" 2>&1 >/dev/null | grep -c ":3: 'setting global device_name' is set twice")"

# --- user config (issue #60) ----------------------------------------------------

user_config_with() {
    printf '%s\n' "$1" > "$WORK/user.conf"
    echo "$WORK/user.conf"
}

# A device with no user config must run exactly what it ran before the user config
# existed, in every stage.
check 'a missing user config generates what the shipped list alone does' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf")" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$WORK/no-such-user.conf")"

check 'the user config is applied after the shipped list' \
    "/data/adb/ksu/bin/resetprop -d ro.boot.qemu.avd_name
noemulator_angle 'com.example.a'" \
    "$(sh "$GENERATE" "$(config_with 'delprop ro.boot.qemu.avd_name')" "$(user_config_with 'angle com.example.a')")"

# The duplicate check spans both files: two values would fight over one record
# just as they would within one file (docs/review/0003-triage.md, finding 9).
check 'a setting row in both files fails and names the user config line' 'exit=1 1' \
    "$(sh "$GENERATE" "$(config_with 'setting global device_name A')" \
        "$(user_config_with '# mine
setting global device_name B')" >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/user.conf:2: 'setting global device_name' is set twice" "$WORK/err")")"

check 'a malformed user config line fails and names its line' 'exit=1 1' \
    "$(sh "$GENERATE" "$(config_with 'delprop ro.boot.qemu')" \
        "$(user_config_with 'frobnicate /dev/x')" >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/user.conf:1: unknown directive 'frobnicate'" "$WORK/err")")"

# A stage that left it out would apply a user's choice in some stages and not in
# others: an angle line honoured at boot but not undone at uninstall.
check 'every stage that generates rules passes the user config' '4/4' \
    "$(calls="$(grep -h 'sh "\$MODDIR/lib/generate_rules.sh"' "$REPO"/module/*.sh)"
       echo "$(echo "$calls" | grep -c '"\$NOEMULATOR_USER_CONFIG"')/$(echo "$calls" | grep -c .)")"

# Inside the module directory, an update would replace it with the module.
check 'the user config lives under /data/adb/, outside the module directory' 'yes' \
    "$(NOEMULATOR_USER_CONFIG=''
       . "$REPO/module/lib/user_config.sh"
       case $NOEMULATOR_USER_CONFIG in
           /data/adb/modules/*|/data/adb/modules_update/*) echo no ;;
           /data/adb/*) echo yes ;;
           *) echo no ;;
       esac)"

# --- native_bridge keep (issue #62) -------------------------------------------

native_bridge_deletes='/data/adb/ksu/bin/resetprop -d ro.dalvik.vm.native.bridge
/data/adb/ksu/bin/resetprop -d ro.enable.native.bridge.exec'

# The name the kept bridge is loaded under, held until both files are read.
native_bridge_name_call="noemulator_native_bridge_name 'libsysglue.so'"

# The machine a translated arm64 app reads, held the same way.
uname_machine_call="noemulator_uname_machine 'aarch64' '/system/bin/arm64/linker64'"

# The key an app reads as unset from its own copy of the area, held the same way.
app_delprop_bridge_call="noemulator_app_delprop 'ro.dalvik.vm.native.bridge'"

# Every app-view key, in the order artifacts.conf lists them: the bridge key, the
# 13 ABI and isa.* keys, then the two on trial (#108).
app_delprop_call="$app_delprop_bridge_call
noemulator_app_delprop 'ro.product.cpu.abi'
noemulator_app_delprop 'ro.product.cpu.abilist'
noemulator_app_delprop 'ro.product.cpu.abilist32'
noemulator_app_delprop 'ro.product.cpu.abilist64'
noemulator_app_delprop 'ro.system.product.cpu.abilist'
noemulator_app_delprop 'ro.system.product.cpu.abilist32'
noemulator_app_delprop 'ro.system.product.cpu.abilist64'
noemulator_app_delprop 'ro.enable.native.bridge.exec'
noemulator_app_delprop 'ro.vendor.product.cpu.abilist'
noemulator_app_delprop 'ro.vendor.product.cpu.abilist32'
noemulator_app_delprop 'ro.vendor.product.cpu.abilist64'
noemulator_app_delprop 'ro.dalvik.vm.isa.arm'
noemulator_app_delprop 'ro.dalvik.vm.isa.arm64'
noemulator_app_delprop 'dalvik.vm.isa.x86_64.features'
noemulator_app_delprop 'dalvik.vm.isa.x86_64.variant'"

# The three ELF-header redirects, in the order artifacts.conf lists them. Held
# until both files are read, so they come after every line emitted as it is read.
elf_redirects="noemulator_redirect '/system/lib64/libc.so' '/system/lib64/arm64/libc.so' '3' 'app_only keep_ident'
noemulator_redirect '/system/bin/linker64' '/system/bin/arm64/linker64' '3' 'any_label'
noemulator_redirect '/system/lib64/libandroid_runtime.so' '/system/lib64/arm64/libandroid_runtime.so' '3'"

check 'without native_bridge keep both native bridge deletes are emitted' '2' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -cxF "$native_bridge_deletes")"

# The two deletes go, and the ELF-header redirects arrive at the end. Nothing else
# changes: ARM translation must not quietly cost another rule.
check 'native_bridge keep in the user config drops exactly the two native bridge deletes' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -vxF "$native_bridge_deletes")
$elf_redirects
$native_bridge_name_call
$uname_machine_call
$app_delprop_call" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$(user_config_with 'native_bridge keep')")"

check 'native_bridge keep in the shipped list does the same' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -vxF "$native_bridge_deletes")
$elf_redirects
$native_bridge_name_call
$uname_machine_call
$app_delprop_call" \
    "$(cat "$REPO/module/artifacts.conf" > "$WORK/conf"
       cp -R "$REPO/module/devices" "$WORK/devices"
       echo 'native_bridge keep' >> "$WORK/conf"
       sh "$GENERATE" "$WORK/conf")"

for bad_keep in 'native_bridge hide' 'native_bridge Keep' 'native_bridge keep now' \
    'boot_qemu hide' 'boot_qemu keep now'; do
    check "'$bad_keep' is rejected and names its line" 'exit=1 1' \
        "$(sh "$GENERATE" "$(config_with 'delprop ro.boot.qemu')" \
            "$(user_config_with "$bad_keep")" >/dev/null 2>"$WORK/err"
           echo "exit=$? $(grep -c "^$WORK/user.conf:1: ${bad_keep%% *} takes only 'keep'" "$WORK/err")")"
done

# --- native_bridge_name (issue #89) -------------------------------------------

native_bridge_name_line='native_bridge_name libsysglue.so'

# Without the keep the property is deleted, so a name would have nothing to point
# at. The directive is held, as the ELF-header redirects are.
check 'without native_bridge keep the shipped config emits no bridge name' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | grep -c '^noemulator_native_bridge_name ')"

check 'native_bridge keep in the user config emits the shipped bridge name' \
    "$native_bridge_name_call" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$(user_config_with 'native_bridge keep')" \
        | grep '^noemulator_native_bridge_name ')"

# The keep may come before or after the directive in the same file: the line is
# held until both files are read, as the deletes and the redirects are.
check 'native_bridge keep before the bridge name still emits it' \
    "$native_bridge_name_call" \
    "$(sh "$GENERATE" "$(config_with "native_bridge keep
$native_bridge_name_line")" | grep '^noemulator_native_bridge_name ')"

check 'native_bridge keep after the bridge name still emits it' \
    "$native_bridge_name_call" \
    "$(sh "$GENERATE" "$(config_with "$native_bridge_name_line
native_bridge keep")" | grep '^noemulator_native_bridge_name ')"

# The name reaches a path under /system/lib64 and a command the applier evals.
# A slash would leave that directory; a quote would break the command.
for bad_bridge_name in 'a/b.so' 'libx' "lib'x.so"; do
    check "native_bridge_name rejects '$bad_bridge_name' and names the line" 'exit=1 1' \
        "$(sh "$GENERATE" "$(config_with "native_bridge_name $bad_bridge_name")" >/dev/null 2>"$WORK/err"
           echo "exit=$? $(grep -c "^$WORK/conf:1: " "$WORK/err")")"
done

# One name only. The installer stages one copy, and a second line would point the
# property at a file that is not there.
check 'a second native_bridge_name line fails and names it' 'exit=1 1' \
    "$(sh "$GENERATE" "$(config_with "native_bridge_name libone.so
native_bridge_name libtwo.so")" >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/conf:2: native_bridge_name is given twice" "$WORK/err")")"

# The rename is set before zygote, by the helper post-fs-data defines, and only
# when the installer staged the file. A property naming a missing library breaks
# every ARM app.
check 'post-fs-data defines the bridge name helper' '1' \
    "$(grep -c '^noemulator_native_bridge_name()' "$REPO/module/post-fs-data.sh")"

check 'the helper checks the staged file before it writes the property' 'before' \
    "$(helper="$(sed -n '/^noemulator_native_bridge_name()/,/^}/p' "$REPO/module/post-fs-data.sh")"
       staged_line="$(printf '%s\n' "$helper" | grep -n 'no staged' | cut -d: -f1)"
       set_line="$(printf '%s\n' "$helper" | grep -n 'resetprop ro.dalvik.vm.native.bridge' | cut -d: -f1)"
       [ -n "$staged_line" ] && [ -n "$set_line" ] && [ "$staged_line" -lt "$set_line" ] && echo before || echo after)"

check 'post-fs-data does not filter the bridge name line out' '0' \
    "$(grep -c -- "-e '\^noemulator_native_bridge_name '" "$REPO/module/post-fs-data.sh")"

check 'the installer calls install_native_bridge_copy' '1' \
    "$(grep -c '^install_native_bridge_copy$' "$REPO/module/customize.sh")"

check 'post-mount does not run the bridge name helper' '0' \
    "$(grep -c 'noemulator_native_bridge_name' "$REPO/module/post-mount.sh")"

check 'service does not run the bridge name helper' '0' \
    "$(grep -c 'noemulator_native_bridge_name' "$REPO/module/service.sh")"

# --- uname_machine (issue #87) ------------------------------------------------

uname_machine_line='uname_machine aarch64 /system/bin/arm64/linker64'

# With the property deleted no arm64 app runs, so there is nothing to spoof. The
# line is held and dropped, as the ELF-header redirects are.
check 'without native_bridge keep the shipped config emits no uname machine line' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | grep -c '^noemulator_uname_machine ')"

check 'native_bridge keep in the user config emits the shipped uname machine line' \
    "$uname_machine_call" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$(user_config_with 'native_bridge keep')" \
        | grep '^noemulator_uname_machine ')"

check 'native_bridge keep before the uname machine line still emits it' \
    "$uname_machine_call" \
    "$(sh "$GENERATE" "$(config_with "native_bridge keep
$uname_machine_line")" | grep '^noemulator_uname_machine ')"

check 'native_bridge keep after the uname machine line still emits it' \
    "$uname_machine_call" \
    "$(sh "$GENERATE" "$(config_with "$uname_machine_line
native_bridge keep")" | grep '^noemulator_uname_machine ')"

# The machine and the marker reach a node line inside a command the applier evals,
# and the kernel resolves the marker to the file it matches against a process's
# maps. A machine with a space is three arguments, a quote breaks the command, and
# a relative or '..' marker names a file this config does not mean. An empty
# machine leaves one argument.
for bad_uname_machine in 'uname_machine aa rch /system/bin/arm64/linker64' \
    "uname_machine a'b /system/bin/arm64/linker64" \
    'uname_machine /system/bin/arm64/linker64' \
    'uname_machine aarch64 relative/marker' \
    'uname_machine aarch64 /a/../b' \
    "uname_machine aarch64 /system/bin/a'b" \
    'uname_machine aarch64 /system/bin/arm64/linker64 extra'; do
    check "'$bad_uname_machine' is rejected and names the line" 'exit=1 1' \
        "$(printf '# first line\n%s\n' "$bad_uname_machine" > "$WORK/conf"
           sh "$GENERATE" "$WORK/conf" >/dev/null 2>"$WORK/err"
           echo "exit=$? $(grep -c "^$WORK/conf:2: " "$WORK/err")")"
done

check 'uname_machine rejects a machine over 64 characters and names the line' 'exit=1 1' \
    "$(uname_long_machine="$(printf '%65s' '' | tr ' ' a)"
       sh "$GENERATE" "$(config_with "uname_machine $uname_long_machine /system/bin/marker")" \
           >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/conf:1: " "$WORK/err")")"

check 'a second uname_machine line fails and names it' 'exit=1 1' \
    "$(sh "$GENERATE" "$(config_with "$uname_machine_line
uname_machine aarch64 /system/bin/other")" >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/conf:2: uname_machine is given twice" "$WORK/err")")"

# The write runs at post-mount, before the open-redirect guard: it needs neither
# that node nor the overlay, and a kernel with one susfs feature and not the other
# must not lose the spoof with the redirects.
check 'post-mount defines the uname machine helper' '1' \
    "$(grep -c '^noemulator_uname_machine()' "$REPO/module/post-mount.sh")"

check 'the helper checks the node and the marker before it writes' 'before' \
    "$(helper="$(sed -n '/^noemulator_uname_machine()/,/^}/p' "$REPO/module/post-mount.sh")"
       node_line="$(printf '%s\n' "$helper" | grep -n 'SUSFS_UNAME_MACHINE_NODE" \]' | cut -d: -f1)"
       marker_line="$(printf '%s\n' "$helper" | grep -n -- '-e "\$uname_machine_marker"' | cut -d: -f1)"
       set_line="$(printf '%s\n' "$helper" | grep -n 'echo "set \$uname_machine_name' | cut -d: -f1)"
       [ -n "$node_line" ] && [ -n "$marker_line" ] && [ -n "$set_line" ] &&
           [ "$node_line" -lt "$set_line" ] && [ "$marker_line" -lt "$set_line" ] &&
           echo before || echo after)"

check 'post-mount applies the uname machine rules before the redirect-node guard' 'before' \
    "$(uname_rules_line="$(grep -n "grep '\^noemulator_uname_machine '" "$REPO/module/post-mount.sh" | cut -d: -f1)"
       guard_line="$(grep -n '\[ ! -e "\$SUSFS_REDIRECT_NODE" \]' "$REPO/module/post-mount.sh" | cut -d: -f1)"
       [ -n "$uname_rules_line" ] && [ -n "$guard_line" ] && [ "$uname_rules_line" -lt "$guard_line" ] &&
           echo before || echo after)"

check 'post-fs-data applies no uname machine rule' '1' \
    "$(grep -c -- "-e '\^noemulator_uname_machine '" "$REPO/module/post-fs-data.sh")"

check 'service does not run the uname machine rules' '0' \
    "$(grep -c 'noemulator_uname_machine' "$REPO/module/service.sh")"

# --- app_delprop (issue #107) -------------------------------------------------

app_delprop_line='app_delprop ro.dalvik.vm.native.bridge needs_native_bridge'

# The ABI and bridge keys are read by an app only while the ARM bridge is kept.
# Without it the property is deleted above and no app runs under the translator,
# so their lines are held and dropped, as the uname machine line is. The init
# service keys are not flagged: those services run whatever the bridge setting
# (ADR 0032).
check 'without native_bridge keep the shipped config hides exactly the seven init service keys' \
    "init.svc.android-hardware-media-c2-goldfish-hal-1-0
init.svc.qemu-device-state
init.svc.qemu-props
init.svc.qemu-props-bootcomplete
init.svc.ranchu-adb-setup
init.svc.ranchu-net
init.svc.ranchu-setup" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | grep '^noemulator_app_delprop ' | cut -d"'" -f2 | sort)"

check 'an app_delprop line without the flag is emitted without native_bridge keep' \
    "noemulator_app_delprop 'init.svc.ranchu-net'" \
    "$(sh "$GENERATE" "$(config_with 'app_delprop init.svc.ranchu-net')" | grep '^noemulator_app_delprop ')"

check 'without native_bridge keep a flagged app_delprop line is dropped' '0' \
    "$(sh "$GENERATE" "$(config_with "$app_delprop_line")" | grep -c '^noemulator_app_delprop ')"

check 'native_bridge keep before the app_delprop line still emits it' \
    "$app_delprop_bridge_call" \
    "$(sh "$GENERATE" "$(config_with "native_bridge keep
$app_delprop_line")" | grep '^noemulator_app_delprop ')"

check 'native_bridge keep after the app_delprop line still emits it' \
    "$app_delprop_bridge_call" \
    "$(sh "$GENERATE" "$(config_with "$app_delprop_line
native_bridge keep")" | grep '^noemulator_app_delprop ')"

# The whole list, once: 14 ABI, isa.* and bridge keys plus the two on trial
# (#108), which is what keep adds to the seven init service keys. Sorted, so the
# check reads as the list rather than as the file's order; a key repeated by
# mistake still shows up as a repeated line.
check 'native_bridge keep adds exactly the sixteen shipped bridge keys' \
    "dalvik.vm.isa.x86_64.features
dalvik.vm.isa.x86_64.variant
ro.dalvik.vm.isa.arm
ro.dalvik.vm.isa.arm64
ro.dalvik.vm.native.bridge
ro.enable.native.bridge.exec
ro.product.cpu.abi
ro.product.cpu.abilist
ro.product.cpu.abilist32
ro.product.cpu.abilist64
ro.system.product.cpu.abilist
ro.system.product.cpu.abilist32
ro.system.product.cpu.abilist64
ro.vendor.product.cpu.abilist
ro.vendor.product.cpu.abilist32
ro.vendor.product.cpu.abilist64" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$(user_config_with 'native_bridge keep')" \
        | grep '^noemulator_app_delprop ' | cut -d"'" -f2 | grep -v '^init\.svc\.' | sort)"

# The key reaches a command the applier evals and a path built from it under
# /dev/__properties__. A quote breaks out of the quoting, a space makes two
# arguments, and a semicolon starts a second command.
for bad_app_delprop in 'app_delprop' "app_delprop a'b" 'app_delprop a b' 'app_delprop a;b' \
    'app_delprop a needs_native_bridge extra'; do
    check "'$bad_app_delprop' is rejected and names the line" 'exit=1 1' \
        "$(printf '# first line\n%s\n' "$bad_app_delprop" > "$WORK/conf"
           sh "$GENERATE" "$WORK/conf" >/dev/null 2>"$WORK/err"
           echo "exit=$? $(grep -c "^$WORK/conf:2: " "$WORK/err")")"
done

# One view per area: a second line for the same key would delete it twice and the
# log would count it twice.
check 'the same app_delprop key twice fails and names the second line' 'exit=1 1' \
    "$(sh "$GENERATE" "$(config_with "$app_delprop_line
$app_delprop_line")" >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/conf:2: app_delprop ro.dalvik.vm.native.bridge is given twice" "$WORK/err")")"

check 'an app_delprop key in both files fails and names the user config line' 'exit=1 1' \
    "$(sh "$GENERATE" "$(config_with "$app_delprop_line")" \
        "$(user_config_with "# mine
$app_delprop_line")" >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/user.conf:2: app_delprop ro.dalvik.vm.native.bridge is given twice" "$WORK/err")")"

# The copy is built at post-mount, not post-fs-data: another module's post-fs-data
# property write may land after this module's, and the copy is frozen. post-fs-data
# must hand the line on untouched.
check 'post-fs-data applies no app_delprop rule' '1' \
    "$(grep -c -- "-e '\^noemulator_app_delprop '" "$REPO/module/post-fs-data.sh")"

check 'post-mount runs the app property view after the redirect-node guard and before the first generic redirect' 'before' \
    "$(app_view_line="$(grep -n 'noemulator_app_property_view ' "$REPO/module/post-mount.sh" | cut -d: -f1 | head -n 1)"
       guard_line="$(grep -n '\[ ! -e "\$SUSFS_REDIRECT_NODE" \]' "$REPO/module/post-mount.sh" | cut -d: -f1)"
       redirect_line="$(grep -n "grep '\^noemulator_redirect '" "$REPO/module/post-mount.sh" | cut -d: -f1)"
       [ -n "$app_view_line" ] && [ -n "$guard_line" ] && [ -n "$redirect_line" ] &&
           [ "$guard_line" -lt "$app_view_line" ] && [ "$app_view_line" -lt "$redirect_line" ] &&
           echo before || echo after)"

# The probe's first attempt bind-mounted into init's namespace and leaked an
# edited area to every process that opened one for a minute. unshare -m alone keeps
# shared propagation, so the make-rprivate call has to come before any bind.
check 'the library makes the namespace private before its first bind mount' 'before' \
    "$(private_line="$(grep -n 'mount --make-rprivate' "$REPO/module/lib/app_property_view.sh" | cut -d: -f1)"
       bind_line="$(grep -n -- '--bind' "$REPO/module/lib/app_property_view.sh" | cut -d: -f1)"
       [ -n "$private_line" ] && [ -n "$bind_line" ] && [ "$private_line" -lt "$bind_line" ] &&
           echo before || echo after)"

# Without the hide an app finds the view by name: the directory answers EACCES
# where a missing path answers ENOENT, and a copy opens by its path (#107).
check 'the library hides the copy directory from apps' '1' \
    "$(grep -c 'echo "add $prop_view_dir" > "$NOEMULATOR_PROP_VIEW_HIDE_NODE"' "$REPO/module/lib/app_property_view.sh")"

# -n keeps the property service out of the edit. Without it the copy would be
# announced, and a rebuild without -n would reach every reader.
check 'every resetprop call in the library carries -n' '0' \
    "$(grep 'prop_view_resetprop ' "$REPO/module/lib/app_property_view.sh" \
        | grep -vc -- ' -n ')"

# The area allowlist, run for real against stubs. getprop -Z answers from one
# '<key> <context>' line, and both /proc nodes are plain files, so what the
# library writes can be read back. A view of an area an app cannot read is itself
# visible (ADR 0029), so the key has to be refused, not copied.
PROP_VIEW_BIN="$WORK/prop-view-bin"
mkdir -p "$PROP_VIEW_BIN"
cat > "$PROP_VIEW_BIN/getprop" <<'STUB'
#!/bin/sh
# getprop -Z <key>: the key's context; nothing for a bare listing.
[ "${1:-}" = -Z ] && [ -n "${2:-}" ] || exit 0
grep -F "$2 " "$PROP_VIEW_ANSWERS" 2>/dev/null | cut -d' ' -f2
STUB
chmod +x "$PROP_VIEW_BIN/getprop"

# run_prop_view <key> <context, or nothing>: the library's log, then the bytes
# written to each node file and whether a copy directory was left behind.
run_prop_view() {
    rm -rf "$WORK/prop-view"
    mkdir -p "$WORK/prop-view"
    : > "$WORK/prop-view/node"
    : > "$WORK/prop-view/redirect-node"
    : > "$WORK/prop-view/hide-node"
    printf '%s %s\n' "$1" "$2" > "$WORK/prop-view/answers"
    printf "noemulator_app_delprop '%s'\n" "$1" > "$WORK/prop-view/rules"
    PATH="$PROP_VIEW_BIN:$PATH" PROP_VIEW_ANSWERS="$WORK/prop-view/answers" \
        sh -c ". '$REPO/module/lib/app_property_view.sh'
               NOEMULATOR_PROP_VIEW_DIR='$WORK/prop-view/copies'
               NOEMULATOR_PROP_VIEW_NODE='$WORK/prop-view/node'
               NOEMULATOR_PROP_VIEW_REDIRECT_NODE='$WORK/prop-view/redirect-node'
               NOEMULATOR_PROP_VIEW_HIDE_NODE='$WORK/prop-view/hide-node'
               noemulator_app_property_view '$WORK/prop-view/rules'"
    echo "node=$(wc -c < "$WORK/prop-view/node" | tr -d ' ') redirect=$(wc -c < "$WORK/prop-view/redirect-node" | tr -d ' ')"
    [ -s "$WORK/prop-view/hide-node" ] && echo "hide=$(cat "$WORK/prop-view/hide-node")"
    [ -e "$WORK/prop-view/copies" ] && echo 'copy dir left'
    return 0
}

check 'the library refuses a key in an area apps cannot read' \
    "app property view: ro.odm.product.cpu.abilist is in vendor_default_prop, which apps cannot be given a view of; skipped
node=0 redirect=0" \
    "$(run_prop_view ro.odm.product.cpu.abilist u:object_r:vendor_default_prop:s0)"

check 'the library refuses a key getprop -Z answers with nothing' \
    "app property view: dalvik.vm.isa.x86_64.variant is in no context, which apps cannot be given a view of; skipped
node=0 redirect=0" \
    "$(run_prop_view dalvik.vm.isa.x86_64.variant '')"

# Six of the seven emulator services start after post-mount, so a copy of their
# area built there would freeze states that have not happened yet (ADR 0032).
# Nothing is registered for it; the directory its copy goes into is made and
# hidden, so the service.sh refresh has somewhere to build.
check 'post-mount defers a live area and only hides the view directory' \
    "app property view: init_service_status_private_prop: built once boot is up
node=0 redirect=0
hide=add $WORK/prop-view/copies
copy dir left" \
    "$(run_prop_view init.svc.ranchu-net u:object_r:init_service_status_private_prop:s0)"

# uninstall.sh deletes no copy: ksud removes the module before its stage scripts
# run, so only a copy on tmpfs is gone after uninstall and reboot (#109).
check 'the app property view copies live on the /dev tmpfs' '1' \
    "$(grep -c '^NOEMULATOR_PROP_VIEW_DIR=/dev/' "$REPO/module/lib/app_property_view.sh")"

# The copies are frozen at post-mount, and another module's service.sh may write
# an area after that. Service is the last stage after boot, so the refresh runs
# there, once the late deletions are in the copies and before the card is flagged.
check 'service refreshes the app property view after the delprop_once_set wait and before module_status' 'before' \
    "$(refresh_line="$(grep -n 'noemulator_app_property_view_refresh ' "$REPO/module/service.sh" | cut -d: -f1 | head -n 1)"
       wait_line="$(grep -n 'delprop_once_set done' "$REPO/module/service.sh" | cut -d: -f1 | head -n 1)"
       status_line="$(grep -n 'module_status.sh' "$REPO/module/service.sh" | cut -d: -f1 | head -n 1)"
       [ -n "$refresh_line" ] && [ -n "$wait_line" ] && [ -n "$status_line" ] &&
           [ "$wait_line" -lt "$refresh_line" ] && [ "$refresh_line" -lt "$status_line" ] &&
           echo before || echo after)"

# run_prop_view_refresh <node contents>: the library's refresh log, the writes
# the node received and whether a staging directory was left. No view directory
# means post-mount set up no view, so nothing at all is written.
run_prop_view_refresh() {
    rm -rf "$WORK/prop-view-refresh"
    mkdir -p "$WORK/prop-view-refresh"
    printf '%s' "$1" > "$WORK/prop-view-refresh/node"
    : > "$WORK/prop-view-refresh/redirect-node"
    : > "$WORK/prop-view-refresh/rules"
    PATH="$PROP_VIEW_BIN:$PATH" PROP_VIEW_ANSWERS=/dev/null \
        sh -c ". '$REPO/module/lib/app_property_view.sh'
               NOEMULATOR_PROP_VIEW_DIR='$WORK/prop-view-refresh/copies'
               NOEMULATOR_PROP_VIEW_NODE='$WORK/prop-view-refresh/node'
               NOEMULATOR_PROP_VIEW_REDIRECT_NODE='$WORK/prop-view-refresh/redirect-node'
               noemulator_app_property_view_refresh '$WORK/prop-view-refresh/rules'"
    echo "writes=$(grep -c -e '^add ' -e '^clear' "$WORK/prop-view-refresh/node")"
    [ -e "$WORK/prop-view-refresh/copies" ] && echo 'copy dir left'
    return 0
}

check 'the refresh skips when post-mount left no view directory and writes nothing' \
    "app property view refresh: post-mount set up no view; skipped
writes=0" \
    "$(run_prop_view_refresh 'swapped: 0
failed: 0
')"

# run_prop_view_watch <live copy: yes or no> <sums, one per pass>: what the
# watcher rebuilt. The area checksum and the refresh are replaced: one reads the
# device's property area and the other needs root and a mount namespace, and
# what is under test is when the loop rebuilds and when it stops. The stand-in
# refresh records the sum it built from, as the real one does, and the rules file
# is removed after the last sum, which is how an uninstall ends the loop.
run_prop_view_watch() {
    rm -rf "$WORK/prop-view-watch"
    mkdir -p "$WORK/prop-view-watch/copies"
    : > "$WORK/prop-view-watch/rules"
    [ "$1" = yes ] && : > "$WORK/prop-view-watch/copies/init_service_status_private_prop"
    printf '%s\n' "$2" > "$WORK/prop-view-watch/sums"
    echo s0 > "$WORK/prop-view-watch/copies/.live_sum"
    sh -c ". '$REPO/module/lib/app_property_view.sh'
           NOEMULATOR_PROP_VIEW_DIR='$WORK/prop-view-watch/copies'
           NOEMULATOR_PROP_VIEW_WATCH_INTERVAL=0
           noemulator_prop_view_live_sum() {
               sum=\$(head -n 1 '$WORK/prop-view-watch/sums')
               sed -i 1d '$WORK/prop-view-watch/sums'
               [ -s '$WORK/prop-view-watch/sums' ] || rm -f '$WORK/prop-view-watch/rules'
               echo \"\$sum\" > '$WORK/prop-view-watch/last'
               echo \"\$sum\"
           }
           noemulator_app_property_view_refresh() {
               echo \"rebuilt from \$(cat '$WORK/prop-view-watch/last')\"
               cp '$WORK/prop-view-watch/last' '$WORK/prop-view-watch/copies/.live_sum'
           }
           noemulator_app_property_view_watch '$WORK/prop-view-watch/rules'"
    return 0
}

check 'the watcher rebuilds only on a pass whose live area changed, and stops once the rules are gone' \
    "app property view: a live area changed; rebuilding
rebuilt from s1
app property view: a live area changed; rebuilding
rebuilt from s2" \
    "$(run_prop_view_watch yes 's0
s1
s1
s2
s2')"

check 'the watcher starts no loop when no live area has a copy' '' \
    "$(run_prop_view_watch no 's1')"

# An app that takes its uid between the clear and an area's add gets the real
# area, and the watcher rebuilds again and again. Every prop view add comes
# straight after the clear, before any redirect is rewritten (12 ms against
# 109 ms on the reference AVD). Both nodes are the same pipe here, so the order
# of the writes can be read; a regular file would be truncated by each write.
check 'the refresh re-adds every prop view entry before it rewrites any redirect' \
    "clear
add build_prop
add init_service_status_private_prop
del build_prop
add_open_redirect build_prop
del init_service_status_private_prop
add_open_redirect init_service_status_private_prop" \
    "$(rm -rf "$WORK/prop-view-order"
       mkdir -p "$WORK/prop-view-order/copies"
       : > "$WORK/prop-view-order/copies/build_prop"
       : > "$WORK/prop-view-order/copies/init_service_status_private_prop"
       sh -c ". '$REPO/module/lib/app_property_view.sh'
              NOEMULATOR_PROP_VIEW_NODE=/dev/stdout
              NOEMULATOR_PROP_VIEW_REDIRECT_NODE=/dev/stdout
              prop_view_dir='$WORK/prop-view-order/copies'
              noemulator_prop_view_replace" | cat |
           sed 's|^\([a-z_]*\) /dev/__properties__/u:object_r:\([a-z_]*\):s0.*|\1 \2|')"

# Regression, 2026-10-20: KernelSU ran this module's post-fs-data before
# susfs_lkm_x64's, so every early rule was skipped. The loader must be asked
# first, and before the check that gives up.
check 'post-fs-data runs the susfs loader before giving up on susfs' 'yes' \
    "$(loader=$(grep -n 'sh "\$SUSFS_LOADER"' "$REPO/module/post-fs-data.sh" | cut -d: -f1)
       giveup=$(grep -n 'susfs not loaded; nothing applied' "$REPO/module/post-fs-data.sh" | cut -d: -f1)
       [ -n "$loader" ] && [ -n "$giveup" ] && [ "$loader" -lt "$giveup" ] && echo yes)"

# --- kstat_inode (issue #78) -------------------------------------------------

check 'kstat_inode registers the inode and leaves the other eleven fields live' \
    "echo 'add_sus_kstat_statically /data/local/tmp 1234 default default default default default default default default default default default' > /proc/susfs_kstat" \
    "$(sh "$GENERATE" "$(config_with 'kstat_inode /data/local/tmp 1234')")"

for bad_kstat in 'kstat_inode /data/local/tmp' 'kstat_inode data/local/tmp 1234' \
    'kstat_inode /data/local/tmp 12a4' 'kstat_inode /data/local/tmp 0' \
    "kstat_inode /data/x';reboot 1234"; do
    check "'$bad_kstat' is rejected and names its line" 'exit=1 1' \
        "$(sh "$GENERATE" "$(config_with "$bad_kstat")" >/dev/null 2>"$WORK/err"
           echo "exit=$? $(grep -c "^$WORK/conf:1: " "$WORK/err")")"
done

# --- relabel (issue #123) -----------------------------------------------------

check 'relabel emits a call to the post-fs-data helper' \
    "noemulator_relabel '/sys/devices/platform/GFSH0001:00/power_supply' 'u:object_r:sysfs:s0'" \
    "$(sh "$GENERATE" "$(config_with 'relabel /sys/devices/platform/GFSH0001:00/power_supply u:object_r:sysfs:s0')")"

# Both fields are quoted into the emitted line, so a quote in either is an injection.
for bad_relabel in 'relabel /sys/x' 'relabel sys/x u:object_r:sysfs:s0' \
    "relabel /sys/x';reboot u:object_r:sysfs:s0" 'relabel /sys/x sysfs' \
    "relabel /sys/x u:object_r:sys'fs:s0" 'relabel /sys/x u:r:sysfs:s0' \
    'relabel /sys/x u:object_r:sysfs:s0 extra'; do
    check "'$bad_relabel' is rejected and names its line" 'exit=1 1' \
        "$(sh "$GENERATE" "$(config_with "$bad_relabel")" >/dev/null 2>"$WORK/err"
           echo "exit=$? $(grep -c "^$WORK/conf:1: " "$WORK/err")")"
done

# The helper is run with chcon and toybox stat replaced at the boundary: the host
# has no SELinux. The fake chcon records the label, the fake stat reads it back,
# unless the run sets a label that does not take.
eval "$(sed -n '/^noemulator_relabel()/,/^}/p' "$REPO/module/post-fs-data.sh")"
chcon() { [ -n "${relabel_ignored:-}" ] || printf '%s' "$1" > "$WORK/label"; }
printf '#!/bin/sh\ncat %s\n' "$WORK/label" > "$WORK/fake_toybox"
chmod +x "$WORK/fake_toybox"
# Read by the helper evaled above, which is why nothing in this file references it.
# shellcheck disable=SC2034
NOEMULATOR_STAT="$WORK/fake_toybox"
mkdir -p "$WORK/power_supply"

check 'the relabel helper succeeds when the label reads back' 'rc=0' \
    "$(printf 'u:object_r:sysfs_batteryinfo:s0' > "$WORK/label"
       noemulator_relabel "$WORK/power_supply" u:object_r:sysfs:s0 >/dev/null; echo "rc=$?")"

# A chcon that returns 0 while the label stays is a rule that did nothing; it must
# be a failed rule, or the artifact stays with health reading ok.
check 'the relabel helper fails when the label does not read back' 'rc=1' \
    "$(printf 'u:object_r:sysfs_batteryinfo:s0' > "$WORK/label"
       relabel_ignored=1 noemulator_relabel "$WORK/power_supply" u:object_r:sysfs:s0 >/dev/null; echo "rc=$?")"

check 'the relabel helper skips a missing path without calling chcon' \
    "rc=0 relabel: no $WORK/no_such_dir; skipped label=unchanged" \
    "$(printf unchanged > "$WORK/label"
       out="$(noemulator_relabel "$WORK/no_such_dir" u:object_r:sysfs:s0)"
       echo "rc=$? $out label=$(cat "$WORK/label")")"

# ADR 0031. Only the parent: battery and its files keep sysfs_batteryinfo, so apps
# still cannot read the battery, as on a real phone.
check 'the shipped config relabels only the AVD power_supply directory, to sysfs' \
    "noemulator_relabel '/sys/devices/platform/GFSH0001:00/power_supply' 'u:object_r:sysfs:s0'" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep '^noemulator_relabel ')"

# Applied by post-fs-data with the property rules, before zygote: a later stage
# would let an app started earlier read the real inode.
check 'the shipped config spoofs the /data/local/tmp inode' '1' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c "> /proc/susfs_kstat$")"

# --- boot_qemu keep (issue #76) -----------------------------------------------

boot_qemu_delete='/data/adb/ksu/bin/resetprop -d ro.boot.qemu'

check 'without boot_qemu keep the ro.boot.qemu delete is emitted' '1' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -cxF "$boot_qemu_delete")"

# Host clipboard sync must cost exactly the one delete, and the two keeps must not
# leak into each other: the ARM switch must not bring the emulator flag back.
check 'boot_qemu keep drops exactly the ro.boot.qemu delete' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -vxF "$boot_qemu_delete")" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$(user_config_with 'boot_qemu keep')")"

check 'native_bridge keep still emits the ro.boot.qemu delete' '1' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$(user_config_with 'native_bridge keep')" \
        | grep -cxF "$boot_qemu_delete")"

# `settings` needs system_server, so the rows are written from service.sh after
# sys.boot_completed, and no earlier stage may run a setting rule.
check 'service.sh is what applies the setting rules' '1' \
    "$(grep -c "grep '\^noemulator_setting '" "$REPO/module/service.sh")"

check 'service.sh applies the setting rules only after boot completed' 'after' \
    "$(boot_line="$(grep -n 'sys.boot_completed' "$REPO/module/service.sh" | head -n 1 | cut -d: -f1)"
       setting_line="$(grep -n "grep '\^noemulator_setting '" "$REPO/module/service.sh" | cut -d: -f1)"
       [ -n "$setting_line" ] && [ "$boot_line" -lt "$setting_line" ] && echo after || echo before)"

check 'post-fs-data applies no setting rule' '1' \
    "$(grep -c -- "-e '\^noemulator_setting '" "$REPO/module/post-fs-data.sh")"

check 'post-mount applies no setting rule' '0' \
    "$(grep -c 'noemulator_setting' "$REPO/module/post-mount.sh")"

# Same regression as the check above, for the library that writes the rows.
check 'every settings put and delete in the setting library goes to /dev/null' '0' \
    "$(grep -E 'settings (put|delete)' "$REPO/module/lib/setting_record.sh" | grep -v '^[[:space:]]*#' | grep -vc '>/dev/null 2>&1')"

# ksud deletes the module directory on uninstall and an update replaces it; the
# record is what restore reads afterwards, so it must live elsewhere.
check 'the setting record lives outside the module tree' 'outside' \
    "$(record_dir="$(sed -n 's/^NOEMULATOR_SETTING_RECORD_DIR=\${NOEMULATOR_SETTING_RECORD_DIR:-\(.*\)}$/\1/p' \
        "$REPO/module/lib/setting_record.sh")"
       case "$record_dir" in
           /data/adb/modules/*|/data/adb/modules_update/*|*MODDIR*|'') echo inside ;;
           /data/adb/*) echo outside ;;
           *) echo "elsewhere: $record_dir" ;;
       esac)"

check 'redirect emits a call to the post-mount helper' \
    "noemulator_redirect '/dev/goldfish_sync' '/dev/sync_fence0' '2'" \
    "$(sh "$GENERATE" "$(config_with 'redirect /dev/goldfish_sync /dev/sync_fence0 2')")"

sh "$GENERATE" "$(config_with 'redirect /dev/a /dev/b')" >/dev/null 2>&1
check 'redirect without a uid_scheme exits non-zero' '1' "$?"

# 0-4 are the whole range; the node refuses anything else with -EINVAL, and a
# refused rule means the artifact stays visible with nothing saying so.
sh "$GENERATE" "$(config_with 'redirect /dev/a /dev/b 5')" >/dev/null 2>&1
check 'redirect with an out-of-range uid_scheme exits non-zero' '1' "$?"

# Without the bridge the arm64 copies mean nothing, so the three lines are
# dropped rather than applied.
check 'without native_bridge keep the shipped config emits no ELF header redirect' '' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | grep -e '/system/lib64/arm64/' -e '/system/bin/arm64/')"

# With the bridge kept, all three appear, with the flags the applier acts on and
# without needs_native_bridge, which the generator consumes. The filter is on the
# redirect prefix, because the uname machine line now names the same arm64 linker.
check 'native_bridge keep emits all three ELF header redirects with their flags' \
    "$elf_redirects" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$(user_config_with 'native_bridge keep')" \
        | grep -e "^noemulator_redirect '.*/system/lib64/arm64/" \
            -e "^noemulator_redirect '.*/system/bin/arm64/")"

elf_libc_redirect='redirect /system/lib64/libc.so /system/lib64/arm64/libc.so 3 app_only needs_native_bridge'

# The keep may come before or after the rule in the same file: the line is held
# until both files are read, as the deletes are.
check 'native_bridge keep before the ELF redirect still emits it' '1' \
    "$(sh "$GENERATE" "$(config_with "native_bridge keep
$elf_libc_redirect")" | grep -c '/system/lib64/arm64/libc.so')"

check 'native_bridge keep after the ELF redirect still emits it' '1' \
    "$(sh "$GENERATE" "$(config_with "$elf_libc_redirect
native_bridge keep")" | grep -c '/system/lib64/arm64/libc.so')"

check 'an unknown redirect flag fails and names its line' 'exit=1 1' \
    "$(sh "$GENERATE" "$(config_with 'redirect /dev/a /dev/b 2 sideways')" >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/conf:1: unknown redirect flag 'sideways'" "$WORK/err")")"

check 'a repeated redirect flag fails and names its line' 'exit=1 1' \
    "$(sh "$GENERATE" "$(config_with 'redirect /dev/a /dev/b 2 any_label any_label')" >/dev/null 2>"$WORK/err"
       echo "exit=$? $(grep -c "^$WORK/conf:1: redirect flag 'any_label' is given twice" "$WORK/err")")"

# The applier is run with the susfs node replaced at the boundary. A plain file
# stands in for a build that takes every flag; a fake write that refuses any line
# carrying keep_ident stands in for a build older than the flag (issue #130). The
# label match needs SELinux, which the host lacks, so it is stubbed to pass.
eval "$(sed -n -e '/^noemulator_redirect_write()/,/^}/p' -e '/^noemulator_redirect()/,/^}/p' \
    "$REPO/module/post-mount.sh")"
noemulator_labels_match() { return 0; }
: > "$WORK/redirect_target"
: > "$WORK/redirect_replacement"
# Read by the helpers evaled above, which is why nothing in this file references it.
# shellcheck disable=SC2034
SUSFS_REDIRECT_NODE="$WORK/redirect_node"
keep_ident_rule="add_open_redirect $WORK/redirect_target $WORK/redirect_replacement 3 no_reverse app_only"

check 'a susfs build with keep_ident gets the rule with the flag' "$keep_ident_rule keep_ident" \
    "$(noemulator_redirect "$WORK/redirect_target" "$WORK/redirect_replacement" 3 'app_only keep_ident' >/dev/null
       cat "$WORK/redirect_node")"

# The WebUI status counts applied redirects by this one line format. A keep_ident
# rule logged in another shape was applied but not counted (found on the AVD).
check 'a keep_ident rule logs the applied line the status counts' '1' \
    "$(noemulator_redirect "$WORK/redirect_target" "$WORK/redirect_replacement" 3 'app_only keep_ident' \
        | grep -c '^redirect: .* -> .* (scheme [0-4])$')"

check 'a susfs build without keep_ident gets the rule without it, and the log says so' \
    "$keep_ident_rule
1" \
    "$(noemulator_redirect_write() {
           case "$1" in *keep_ident*) return 1 ;; esac
           echo "$1" >> "$WORK/accepted"
       }
       : > "$WORK/accepted"
       noemulator_redirect "$WORK/redirect_target" "$WORK/redirect_replacement" 3 'app_only keep_ident' \
           > "$WORK/apply_log"
       cat "$WORK/accepted"
       grep -c "susfs has no keep_ident; $WORK/redirect_target is written without it" "$WORK/apply_log")"

# A replacement carrying a token would rename one hit into another: the detector
# greps the whole path for 'goldfish', 'ranchu' and 'qemu'.
check_invariant 1 'no shipped redirect replaces a path with another emulator token' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | sed -n "s/^noemulator_redirect '[^']*' '\\([^']*\\)'.*/\\1/p" \
        | grep -c -E 'goldfish|ranchu|qemu')"

# customize.sh stages a library replacement by reading the same redirect lines the
# generator reads. If its expression stops matching, the file is never staged,
# post-fs-data skips the rule, and the artifact stays visible with nothing failing.
# The generator is run with native_bridge keep so it emits every line; otherwise
# the held ELF-header lines would be missing on this side only. The shipped
# expression is run here against the shipped config.
# c absorbs the uid_scheme and the flags so they do not land in b.
# shellcheck disable=SC2034
check_invariant 1 'customize.sh sees the same redirect lines the generator does' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$(user_config_with 'native_bridge keep')" \
        | sed -n "s/^noemulator_redirect '\\([^']*\\)' '\\([^']*\\)'.*/\\1 \\2/p")" \
    "$(eval "$(grep -m1 "^[[:space:]]*sed -n 's/\\^\\[\\[:space:\\]\\]\\*redirect" "$REPO/module/customize.sh" | cut -d'>' -f1)" \
        | while read -r a b c; do echo "$a $b"; done)"

# Regression guard, v0.4.0 (2026-10-16): the redirects ran at post-fs-data, where
# the module's /vendor overlay is not mounted, so the mapper rule found no
# replacement and was skipped. The same boot also left the cloned nodes labelled
# u:object_r:device:s0 because busybox stat has no %C, every non-su process got
# EACCES on them, and the device never reached sys.boot_completed. Recovery
# needed adb. The stage split is what makes that failure survivable, so it is
# asserted, not left to a comment.
check_invariant 1 'post-fs-data applies no redirect rule' '1' \
    "$(grep -c -- "-e '\^noemulator_redirect '" "$REPO/module/post-fs-data.sh")"

# Regression guard, v0.4.1 (2026-10-16): the redirects moved to service.sh, which
# runs after sys.boot_completed -- 20 seconds after the overlay mounts on the
# target AVD. A detector already running by then had opened
# /dev/goldfish_pipe_dprctd under its real name and its exported report still
# named it. post-mount is the only stage where the overlay is up and zygote is
# not yet running, so the stage is asserted on both sides.
check_invariant 1 'post-mount.sh is what applies the redirect rules' '1' \
    "$(grep -c "grep '\^noemulator_redirect '" "$REPO/module/post-mount.sh")"

check_invariant 1 'service.sh applies no redirect rule' '0' \
    "$(grep -c 'noemulator_redirect' "$REPO/module/service.sh")"

# The v0.4.0 incident: chcon's exit status was trusted. The label is read back now.
check_invariant 4 'the node clone verifies the label it set' '1' \
    "$(grep -c 'did not take the label' "$REPO/module/post-mount.sh")"

# Regression guard, v0.4.1 (2026-10-16): both staged libraries shipped labelled
# u:object_r:system_file:s0 instead of same_process_hal_file:s0, because
# install_redirect_libraries ran set_perm_recursive over the whole overlay after
# install_vulkan_hal had set its label, and because the installer relocates
# $MODPATH/system/vendor. A rule pointing at a file an app may not map is worse
# than no rule, so both ends are asserted: the installer applies labels only
# after its last recursive pass, and post-mount refuses a mismatched replacement.
check_invariant 4 'the installer sets staged labels after the recursive permission pass' '1' \
    "$(sed -n '/^noemulator_apply_staged_labels()/,/^}/p' "$REPO/module/customize.sh" \
        | grep -c 'set_perm_recursive')"

for staging_function in install_vulkan_hal install_redirect_libraries; do
    check_invariant 4 "$staging_function sets no permissions of its own" '0' \
        "$(sed -n "/^$staging_function()/,/^}/p" "$REPO/module/customize.sh" | grep -c 'set_perm')"
done

# A replacement already on the image is left alone. The ELF-header rules point at
# the real arm64 libraries, and staging the x86_64 target over one would replace
# the very file the rule serves (ADR 0026). One the installed NoEmulator delivers
# (mapper.zuma.so) is staged again, or an update would drop it at the reboot.
check 'install_redirect_libraries skips a replacement the image carries' '1' \
    "$(sed -n '/^install_redirect_libraries()/,/^}/p' "$REPO/module/customize.sh" \
        | grep -c '\[ -e "\$redirect_replacement" \]')"
check 'install_redirect_libraries restages a replacement the installed module delivers' '1' \
    "$(sed -n '/^install_redirect_libraries()/,/^}/p' "$REPO/module/customize.sh" \
        | grep -c '\[ ! -e "/data/adb/modules/noemulator\$redirect_replacement" \]')"

check_invariant 4 'post-mount refuses a replacement whose label differs from the target' '1' \
    "$(grep -c 'noemulator_labels_match "$redirect_target" "$redirect_replacement"' "$REPO/module/post-mount.sh")"

# busybox stat has no %C and prints the literal letter C. Every stat in the
# module must name toybox explicitly; one that does not is the v0.4.0 boot loop.
for stat_user in customize.sh post-fs-data.sh post-mount.sh; do
    check_invariant 4 "$stat_user calls stat only through the toybox path" '0' \
        "$(grep 'stat -c' "$REPO/module/$stat_user" | grep -vc 'NOEMULATOR_STAT')"
done

# Regression guard, v0.4.4 (2026-10-17): ro.boot.qemu.virtiowifi was deleted at
# post-fs-data, ~5s, and the Wi-Fi HAL reads it at 8.5s. The AVD came up with no
# wlan0 at all, and vdinfos' net:nettype_consistency went MATCH -> MISMATCH --
# the only verdict NoEmulator made worse. Both ends of the new stage split are
# asserted, and so is the shipped config, because a rule that drifts back into
# the post-fs-data block breaks Wi-Fi silently.
check_invariant 12 'delprop_after_wifi emits the applier call, not a resetprop' \
    "noemulator_delprop_after_wifi 'ro.boot.qemu.virtiowifi'" \
    "$(sh "$GENERATE" "$(config_with 'delprop_after_wifi ro.boot.qemu.virtiowifi')")"

check 'the shipped config deletes the wifi property late' '1' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | grep -c "^noemulator_delprop_after_wifi 'ro.boot.qemu.virtiowifi'")"

check_invariant 12 'the shipped config never deletes the wifi property early' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" \
        | grep -c '^/data/adb/ksu/bin/resetprop -d ro.boot.qemu.virtiowifi$')"

check_invariant 12 'post-fs-data applies no delprop_after_wifi rule' '1' \
    "$(grep -c -- "-e '\^noemulator_delprop_after_wifi '" "$REPO/module/post-fs-data.sh")"

check 'post-mount.sh is what applies the delprop_after_wifi rules' '1' \
    "$(grep -c "grep '\^noemulator_delprop_after_wifi '" "$REPO/module/post-mount.sh")"

# The waiter sleeps for as long as 30 seconds. Running it in the boot path would
# hold post-mount open for that whole time on an image with no emulated Wi-Fi.
check 'the late deletions run in the background' '1' \
    "$(grep -c '^noemulator_late_deletions &$' "$REPO/module/post-mount.sh")"

# A deleted property leaves its name in the raw area for an enumerating reader.
# post-fs-data rebuilds the areas after its own deletions; these happen later.
check 'the wifi waiter rebuilds the property areas after deleting' '1' \
    "$(grep -c -- '-c --force' "$REPO/module/lib/delete_after_wifi.sh")"

check 'delprop_after_wifi rejects a name that is not a property' '1' \
    "$(sh "$GENERATE" "$(config_with 'delprop_after_wifi ro.boot qemu')" >/dev/null 2>&1; echo $?)"

# The deletions need neither susfs node. customize.sh accepts an install on
# /proc/susfs_path alone, so a kernel with SUS_PATH and no OPEN_REDIRECT reaches
# post-mount; if the waiter were launched after the open-redirect guard, that
# kernel would take the early exit and keep ro.boot.qemu.virtiowifi for the whole
# session while every other delprop still ran (issue #14).
after_wifi_line="$(grep -n '^noemulator_late_deletions &$' \
    "$REPO/module/post-mount.sh" | cut -d: -f1)"
redirect_guard_line="$(grep -n '\[ ! -e "\$SUSFS_REDIRECT_NODE" \]' \
    "$REPO/module/post-mount.sh" | cut -d: -f1)"

check 'the late deletions are launched before the open-redirect guard' 'before' \
    "$([ "$after_wifi_line" -lt "$redirect_guard_line" ] && echo before || echo after)"

check 'the open-redirect guard still gates the redirects' 'gated' \
    "$(redirect_line="$(grep -n "grep '\^noemulator_redirect '" "$REPO/module/post-mount.sh" \
        | cut -d: -f1)"
       [ "$redirect_guard_line" -lt "$redirect_line" ] && echo gated || echo ungated)"

# --- delprop_once_set -------------------------------------------------------
# The vendor.qemu.* properties are written by qemu-props at 5.35s, after
# post-fs-data, so a plain delprop there deletes nothing (issue #33).
check 'delprop_once_set emits the applier call, not a resetprop' \
    "noemulator_delprop_once_set 'vendor.qemu.timezone'" \
    "$(sh "$GENERATE" "$(config_with 'delprop_once_set vendor.qemu.timezone')")"

check 'delprop_once_set rejects a name that is not a property' '1' \
    "$(sh "$GENERATE" "$(config_with 'delprop_once_set vendor.qemu;id')" >/dev/null 2>&1; echo $?)"

check 'post-fs-data applies no delprop_once_set rule' '1' \
    "$(grep -c -- "-e '\^noemulator_delprop_once_set '" "$REPO/module/post-fs-data.sh")"

check 'post-mount.sh is what applies the delprop_once_set rules' '1' \
    "$(grep -c "grep '\^noemulator_delprop_once_set '" "$REPO/module/post-mount.sh")"

check 'the shipped config deletes four vendor.qemu properties once set' \
    "noemulator_delprop_once_set 'vendor.qemu.timezone'
noemulator_delprop_once_set 'vendor.qemu.vport.bluetooth'
noemulator_delprop_once_set 'vendor.qemu.vport.uwb'
noemulator_delprop_once_set 'vendor.qemu.sf.fake_camera'" \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep '^noemulator_delprop_once_set ')"

# The radio HAL reads the modem port at every start and does not stay up without
# it, so deleting it is opt-in, never shipped on.
check 'the shipped config leaves the modem property alone' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" | grep -c 'vendor.qemu.vport.modem')"

# The waiter, run for real against stubs: getprop answers from one file per
# property, resetprop logs its arguments.
ONCE_BIN="$WORK/once-bin"
mkdir -p "$ONCE_BIN"
printf '#!/bin/sh\ncat "$ONCE_PROPS/$1" 2>/dev/null\n' > "$ONCE_BIN/getprop"
printf '#!/bin/sh\necho "$*" >> "$ONCE_PROPS/../calls"\n' > "$ONCE_BIN/resetprop"
chmod +x "$ONCE_BIN/getprop" "$ONCE_BIN/resetprop"

# run_once_set <property set, or -> prints the resetprop calls and whether the
# rules file survived.
run_once_set() {
    rm -rf "$WORK/once"
    mkdir -p "$WORK/once/props"
    [ "$1" = '-' ] || printf '/dev/vport8p3\n' > "$WORK/once/props/vendor.qemu.vport.bluetooth"
    echo "noemulator_delprop_once_set 'vendor.qemu.vport.bluetooth'" > "$WORK/once/rules"
    PATH="$ONCE_BIN:$PATH" ONCE_PROPS="$WORK/once/props" \
        NOEMULATOR_ONCE_SET_RESETPROP="$ONCE_BIN/resetprop" \
        NOEMULATOR_ONCE_SET_TIMEOUT=1 NOEMULATOR_ONCE_SET_SETTLE=0 \
        sh -c ". '$REPO/module/lib/delete_once_set.sh'; noemulator_delete_once_set '$WORK/once/rules'" \
        | grep -v '^delprop_once_set done'
    echo "calls=$(tr '\n' ';' < "$WORK/once/calls")"
    [ -e "$WORK/once/rules" ] && echo 'left rules'
    return 0
}

check 'once_set: a set property is deleted, then the areas are rebuilt' \
    'calls=-d vendor.qemu.vport.bluetooth;-c --force;' \
    "$(run_once_set set)"

check 'once_set: a property never set is reported, and the rest still runs' \
    'delprop_once_set: vendor.qemu.vport.bluetooth never set within 1s
calls=-d vendor.qemu.vport.bluetooth;-c --force;' \
    "$(run_once_set -)"

# The NoMount check reports; it must never refuse the install. NoEmulator's rules do
# not depend on how the module's files are delivered, only the mount artifact does.
nomount_check="$(grep -A8 'modules/nomount' "$REPO/module/customize.sh")"

check 'the installer looks for NoMount in the modules path' '1' \
    "$(grep -c '\[ -d /data/adb/modules/nomount \]' "$REPO/module/customize.sh")"

check 'a disabled NoMount does not pass the check' '1' \
    "$(grep -c '\[ ! -f /data/adb/modules/nomount/disable \]' "$REPO/module/customize.sh")"

check 'a missing NoMount warns and does not abort the install' '0' \
    "$(printf '%s\n' "$nomount_check" | grep -c 'abort_with')"

# The ANGLE selection is two parallel settings keys, and the module is one of
# several writers. v0.4.6 wrote the package list straight, which replaced the whole
# thing: a package the user had put on ANGLE was dropped for as long as NoEmulator
# was installed, and ours were left on it forever after removal (issue #25). The
# list surgery is exercised here against a stub `settings`, because the real one
# needs a booted framework.
angle_lib_harness() {
    cat <<'HARNESS'
STORE_P=""; STORE_V=""; WRITES=0
settings() {
    case "$1 $2" in
      "get global") case "$3" in
            angle_gl_driver_selection_pkgs)   [ -n "$STORE_P" ] && echo "$STORE_P" || echo null ;;
            angle_gl_driver_selection_values) [ -n "$STORE_V" ] && echo "$STORE_V" || echo null ;;
          esac ;;
      "put global") WRITES=$((WRITES+1)); case "$3" in
            angle_gl_driver_selection_pkgs)   STORE_P="$4" ;;
            angle_gl_driver_selection_values) STORE_V="$4" ;;
          esac ;;
      "delete global") WRITES=$((WRITES+1)); case "$3" in
            angle_gl_driver_selection_pkgs)   STORE_P="" ;;
            angle_gl_driver_selection_values) STORE_V="" ;;
          esac ;;
    esac
}
HARNESS
    echo ". $REPO/module/lib/angle_settings.sh"
    cat
}

angle_run() { angle_lib_harness | sh; }

check 'angle: adding to a device with no selection sets both keys' 'com.ours|angle' \
    "$(angle_run <<'T'
noemulator_angle_add "com.ours"
echo "$STORE_P|$STORE_V"
T
)"

check 'angle: a package already listed is not added twice' '0' \
    "$(angle_run <<'T'
noemulator_angle_add "com.ours"
WRITES=0
noemulator_angle_add "com.ours"
echo "$WRITES"
T
)"

check "angle: a package we never named survives our add, with its own value" \
    'com.theirs,com.ours|native,angle' \
    "$(angle_run <<'T'
STORE_P="com.theirs"; STORE_V="native"
noemulator_angle_add "com.ours"
echo "$STORE_P|$STORE_V"
T
)"

check "angle: removing ours leaves theirs untouched" 'com.theirs|native' \
    "$(angle_run <<'T'
STORE_P="com.theirs,com.ours"; STORE_V="native,angle"
noemulator_angle_remove "com.ours"
echo "$STORE_P|$STORE_V"
T
)"

check 'angle: removing the last entry clears both keys' '|' \
    "$(angle_run <<'T'
STORE_P="com.ours"; STORE_V="angle"
noemulator_angle_remove "com.ours"
echo "$STORE_P|$STORE_V"
T
)"

check 'angle: the two lists stay the same length' 'same' \
    "$(angle_run <<'T'
STORE_P="com.a,com.theirs,com.b"; STORE_V="angle,default,angle"
noemulator_angle_remove "com.a,com.b"
p=$(echo "$STORE_P" | tr ',' '\n' | grep -c .)
v=$(echo "$STORE_V" | tr ',' '\n' | grep -c .)
[ "$p" = "$v" ] && echo same || echo "p=$p v=$v"
T
)"

check 'angle: a package whose name extends ours is not removed with it' 'com.ours.extra' \
    "$(angle_run <<'T'
STORE_P="com.ours.extra,com.ours"; STORE_V="angle,angle"
noemulator_angle_remove "com.ours"
echo "$STORE_P"
T
)"

check 'angle: removing a package that is not listed writes nothing' '0' \
    "$(angle_run <<'T'
STORE_P="com.theirs"; STORE_V="default"; WRITES=0
noemulator_angle_remove "com.absent"
echo "$WRITES"
T
)"

# service.sh must go through the library rather than writing the key itself, or the
# clobber comes back the next time someone edits it.
check 'service.sh adds through the library and writes no package key directly' '0' \
    "$(grep -c 'settings put global angle_gl_driver_selection' "$REPO/module/service.sh")"

check 'service.sh calls the library add' '1' \
    "$(grep -c 'noemulator_angle_add' "$REPO/module/service.sh")"

# The setting record and apply rule, against a stub `settings` whose rows live in
# files: one file per row value, one per stored default, and a log of every put.
# A row file holding FAIL makes the read print an error and exit non-zero; an
# empty one makes it exit 0 having printed nothing. A 'failput' file makes every put
# report failure after it has landed, the case that decides the write order.
setting_lib_harness() {
    rm -rf "$WORK/setting"
    mkdir -p "$WORK/setting/rows"
    cat <<HARNESS
ROWS="$WORK/setting/rows"
NOEMULATOR_SETTING_RECORD_DIR="$WORK/setting/record"
HARNESS
    cat <<'HARNESS'
settings() {
    case "$1" in
        get)
            [ -f "$ROWS/$2.$3" ] || { echo null; return 0; }
            [ "$(cat "$ROWS/$2.$3")" = FAIL ] && { echo 'Failure calling service settings'; return 1; }
            cat "$ROWS/$2.$3" ;;
        put)
            echo "$*" >> "$ROWS/../puts"
            printf '%s\n' "$4" > "$ROWS/$2.$3"
            [ "${5:-}" = default ] && printf '%s\n' "$4" > "$ROWS/$2.$3.default"
            [ -f "$ROWS/../failput" ] && return 2
            return 0 ;;
    esac
}
row() { printf '%s\n' "$3" > "$ROWS/$1.$2"; }
record() { mkdir -p "$NOEMULATOR_SETTING_RECORD_DIR"; printf 'original=%s\nwritten=%s\n' "$3" "$4" > "$NOEMULATOR_SETTING_RECORD_DIR/$1.$2"; }
show() {
    echo "row=$(cat "$ROWS/$1.$2" 2>/dev/null) default=$(cat "$ROWS/$1.$2.default" 2>/dev/null)"
    echo "record=$(cat "$NOEMULATOR_SETTING_RECORD_DIR/$1.$2" 2>/dev/null | tr '\n' ' ')"
    echo "puts=$(grep -c . "$ROWS/../puts" 2>/dev/null || echo 0)"
}
HARNESS
    echo ". $REPO/module/lib/setting_record.sh"
    cat
}

setting_run() { setting_lib_harness | sh; }

check 'setting: first apply records the original and writes value and default' \
    'setting global device_name: written
row=Pixel 8 default=Pixel 8
record=original=sdk_gphone64_x86_64 written=Pixel 8 
puts=1' \
    "$(setting_run <<'T'
row global device_name sdk_gphone64_x86_64
noemulator_setting global device_name 'Pixel 8'
show global device_name
T
)"

check 'setting: a row still holding what we wrote is not written again' \
    'setting global device_name: already ours
puts=0' \
    "$(setting_run <<'T'
row global device_name 'Pixel 8'; record global device_name sdk_gphone64_x86_64 'Pixel 8'
noemulator_setting global device_name 'Pixel 8'
show global device_name | tail -n 1
T
)"

# A release that moves the model must move the name too, not leave the old one
# logged as the user's (finding 1).
check 'setting: a configured value changed since the last write is written' \
    'row=Pixel 9 default=Pixel 9
record=original=sdk_gphone64_x86_64 written=Pixel 9 ' \
    "$(setting_run <<'T'
row global device_name 'Pixel 8'; record global device_name sdk_gphone64_x86_64 'Pixel 8'
noemulator_setting global device_name 'Pixel 9' >/dev/null
show global device_name | head -n 2
T
)"

check "setting: a name the user chose is left, and logged as theirs" \
    "setting global device_name: left as the user's
row=My phone default=
record=original=sdk_gphone64_x86_64 written=Pixel 8 
puts=0" \
    "$(setting_run <<'T'
row global device_name 'My phone'; record global device_name sdk_gphone64_x86_64 'Pixel 8'
noemulator_setting global device_name 'Pixel 8'
show global device_name
T
)"

# A settings reset, or a rename back, puts the original back; the module owns the
# row again (finding 8).
check 'setting: a row back at its original is written again' \
    'row=Pixel 8 default=Pixel 8
record=original=sdk_gphone64_x86_64 written=Pixel 8 ' \
    "$(setting_run <<'T'
row global device_name sdk_gphone64_x86_64; record global device_name sdk_gphone64_x86_64 'Pixel 8'
noemulator_setting global device_name 'Pixel 8' >/dev/null
show global device_name | head -n 2
T
)"

check 'setting: a row already at the value on first apply is recorded, not written' \
    'setting global device_name: already the configured value
record=original=Pixel 8 written=Pixel 8 
puts=0' \
    "$(setting_run <<'T'
row global device_name 'Pixel 8'
noemulator_setting global device_name 'Pixel 8'
show global device_name | tail -n 2
T
)"

# A failed read taken for the original would have uninstall erase the row
# (finding 3).
check 'setting: a failed read records nothing and writes nothing' \
    'setting global device_name: could not read; retried next boot
record=
puts=0' \
    "$(setting_run <<'T'
row global device_name FAIL
noemulator_setting global device_name 'Pixel 8'
show global device_name | tail -n 2
T
)"

check 'setting: a read that prints nothing records nothing and writes nothing' \
    'record=
puts=0' \
    "$(setting_run <<'T'
: > "$ROWS/global.device_name"
noemulator_setting global device_name 'Pixel 8' >/dev/null
show global device_name | tail -n 2
T
)"

check 'setting: an unset row is recorded as null, the word for unset' \
    'record=original=null written=Pixel 8 ' \
    "$(setting_run <<'T'
noemulator_setting secure device_name 'Pixel 8' >/dev/null
show secure device_name | sed -n 2p
T
)"

check 'setting: a system row is written without the default form' \
    'put system font_scale 1.1' \
    "$(setting_run <<'T'
row system font_scale 1.0
noemulator_setting system font_scale 1.1 >/dev/null
cat "$ROWS/../puts"
T
)"

# The record is saved before the write. Saved after, a write that lands but
# reports failure leaves no record, and the next boot takes the configured value
# for the original: uninstall would then have nothing to put back.
check 'setting: a write that lands but reports failure keeps the original' \
    'setting global device_name: could not write; retried next boot
setting global device_name: already ours
record=original=sdk_gphone64_x86_64 written=Pixel 8 ' \
    "$(setting_run <<'T'
row global device_name sdk_gphone64_x86_64
touch "$ROWS/../failput"
noemulator_setting global device_name 'Pixel 8'
rm "$ROWS/../failput"
noemulator_setting global device_name 'Pixel 8'
show global device_name | sed -n 2p
T
)"

# The staged restorer, run for real as its own process, the way the service.d
# hook runs it. `settings` and `getprop` are executables on PATH; the settings
# stub keeps each row and its default in files and logs every put and delete.
RESTORE_BIN="$WORK/restore-bin"
mkdir -p "$RESTORE_BIN"
cat > "$RESTORE_BIN/settings" <<'STUB'
#!/bin/sh
row="$RESTORE_ROWS/$2.$3"
case "$1" in
    get)
        [ -f "$row" ] || { echo null; exit 0; }
        [ "$(cat "$row")" = FAIL ] && exit 1
        cat "$row" ;;
    put)
        echo "$*" >> "$RESTORE_ROWS/../calls"
        printf '%s\n' "$4" > "$row"
        [ "${5:-}" = default ] && printf '%s\n' "$4" > "$row.default"
        exit 0 ;;
    delete)
        echo "$*" >> "$RESTORE_ROWS/../calls"
        rm -f "$row" ;;
esac
STUB
printf '#!/bin/sh\necho 1\n' > "$RESTORE_BIN/getprop"
chmod +x "$RESTORE_BIN/settings" "$RESTORE_BIN/getprop"

# restore_fixture <namespace.key> <current row value> <record contents>
restore_fixture() {
    rm -rf "$WORK/restore"
    mkdir -p "$WORK/restore/rows" "$WORK/restore/staged" "$WORK/restore/record" "$WORK/restore/service.d"
    cp "$REPO/module/lib/setting_record.sh" "$REPO/module/lib/setting_restore.sh" "$WORK/restore/staged/"
    : > "$WORK/restore/service.d/hook.sh"
    [ "$2" = '-' ] || printf '%s\n' "$2" > "$WORK/restore/rows/$1"
    printf '%s\n' "$3" > "$WORK/restore/record/$1"
}

# Prints what is left: the row, the settings calls made, and which staged pieces
# survived the run.
run_restorer() {
    PATH="$RESTORE_BIN:$PATH" RESTORE_ROWS="$WORK/restore/rows" \
        NOEMULATOR_SETTING_RECORD_DIR="$WORK/restore/record" \
        NOEMULATOR_SETTING_RESTORE_HOOK="$WORK/restore/service.d/hook.sh" \
        NOEMULATOR_SETTING_RESTORE_LOCK="$WORK/restore/lock" \
        sh "$WORK/restore/staged/setting_restore.sh"
    echo "row=$(cat "$WORK/restore/rows/$1" 2>/dev/null)"
    echo "calls=$(cat "$WORK/restore/calls" 2>/dev/null | tr '\n' ';')"
    for left in staged record service.d/hook.sh lock; do
        [ -e "$WORK/restore/$left" ] && echo "left $left"
    done
    return 0
}

check 'restorer: a row still ours goes back to its original and everything is removed' \
    'row=sdk_gphone64_x86_64
calls=put global device_name sdk_gphone64_x86_64 default;' \
    "$(restore_fixture global.device_name 'Pixel 8' 'original=sdk_gphone64_x86_64
written=Pixel 8'; run_restorer global.device_name)"

# A rename made after install is the user's choice, and removing the module must
# not undo it (finding 6). It still counts as done, or the hook would run forever.
check "restorer: a row the user renamed is left, and everything is still removed" \
    'row=My phone
calls=' \
    "$(restore_fixture global.device_name 'My phone' 'original=sdk_gphone64_x86_64
written=Pixel 8'; run_restorer global.device_name)"

check 'restorer: an unset original is deleted, never written as null' \
    'row=
calls=delete secure device_name;' \
    "$(restore_fixture secure.device_name 'Pixel 8' 'original=null
written=Pixel 8'; run_restorer secure.device_name)"

check 'restorer: a system row is written back without the default form' \
    'row=1.0
calls=put system font_scale 1.0;' \
    "$(restore_fixture system.font_scale '1.1' 'original=1.0
written=1.1'; run_restorer system.font_scale)"

# Writing back a value that was never changed would only move the row's owner
# from android to root.
check 'restorer: a row recorded as never written gets no write' \
    'row=Pixel 8
calls=' \
    "$(restore_fixture global.device_name 'Pixel 8' 'original=Pixel 8
written=Pixel 8'; run_restorer global.device_name)"

check 'restorer: a failed read keeps everything staged for the next boot' \
    'row=FAIL
calls=
left staged
left record
left service.d/hook.sh' \
    "$(restore_fixture global.device_name FAIL 'original=sdk_gphone64_x86_64
written=Pixel 8'; run_restorer global.device_name)"

# The other copy holds the lock, so this one must do nothing at all -- not even
# wait for boot (finding 12).
check 'restorer: a held lock means this copy touches nothing' \
    'row=Pixel 8
calls=
left staged
left record
left service.d/hook.sh
left lock' \
    "$(restore_fixture global.device_name 'Pixel 8' 'original=sdk_gphone64_x86_64
written=Pixel 8'; mkdir "$WORK/restore/lock"; run_restorer global.device_name)"

check 'restorer: the lock is taken before the wait for boot' 'before' \
    "$(lock_line="$(grep -n 'mkdir "$NOEMULATOR_SETTING_RESTORE_LOCK"' "$REPO/module/lib/setting_restore.sh" | cut -d: -f1)"
       wait_line="$(grep -n 'if ! noemulator_setting_restore_wait' "$REPO/module/lib/setting_restore.sh" | cut -d: -f1)"
       [ -n "$lock_line" ] && [ "$lock_line" -lt "$wait_line" ] && echo before || echo after)"

# A key a release stops setting is undone at the next boot rather than stranded
# (finding 5); a key the config still sets is not touched.
check 'setting: a recorded key the config no longer sets is restored at apply' \
    'setting global old_name: restored
row=sdk default=sdk
record=
row=Pixel 8 default=
record=original=sdk_gphone64_x86_64 written=Pixel 8 ' \
    "$(setting_run <<'T'
row global old_name 'Pixel 8'; record global old_name sdk 'Pixel 8'
row global device_name 'Pixel 8'; record global device_name sdk_gphone64_x86_64 'Pixel 8'
noemulator_setting_restore_unconfigured "$(noemulator_setting_ids "noemulator_setting 'global' 'device_name' 'Pixel 8'")"
show global old_name | head -n 2
show global device_name | head -n 2
T
)"

check 'setting: restoring the last record removes the record directory' 'gone' \
    "$(setting_run <<'T'
row global old_name 'Pixel 8'; record global old_name sdk 'Pixel 8'
noemulator_setting_restore_unconfigured "" >/dev/null
[ -d "$NOEMULATOR_SETTING_RECORD_DIR" ] && echo kept || echo gone
T
)"

check 'setting: the configured ids are namespace.key, keys with dots kept whole' \
    'global.device_name
system.a.b' \
    "$(setting_run <<'T'
noemulator_setting_ids "noemulator_angle 'com.a'
noemulator_setting 'global' 'device_name' 'Pixel 8'
noemulator_setting 'system' 'a.b' 'x y'"
T
)"

# A restore pending from an uninstall that was reinstalled over must not run: the
# module owns the rows again (finding 7).
check 'service.sh cancels a pending setting restore before applying' 'before' \
    "$(cancel_line="$(grep -n 'rm -f /data/adb/service.d/noemulator-setting-restore.sh' "$REPO/module/service.sh" | cut -d: -f1)"
       apply_line="$(grep -n "grep '\^noemulator_setting '" "$REPO/module/service.sh" | cut -d: -f1)"
       [ -n "$cancel_line" ] && [ "$cancel_line" -lt "$apply_line" ] && echo before || echo after)"

check 'service.sh cancels the staged restore directory as well as its hook' '1' \
    "$(grep -c 'rm -rf /data/adb/noemulator-setting-restore$' "$REPO/module/service.sh")"

# uninstall.sh runs at ~6.8s with no system_server, so it must not call settings
# itself; its whole job is to stage the cleanup that can.
check 'uninstall.sh calls settings nowhere' '0' \
    "$(grep -c '^[[:space:]]*settings[[:space:]]' "$REPO/module/uninstall.sh")"

# uninstall.sh is run here for real, against a scratch MODDIR and scratch cleanup
# paths. The `sh` it finds on PATH runs everything except the staged cleanup,
# which it only records: started for real, the cleanup would race this check and
# delete what it is meant to observe.
uninstall_bin="$WORK/uninstall-bin"
mkdir -p "$uninstall_bin"
real_sh="$(command -v sh)"
cat > "$uninstall_bin/sh" <<STUB
#!$real_sh
case "\$1" in
    *angle_cleanup.sh|*setting_restore.sh) exit 0 ;;
    *) exec $real_sh "\$@" ;;
esac
STUB
chmod +x "$uninstall_bin/sh"

# run_uninstall <artifacts.conf contents> [setting record contents]
#               [user config contents]; prints what was left staged, and the exit
# status if it was not 0.
run_uninstall() {
    rm -rf "$WORK/uninstall"
    mkdir -p "$WORK/uninstall/module/lib"
    cp "$REPO/module/uninstall.sh" "$WORK/uninstall/module/"
    cp "$REPO/module/lib/generate_rules.sh" "$REPO/module/lib/angle_settings.sh" \
        "$REPO/module/lib/angle_cleanup.sh" "$REPO/module/lib/setting_record.sh" \
        "$REPO/module/lib/setting_restore.sh" "$REPO/module/lib/user_config.sh" \
        "$WORK/uninstall/module/lib/"
    printf '%s\n' "$1" > "$WORK/uninstall/module/artifacts.conf"
    if [ -n "${3:-}" ]; then
        mkdir -p "$WORK/uninstall/adb"
        printf '%s\n' "$3" > "$WORK/uninstall/adb/noemulator-user.conf"
    fi
    if [ -n "${2:-}" ]; then
        mkdir -p "$WORK/uninstall/adb/noemulator-settings"
        printf '%s\n' "$2" > "$WORK/uninstall/adb/noemulator-settings/global.device_name"
    fi
    PATH="$uninstall_bin:$PATH" \
        NOEMULATOR_SETTING_RECORD_DIR="$WORK/uninstall/adb/noemulator-settings" \
        NOEMULATOR_RESTORE_DIR="$WORK/uninstall/adb/noemulator-setting-restore" \
        NOEMULATOR_RESTORE_HOOK="$WORK/uninstall/adb/service.d/noemulator-setting-restore.sh" \
        NOEMULATOR_CLEANUP_DIR="$WORK/uninstall/adb/noemulator-angle-cleanup" \
        NOEMULATOR_CLEANUP_HOOK="$WORK/uninstall/adb/service.d/noemulator-angle-cleanup.sh" \
        NOEMULATOR_USER_CONFIG="$WORK/uninstall/adb/noemulator-user.conf" \
        "$real_sh" "$WORK/uninstall/module/uninstall.sh" || echo "exit=$?"
    [ -f "$WORK/uninstall/adb/noemulator-angle-cleanup/packages" ] &&
        echo "packages=$(cat "$WORK/uninstall/adb/noemulator-angle-cleanup/packages")"
    [ -f "$WORK/uninstall/adb/service.d/noemulator-angle-cleanup.sh" ] && echo hook
    [ -f "$WORK/uninstall/adb/noemulator-setting-restore/setting_restore.sh" ] && echo restore
    [ -f "$WORK/uninstall/adb/service.d/noemulator-setting-restore.sh" ] && echo restore-hook
    [ -f "$WORK/uninstall/adb/noemulator-user.conf" ] && echo user-config
    return 0
}

# The shipped config names no package, so an uninstall must stage nothing at all.
check 'uninstall stages no angle cleanup when no package is named' '' \
    "$(run_uninstall 'delprop ro.boot.qemu')"

check 'uninstall stages the angle cleanup and its hook for a named package' \
    'packages=com.example.a,com.example.b
hook' \
    "$(run_uninstall 'angle com.example.a
angle com.example.b')"

# The packages a user put on ANGLE are theirs to take back off, wherever the line
# lives (#59, story 18).
check 'uninstall stages the angle packages named in the user config too' \
    'packages=com.example.a,com.example.b
hook' \
    "$(run_uninstall 'angle com.example.a' '' 'angle com.example.b')"

# Removal means removal: nothing NoEmulator wrote under /data/adb/ stays behind,
# and a reinstall starts from the defaults (#59, Q8).
check 'uninstall removes the user config' 'absent' \
    "$(run_uninstall 'delprop ro.boot.qemu' '' 'delprop_once_set vendor.qemu.vport.modem' >/dev/null
       [ -e "$WORK/uninstall/adb/noemulator-user.conf" ] && echo present || echo absent)"

# A config that no longer parses is not a reason to strand the removal.
check 'uninstall with an invalid config stages nothing and still exits 0' '' \
    "$(run_uninstall 'frobnicate /dev/x')"

# A record means this module wrote a settings row, and the restore is staged from
# it whatever the config says: with no angle package (what ships), and with a
# config that no longer parses (finding 2, finding 5).
check 'uninstall stages the setting restore and its hook when a record exists' \
    'restore
restore-hook' \
    "$(run_uninstall 'delprop ro.boot.qemu' 'original=sdk_gphone64_x86_64
written=Pixel 8')"

check 'uninstall stages the setting restore even with an invalid config' \
    'restore
restore-hook' \
    "$(run_uninstall 'frobnicate /dev/x' 'original=sdk_gphone64_x86_64
written=Pixel 8')"

check 'uninstall stages the setting restore before the angle cleanup' 'before' \
    "$(restore_line="$(grep -n '^noemulator_stage_setting_restore$' "$REPO/module/uninstall.sh" | cut -d: -f1)"
       angle_line="$(grep -n '^noemulator_stage_angle_cleanup$' "$REPO/module/uninstall.sh" | cut -d: -f1)"
       [ -n "$restore_line" ] && [ "$restore_line" -lt "$angle_line" ] && echo before || echo after)"

# The cleanup deletes the hook as well as its own directory, or an uninstalled
# module leaves a script running on every boot forever.
check 'the cleanup removes its boot hook, not just its directory' '1' \
    "$(grep -c 'rm -f "\$NOEMULATOR_ANGLE_CLEANUP_HOOK"' "$REPO/module/lib/angle_cleanup.sh")"

check 'the cleanup waits for the framework before touching settings' '1' \
    "$(grep -c 'getprop sys.boot_completed' "$REPO/module/lib/angle_cleanup.sh")"

# The staged cleanup, run for real with the restorer's stubs. A lock left behind
# by a boot that died mid-wait must not stop a later boot (issue #47): v0.4.7 to
# v0.6.0 kept the lock as a 'running' directory inside the staged directory,
# which survives a reboot, so the leftover is planted there.
#
# run_angle_cleanup <setup command>; prints the package key and what survived.
run_angle_cleanup() {
    rm -rf "$WORK/angle-cleanup"
    mkdir -p "$WORK/angle-cleanup/rows" "$WORK/angle-cleanup/staged" "$WORK/angle-cleanup/service.d"
    cp "$REPO/module/lib/angle_settings.sh" "$REPO/module/lib/angle_cleanup.sh" "$WORK/angle-cleanup/staged/"
    echo com.ours > "$WORK/angle-cleanup/staged/packages"
    : > "$WORK/angle-cleanup/service.d/hook.sh"
    echo com.theirs,com.ours > "$WORK/angle-cleanup/rows/global.angle_gl_driver_selection_pkgs"
    echo native,angle > "$WORK/angle-cleanup/rows/global.angle_gl_driver_selection_values"
    eval "$1"
    PATH="$RESTORE_BIN:$PATH" RESTORE_ROWS="$WORK/angle-cleanup/rows" \
        NOEMULATOR_ANGLE_CLEANUP_HOOK="$WORK/angle-cleanup/service.d/hook.sh" \
        NOEMULATOR_ANGLE_CLEANUP_LOCK="$WORK/angle-cleanup/lock" \
        sh "$WORK/angle-cleanup/staged/angle_cleanup.sh"
    echo "pkgs=$(cat "$WORK/angle-cleanup/rows/global.angle_gl_driver_selection_pkgs")"
    for left in staged service.d/hook.sh lock; do
        [ -e "$WORK/angle-cleanup/$left" ] && echo "left $left"
    done
    return 0
}

check 'the cleanup runs despite a lock left inside its directory by an earlier boot' \
    'pkgs=com.theirs' \
    "$(run_angle_cleanup 'mkdir "$WORK/angle-cleanup/staged/running"')"

check 'the cleanup touches nothing while the other copy holds the lock' \
    'pkgs=com.theirs,com.ours
left staged
left service.d/hook.sh
left lock' \
    "$(run_angle_cleanup 'mkdir "$WORK/angle-cleanup/lock"')"

# --- the WebUI's shell half -------------------------------------------------
#
# lib/angle_webui.sh is what the page calls through ksu.exec. The page itself
# cannot be tested on a host, which is the reason every decision lives in the
# shell: what is installed, what is on ANGLE, which entries are ours, and how
# the config is edited.
#
# `settings` and `pm` are stubbed as real executables on PATH rather than as
# shell functions, because the helper runs as its own process and would not
# inherit a function. The settings stub keeps its two keys in files so writes
# survive across the separate invocations a round-trip needs.

WEBUI_BIN="$WORK/bin"
mkdir -p "$WEBUI_BIN"

cat > "$WEBUI_BIN/settings" <<'STUB'
#!/bin/sh
key_file() {
    case "$1" in
        angle_gl_driver_selection_pkgs)   echo "$WEBUI_STORE/pkgs" ;;
        angle_gl_driver_selection_values) echo "$WEBUI_STORE/values" ;;
    esac
}
case "$1 $2" in
    "get global")    f=$(key_file "$3"); [ -s "$f" ] && cat "$f" || echo null ;;
    "put global")    echo w >> "$WEBUI_STORE/writes"; printf '%s' "$4" > "$(key_file "$3")" ;;
    "delete global") echo w >> "$WEBUI_STORE/writes"; : > "$(key_file "$3")" ;;
esac
STUB

cat > "$WEBUI_BIN/pm" <<'STUB'
#!/bin/sh
# 'pm list packages [-3]'. The third-party list is the first two; the full list
# adds a system package, so --all can be told apart from the default.
echo "package:com.example.third"
echo "package:com.example.other"
[ "$3" = "-3" ] || echo "package:android"
STUB

chmod +x "$WEBUI_BIN/settings" "$WEBUI_BIN/pm"

# A config carrying every directive type, so the round-trip assertion below is
# about the real file shape rather than a stripped-down one.
webui_fixture() {
    cat > "$WORK/webui.conf" <<'CONF'
# A comment that carries the reason for the rule below it.
redirect /dev/goldfish_sync /dev/sync_fence0 2

    # An indented comment.
delprop ro.boot.qemu
delprop_after_wifi ro.boot.qemu.virtiowifi
setprop ro.product.model Pixel 8

# Trailing comment.
CONF
    rm -rf "$WORK/store"
    mkdir -p "$WORK/store"
}

# How many times the device was written. Adopt's contract is zero.
webui_writes() {
    [ -f "$WORK/store/writes" ] && wc -l < "$WORK/store/writes" | tr -d ' ' || echo 0
}

webui() {
    PATH="$WEBUI_BIN:$PATH" WEBUI_STORE="$WORK/store" \
        NOEMULATOR_USER_CONFIG="$WORK/webui.conf" \
        sh "$REPO/module/lib/angle_webui.sh" "$@"
}

webui_fixture
check 'webui: the third-party list excludes system packages' \
    'com.example.other
com.example.third' \
    "$(webui packages)"

check 'webui: --all includes them' \
    'android
com.example.other
com.example.third' \
    "$(webui packages --all)"

webui_fixture
check 'webui: a config naming no package has an empty selection' '' "$(webui selection)"

webui_fixture
webui add com.example.third >/dev/null
check 'webui: add names the package in the config' 'angle com.example.third' \
    "$(grep '^angle ' "$WORK/webui.conf")"

check 'webui: add puts the package on ANGLE now' 'com.example.third|angle' \
    "$(printf '%s|%s' "$(cat "$WORK/store/pkgs")" "$(cat "$WORK/store/values")")"

check 'webui: the added package reports as ours' 'com.example.third angle ours' \
    "$(webui selection)"

# The whole reason the page is not allowed to regenerate the file: artifacts.conf
# is mostly comments, and those comments carry the measurement behind every
# directive. An add followed by a remove must leave the file as it was found.
webui_fixture
cp "$WORK/webui.conf" "$WORK/webui.conf.before"
webui add com.example.third >/dev/null
webui remove com.example.third >/dev/null
check 'webui: add then remove round-trips the config byte for byte' '' \
    "$(diff "$WORK/webui.conf.before" "$WORK/webui.conf")"

check 'webui: remove takes the package back off ANGLE' '|' \
    "$(printf '%s|%s' "$(cat "$WORK/store/pkgs")" "$(cat "$WORK/store/values")")"

# A package the user put on ANGLE themselves is reported, so the page can show
# it, and marked theirs, so the page will not offer to remove it. Same rule
# uninstall follows (issue #25).
webui_fixture
printf 'com.theirs' > "$WORK/store/pkgs"
printf 'native' > "$WORK/store/values"
webui add com.example.third >/dev/null
check 'webui: a package set outside NoEmulator is reported as theirs' \
    'com.theirs native theirs
com.example.third angle ours' \
    "$(webui selection)"

webui remove com.example.third >/dev/null
check "webui: removing ours leaves theirs on ANGLE" 'com.theirs|native' \
    "$(printf '%s|%s' "$(cat "$WORK/store/pkgs")" "$(cat "$WORK/store/values")")"

# Adding twice must not write the line twice: the config is appended to, so a
# duplicate would survive every later read and show up as two rules.
webui_fixture
webui add com.example.third >/dev/null
webui add com.example.third >/dev/null
check 'webui: adding the same package twice writes one line' '1' \
    "$(grep -c '^angle com.example.third$' "$WORK/webui.conf")"

# The page passes the package name straight into a shell command. The charset
# check is the thing standing between a crafted name and that command, and it is
# asserted here rather than trusted because angle_webui.sh is the only writer of
# artifacts.conf that is not a human.
webui_fixture
for webui_bad_name in 'com.a;id' 'com.a $(id)' "com.a'id" 'com.a b'; do
    webui add "$webui_bad_name" >/dev/null 2>&1
    check "webui: add rejects '$webui_bad_name'" '1' "$?"
done

check 'webui: a rejected name writes nothing to the config' '0' \
    "$(grep -c '^angle ' "$WORK/webui.conf")"

check 'webui: a rejected name writes nothing to the settings' '' \
    "$(cat "$WORK/store/pkgs" 2>/dev/null)"

# Adopting takes over an entry somebody else put on ANGLE. It is the only way
# off the 'theirs' state from the phone, because the page refuses to edit an
# entry it does not own in either direction.
#
# The asymmetry with add is the whole point and is asserted here: add changes
# the device, adopt only changes who is responsible for it.
webui_fixture
printf 'com.theirs' > "$WORK/store/pkgs"
printf 'native' > "$WORK/store/values"
webui adopt com.theirs >/dev/null
check 'webui: adopt names the package in the config' 'angle com.theirs' \
    "$(grep '^angle ' "$WORK/webui.conf")"

# The device must not move. The package was already on ANGLE with its own value,
# and rewriting it to 'angle' would be this module changing a setting it was
# only asked to take responsibility for.
check 'webui: adopt leaves the live setting exactly as it was' 'com.theirs|native' \
    "$(printf '%s|%s' "$(cat "$WORK/store/pkgs")" "$(cat "$WORK/store/values")")"

check 'webui: adopt writes to the device not at all' '0' "$(webui_writes)"

check 'webui: an adopted package reports as ours, keeping its value' 'com.theirs native ours' \
    "$(webui selection)"

# Once adopted it is ours, so remove works on it -- which is the point of
# adopting, and also what makes uninstall take it off.
webui remove com.theirs >/dev/null
check 'webui: an adopted package can then be removed' '|' \
    "$(printf '%s|%s' "$(cat "$WORK/store/pkgs")" "$(cat "$WORK/store/values")")"

# Adopt is not add. A package that is not on ANGLE has nothing to adopt, and
# recording it would make the config describe a state the device is not in --
# which the next boot would then go and create.
webui_fixture
webui adopt com.example.third >/dev/null 2>&1
check 'webui: adopt refuses a package that is not on ANGLE' '1' "$?"

check 'webui: a refused adopt writes nothing to the config' '0' \
    "$(grep -c '^angle ' "$WORK/webui.conf")"

# Adopting twice must not write the line twice, for the same reason add must
# not: the config is appended to, so a duplicate would survive every later read.
webui_fixture
printf 'com.theirs' > "$WORK/store/pkgs"
printf 'native' > "$WORK/store/values"
webui adopt com.theirs >/dev/null
webui adopt com.theirs >/dev/null
check 'webui: adopting the same package twice writes one line' '1' \
    "$(grep -c '^angle com.theirs$' "$WORK/webui.conf")"

webui_fixture
printf 'com.a;id' > "$WORK/store/pkgs"
printf 'angle' > "$WORK/store/values"
webui adopt 'com.a;id' >/dev/null 2>&1
check 'webui: adopt rejects a crafted name even when it is on ANGLE' '1' "$?"

check 'webui: a refused adopt of a listed name writes nothing' '0' \
    "$(grep -c '^angle ' "$WORK/webui.conf")"

# The config and the live selection are separate state, so add must write the
# setting even when the config already names the package. A guard that returned
# early on the config line alone reported success while writing nothing, leaving
# an entry the page shows as Off that no tap could turn on until the next boot.
webui_fixture
webui add com.example.third >/dev/null
: > "$WORK/store/pkgs"
: > "$WORK/store/values"
webui add com.example.third >/dev/null
check 'webui: add writes the setting even when the config already names it' \
    'com.example.third|angle' \
    "$(cat "$WORK/store/pkgs")|$(cat "$WORK/store/values")"

check 'webui: that second add still leaves one config line' '1' \
    "$(grep -c '^angle com.example.third$' "$WORK/webui.conf")"

# A package name's dots are regex metacharacters. Matching the config with a
# grep pattern made `com.a.b` match a line reading `com.a_b`, and both names are
# legal, so add appended nothing and reported success.
webui_fixture
webui add com.example_third >/dev/null
webui add com.example.third >/dev/null
# -F, because this assertion is subject to the very bug it is checking: with a
# pattern, `.` matches the `_` and the count is 2 whichever way the helper went.
check 'webui: a name differing only by a dot is a different package to add' '1' \
    "$(grep -cxF 'angle com.example.third' "$WORK/webui.conf")"

webui_fixture
printf 'com.example.third' > "$WORK/store/pkgs"
printf 'native' > "$WORK/store/values"
webui add com.example_third >/dev/null
webui adopt com.example.third >/dev/null
check 'webui: a name differing only by a dot is a different package to adopt' '1' \
    "$(grep -cxF 'angle com.example.third' "$WORK/webui.conf")"

# The guard joins the config's names with newlines and matches one with a
# newline on each side. Both delimiters earn their place: without the trailing
# one a config naming com.example.third would swallow an add of com.example.thi,
# and without the leading one a config naming com.example.third would swallow an
# add of example.third. Same invariant angle_settings.sh holds for the live
# list, held here for the config.
webui_fixture
webui add com.example.third >/dev/null
webui add com.example.thi >/dev/null
check 'webui: a name another entry starts with is a different package' '1' \
    "$(grep -cxF 'angle com.example.thi' "$WORK/webui.conf")"

webui_fixture
webui add com.example.third >/dev/null
webui add example.third >/dev/null
check 'webui: a name another entry ends with is a different package' '1' \
    "$(grep -cxF 'angle example.third' "$WORK/webui.conf")"

# A config saved without a final newline is what hand-editing produces, and the
# shipped config's last line is a comment. Appending straight onto it would hide
# the directive inside that comment while the package went on ANGLE anyway.
webui_fixture
printf '# A last line with no newline after it.' >> "$WORK/webui.conf"
webui add com.example.third >/dev/null
check 'webui: add keeps the directive off the end of an unterminated last line' \
    'angle com.example.third' \
    "$(grep '^angle ' "$WORK/webui.conf")"

webui_fixture
printf 'com.theirs' > "$WORK/store/pkgs"
printf 'native' > "$WORK/store/values"
printf '# A last line with no newline after it.' >> "$WORK/webui.conf"
webui adopt com.theirs >/dev/null
check 'webui: adopt keeps the directive off the end of an unterminated last line' \
    'angle com.theirs' \
    "$(grep '^angle ' "$WORK/webui.conf")"

# An unknown command is a usage error, not a silent success, for the same reason
# an unknown directive fails generation loudly.
webui_fixture
webui nonsense >/dev/null 2>&1
check 'webui: an unknown command exits 2' '2' "$?"

# --- options_webui.sh -------------------------------------------------------
# The Home and Options pages' shell half (issue #55). Run as its own process
# against a fixture module directory.
options_fixture() {
    rm -rf "$WORK/opt"
    mkdir -p "$WORK/opt/module" "$WORK/opt/modules/nomount"
    printf 'id=noemulator\nversion=v9.9.9\n' > "$WORK/opt/module/module.prop"
    cp "$WORK/webui.conf" "$WORK/opt/user.conf"
    # Two boots. Only the second may be reported: the first finished every stage
    # and failed one rule, the second skipped a redirect and never ran once-set.
    cat > "$WORK/opt/module/apply.log" <<'LOG'
NoEmulator Sun Oct 18 09:00:00 EEST 2026
failed: resetprop -d ro.example
done
NoEmulator redirects Sun Oct 18 09:00:02 EEST 2026 uptime=7.5
redirect: /dev/a -> /dev/b (scheme 2)
redirects done
delprop_after_wifi done (wlan0 up) uptime=8.6
delprop_once_set done uptime=13.7
NoEmulator Mon Oct 19 10:00:00 EEST 2026
done
NoEmulator redirects Mon Oct 19 10:00:02 EEST 2026 uptime=7.6
redirect: /dev/a -> /dev/b (scheme 2)
redirect: /dev/c -> /dev/d (scheme 2)
redirect: no target /dev/e; skipped
redirects done
delprop_after_wifi done (wlan0 up) uptime=8.7
LOG
    : > "$WORK/opt/susfs_path"
    # What getprop answers, one file per property; no file is an unset property.
    # Empty: a booted device with the module's defaults, bridge deleted.
    mkdir -p "$WORK/opt/props"
}

OPT_BIN="$WORK/opt-bin"
mkdir -p "$OPT_BIN"
# With no argument getprop lists every property, read here from the file '_all'.
printf '#!/bin/sh\ncat "$OPT_PROPS/${1:-_all}" 2>/dev/null\n' > "$OPT_BIN/getprop"
chmod +x "$OPT_BIN/getprop"

# options_configured <switch>: the configured half of the switch state.
options_configured() {
    options "$1" | sed -n 's/^configured //p'
}

options() {
    PATH="$OPT_BIN:$PATH" OPT_PROPS="$WORK/opt/props" \
        NOEMULATOR_WEBUI_MODULE="$WORK/opt/module" \
        NOEMULATOR_WEBUI_MODULES_ROOT="$WORK/opt/modules" \
        NOEMULATOR_WEBUI_SUSFS_NODE="$WORK/opt/susfs_path" \
        NOEMULATOR_USER_CONFIG="$WORK/opt/user.conf" \
        sh "$REPO/module/lib/options_webui.sh" "$@"
}

webui_fixture
options_fixture
check 'options: status reports the last boot only, counting applied redirects alone' \
    'version v9.9.9
susfs yes
nomount yes
redirects 2
view_areas
stage post-fs-data done
stage post-mount done
stage after-wifi done
stage once-set missing
failures 0' \
    "$(options status)"

webui_fixture
options_fixture
touch "$WORK/opt/modules/nomount/disable"
rm "$WORK/opt/susfs_path"
check 'options: a disabled NoMount and an absent susfs node read as no' \
    'susfs no
nomount no' \
    "$(options status | grep -E '^(susfs|nomount) ')"

# The verdict both the Home card and the module card show (lib/module_status.sh).
webui_fixture
options_fixture
check 'options: health names each reason the last boot was not working' \
    'health warn
detail 1 stage(s) did not finish.' \
    "$(options health)"

echo 'delprop_once_set done uptime=13.8' >> "$WORK/opt/module/apply.log"
check 'options: health is ok once every stage ran, with no failed rule and susfs up' \
    'health ok
detail Every stage ran on the last boot, 2 redirects applied.' \
    "$(options health)"

echo 'failed: resetprop -d ro.other' >> "$WORK/opt/module/apply.log"
rm "$WORK/opt/susfs_path"
check 'options: health reports a missing susfs and a failed rule together' \
    'health warn
detail The susfs kernel module is not loaded.
detail 1 rule(s) failed.' \
    "$(options health)"

# The init service states' copy is first built by the service.sh refresh, not at
# post-mount (ADR 0032), so the refresh's line names that area. An area both
# stages name is listed once.
webui_fixture
options_fixture
cat >> "$WORK/opt/module/apply.log" <<'LOG'
app property view: init_service_status_private_prop: built once boot is up
app property view: build_prop: 4 key(s) hidden from apps
app property view: init_service_status_private_prop: copy refreshed
app property view: build_prop: copy refreshed
LOG
check 'options: status lists an area first built once boot is up, and each area once' \
    'view_areas build_prop init_service_status_private_prop' "$(options status | grep '^view_areas')"

# The app property view (#109): the areas it covers are counted from the last
# boot like redirects, and a failed area is named, not only counted.
webui_fixture
options_fixture
cat >> "$WORK/opt/module/apply.log" <<'LOG'
app property view: build_prop: 4 key(s) hidden from apps
app property view: dalvik_config_prop: 4 key(s) hidden from apps
delprop_once_set done uptime=13.8
LOG
check 'options: status lists the areas the app property view covers' \
    'view_areas build_prop dalvik_config_prop' "$(options status | grep '^view_areas')"
check 'options: health is ok with the view working and says which areas it covers' \
    'health ok
detail Every stage ran on the last boot, 2 redirects applied, app property view on build_prop dalvik_config_prop.' \
    "$(options health)"

echo 'failed: app property view: default_prop: open redirect refused' >> "$WORK/opt/module/apply.log"
check 'options: health names a failed app property view area' \
    'health warn
detail 1 rule(s) failed.
detail App property view: default_prop: open redirect refused.' \
    "$(options health)"

webui_fixture
options_fixture
echo 'failed: resetprop -d ro.other' >> "$WORK/opt/module/apply.log"
rm "$WORK/opt/susfs_path"
check 'options: failures lists the last boot failed lines only' \
    'failed: resetprop -d ro.other' "$(options failures)"

check 'options: log starts at the last boot header' \
    'NoEmulator Mon Oct 19 10:00:00 EEST 2026' "$(options log | head -n 1)"

options_fixture
check 'options: failures with none prints nothing and succeeds' 'exit=0 ' \
    "$(out=$(options failures); echo "exit=$? $out")"

# --- the log export (collect_logs.sh) --------------------------------------------

# The report goes to a public issue, so these must never reach it. The guid row is
# a regression: the first export on the reference AVD, 2026-10-20, carried the
# emulator serial inside persist.adb.wifi.guid.
options_fixture
printf '[vendor.qemu.timezone]: [Europe/Somewhere]\n[ro.boot.qemu.adb.pubkey]: [QAAAAKEY user@host]\n[ro.serialno]: [EMU123]\n[persist.adb.wifi.guid]: [adb-EMULATOR123-x]\n[ro.boot.qemu]: [1]\n' \
    > "$WORK/opt/props/_all"
printf 'setprop ro.serialno EMU123\nsetprop ro.product.model Pixel 6a\n' > "$WORK/opt/user.conf"
mkdir -p "$WORK/opt/out"
export_path=$(PATH="$OPT_BIN:$PATH" OPT_PROPS="$WORK/opt/props" \
    NOEMULATOR_LOGS_MODULE="$WORK/opt/module" \
    NOEMULATOR_LOGS_MODULES_ROOT="$WORK/opt/modules" \
    NOEMULATOR_LOGS_OUT_DIR="$WORK/opt/out" \
    NOEMULATOR_USER_CONFIG="$WORK/opt/user.conf" \
    sh "$REPO/module/lib/collect_logs.sh")
check 'export: no timezone, ADB key or serial value survives' '0' \
    "$(grep -c -e 'Somewhere' -e 'QAAAAKEY' -e 'EMU123' -e 'EMULATOR123' "$export_path")"
check 'export: the redacted names are still listed, and other values kept' \
    'setprop ro.serialno redacted
setprop ro.product.model Pixel 6a
[vendor.qemu.timezone]: [redacted]
[ro.boot.qemu.adb.pubkey]: [redacted]
[persist.adb.wifi.guid]: [redacted]
[ro.boot.qemu]: [1]' \
    "$(grep -e '^\[' -e '^setprop' "$export_path")"
check 'export: times are UTC, so no local zone name gives the location away' '1' \
    "$(grep -c '^NoEmulator log export, .* UTC ' "$export_path")"
check 'export: the report carries the last boot log' '1' \
    "$(grep -c '^failed: resetprop -d ro.example$' "$export_path")"

# The manager offers an update when update.json names a higher versionCode; a
# release that bumps one file and not the other offers the wrong thing.
check 'update.json names the version and versionCode module.prop has' 'match' \
    "$(prop_version=$(sed -n 's/^version=//p' "$REPO/module/module.prop")
       prop_code=$(sed -n 's/^versionCode=//p' "$REPO/module/module.prop")
       grep -q "\"version\": \"$prop_version\"" "$REPO/update.json" &&
       grep -q "\"versionCode\": $prop_code," "$REPO/update.json" &&
       grep -q "/download/$prop_version/noemulator-$prop_version.zip\"" "$REPO/update.json" && echo match)"

webui_fixture
options_fixture
options nonsense >/dev/null 2>&1
check 'options: an unknown command exits 2' '2' "$?"

# --- the ARM translation switch, and configured against running (issue #63) ----

webui_fixture
options_fixture
check 'options: arm is off by default, configured and running' \
    'configured off
running off' \
    "$(options arm)"

# The two halves differ right after a flip: that difference is what the page
# shows as "Reboot to apply".
options arm on
check 'options: arm on writes the directive and reads configured on, still running off' \
    'native_bridge keep
configured on
running off' \
    "$(grep -x 'native_bridge keep' "$WORK/opt/user.conf"; options arm)"

options arm on
check 'options: turning arm on twice writes one line' '1' \
    "$(grep -cx 'native_bridge keep' "$WORK/opt/user.conf")"

options arm off
check 'options: arm on then off round-trips the user config byte for byte' 'identical' \
    "$(cmp -s "$WORK/webui.conf" "$WORK/opt/user.conf" && echo identical)"

# Running is read from the live property, in the switch's own terms.
for running_case in 'arm|ro.dalvik.vm.native.bridge|libndk_translation.so|on' \
    'arm|ro.dalvik.vm.native.bridge|0|off' \
    'arm|ro.dalvik.vm.native.bridge||off' \
    'clipboard|ro.boot.qemu|1|on' \
    'clipboard|ro.boot.qemu|0|on' \
    'clipboard|ro.boot.qemu||off'; do
    IFS='|' read -r running_switch running_prop running_value running_expected <<CASE
$running_case
CASE
    options_fixture
    rm -f "$WORK/opt/props/$running_prop"
    [ -n "$running_value" ] && echo "$running_value" > "$WORK/opt/props/$running_prop"
    check "options: $running_switch reads running $running_expected with $running_prop='$running_value'" \
        "running $running_expected" "$(options "$running_switch" | grep '^running ')"
done

check 'options: an unknown arm argument exits 2' '2' \
    "$(options arm sideways >/dev/null 2>&1; echo $?)"

# The line the switch writes must be one the generator turns into ARM translation.
options_fixture
options arm on
check 'options: the arm switch line drops the native bridge deletes' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$WORK/opt/user.conf" \
        | grep -c -- '-d ro.dalvik.vm.native.bridge$')"

# --- the host clipboard switch (issue #76) --------------------------------------

options_fixture
options clipboard on
options arm on
check 'options: clipboard and arm each write their own line' \
    'native_bridge keep
boot_qemu keep' \
    "$(grep -x -e 'native_bridge keep' -e 'boot_qemu keep' "$WORK/opt/user.conf" | sort -r)"

options clipboard off
check 'options: clipboard off leaves the arm line alone' \
    'configured off
configured on' \
    "$(options clipboard | grep '^configured '; options arm | grep '^configured ')"

# The line the switch writes must be one the generator turns into a kept property.
options_fixture
options clipboard on
check 'options: the clipboard switch line drops the ro.boot.qemu delete' '0' \
    "$(sh "$GENERATE" "$REPO/module/artifacts.conf" "$WORK/opt/user.conf" | grep -cxF "$boot_qemu_delete")"

# --- the user config before the first choice (issue #61) -----------------------

# The user config does not exist until something is chosen. Reading must treat it
# as empty, and the first choice must create it.
rm -f "$WORK/opt/user.conf"
check 'options: with no user config arm reads configured off' 'off' "$(options_configured arm)"
check 'options: arm off with no user config succeeds and creates no file' 'exit=0 absent' \
    "$(options arm off 2>/dev/null; echo "exit=$? $([ -e "$WORK/opt/user.conf" ] && echo present || echo absent)")"
options arm on
check 'options: arm on with no user config creates it with that one line' \
    'native_bridge keep' "$(cat "$WORK/opt/user.conf")"

webui_fixture
rm -f "$WORK/webui.conf"
check 'webui: with no user config nothing is ours' '' "$(webui selection)"
webui add com.example.third
check 'webui: add with no user config creates it with that one line' \
    'angle com.example.third' "$(cat "$WORK/webui.conf")"

# --- the device dropdown (issue #133) ----------------------------------------

# device_fixture <running release>: the options fixture with the shipped presets,
# booted with the Pixel 8 and no device chosen.
device_fixture() {
    options_fixture
    rm -f "$WORK/opt/user.conf"
    printf 'device shiba\n' > "$WORK/opt/module/artifacts.conf"
    cp -R "$REPO/module/devices" "$WORK/opt/module/devices"
    printf '%s' "$1" > "$WORK/opt/props/ro.build.version.release"
    sed -n 's/^setprop ro.build.fingerprint //p' "$REPO/module/devices/shiba.conf" \
        > "$WORK/opt/props/ro.build.fingerprint"
}

device_fixture 16
check 'options: device lists the presets for the running release, with the default configured' \
    'configured shiba
running shiba
preset caiman Pixel 9 Pro
preset cheetah Pixel 7 Pro
preset husky Pixel 8 Pro
preset komodo Pixel 9 Pro XL
preset shiba Pixel 8' \
    "$(options device)"

options device husky
check 'options: choosing a preset writes its line and reads configured, still running the default' \
    'device husky
configured husky
running shiba' \
    "$(cat "$WORK/opt/user.conf"; options device | grep -v '^preset ')"

printf '# mine\nangle com.example\n' > "$WORK/opt/user.conf"
cp "$WORK/opt/user.conf" "$WORK/device-before.conf"
options device komodo
options device shiba
check 'options: choosing a preset then the default round-trips the user config byte for byte' 'identical' \
    "$(cmp -s "$WORK/device-before.conf" "$WORK/opt/user.conf" && echo identical)"

printf '  device caiman\n\tdevice\tkomodo\n' > "$WORK/opt/user.conf"
options device husky
check 'options: a choice replaces every device line, however a hand edit spaced it' \
    'device husky' "$(cat "$WORK/opt/user.conf")"

for refused_device in 'nosuch|1' 'a;b|2' 'Husky|2'; do
    device_fixture 16
    options device "${refused_device%|*}" >/dev/null 2>&1
    check "options: device '${refused_device%|*}' is refused and writes nothing" \
        "exit=${refused_device#*|} none" \
        "exit=$? $([ -e "$WORK/opt/user.conf" ] && echo written || echo none)"
done

device_fixture 17
options device husky >/dev/null 2>&1
check 'options: on another Android release no preset is listed, and none can be chosen' \
    'exit=1 configured shiba
running shiba' \
    "exit=$? $(options device)"

device_fixture 16
cat >> "$WORK/opt/module/apply.log" <<'LOG'
device: 'husky' is for Android 16, and this device runs Android 17; the default, shiba, applies
device: 'husky' is for Android 16, and this device runs Android 17; the default, shiba, applies
LOG
check 'options: health warns once about a device choice that was not applied' \
    "health warn
detail The chosen device was not applied: 'husky' is for Android 16, and this device runs Android 17; the default, shiba, applies." \
    "$(options health | grep -e '^health' -e 'device')"

# --- carrying choices over at install (issue #61) -------------------------------

# customize.sh cannot run on a host; this is the wiring the checks below rely on.
check 'the installer carries choices over from the installed module' '1' \
    "$(grep -c '^sh "\$MODPATH/lib/carry_over.sh" /data/adb/modules/noemulator "\$MODPATH/artifacts.conf" |$' "$REPO/module/customize.sh")"

# carry_fixture <installed versionCode>: an installed module whose artifacts.conf
# holds the shipped lines plus what an older WebUI and a hand edit added.
carry_fixture() {
    rm -rf "$WORK/carry"
    mkdir -p "$WORK/carry/installed" "$WORK/carry/adb"
    printf 'id=noemulator\nversionCode=%s\n' "$1" > "$WORK/carry/installed/module.prop"
    cat > "$WORK/carry/shipped.conf" <<'CONF'
# shipped
delprop ro.boot.qemu
delprop_once_set vendor.qemu.timezone
#   delprop_once_set vendor.qemu.vport.modem
CONF
    cat "$WORK/carry/shipped.conf" - > "$WORK/carry/installed/artifacts.conf" <<'CONF'
angle com.example.a
  delprop_once_set vendor.qemu.vport.modem
delprop ro.hand.edit
CONF
}

carry() {
    NOEMULATOR_USER_CONFIG="$WORK/carry/adb/noemulator-user.conf" \
        sh "$REPO/module/lib/carry_over.sh" "$WORK/carry/installed" "$WORK/carry/shipped.conf"
}

carry_fixture 16
check 'carry: the WebUI kinds are carried and a hand edit is named, not copied' \
    'carried angle com.example.a
carried delprop_once_set vendor.qemu.vport.modem
not carried delprop ro.hand.edit' \
    "$(carry)"
check 'carry: the user config holds exactly the carried lines' \
    'angle com.example.a
delprop_once_set vendor.qemu.vport.modem' \
    "$(cat "$WORK/carry/adb/noemulator-user.conf")"

carry >/dev/null
check 'carry: a rerun adds no line twice' '2' \
    "$(grep -c . "$WORK/carry/adb/noemulator-user.conf")"

# A line the user config already has, from an earlier choice, is not added again.
carry_fixture 16
printf 'angle com.example.a\n' > "$WORK/carry/adb/noemulator-user.conf"
carry >/dev/null
check 'carry: a line already in the user config is not added again' '1' \
    "$(grep -cx 'angle com.example.a' "$WORK/carry/adb/noemulator-user.conf")"

# From versionCode 17 on, the installed artifacts.conf holds shipped rules only; a
# line only it has is one this version dropped, and must not come back.
carry_fixture 17
check 'carry: an installed version that already has the user config carries nothing' \
    '' "$(carry; cat "$WORK/carry/adb/noemulator-user.conf" 2>/dev/null)"

carry_fixture 16
rm -rf "$WORK/carry/installed"
check 'carry: a fresh install carries nothing' \
    '' "$(carry; cat "$WORK/carry/adb/noemulator-user.conf" 2>/dev/null)"

if [ "$invariants_only" -eq 1 ]; then
    printf '\n%d invariant checks, %d failed\n' "$checks" "$failures"
else
    printf '\n%d checks, %d failed\n' "$checks" "$failures"
fi
[ "$failures" -eq 0 ]
