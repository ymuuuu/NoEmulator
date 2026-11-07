#!/usr/bin/env bash
# Build a device preset from a Pixel-Props dump, so no preset value is typed by hand.
#
# Usage: scripts/make_device_preset.sh <Device_BUILD.zip> > module/devices/<codename>.conf
#
# The zip is a release asset of https://github.com/Pixel-Props/build.prop. Its
# system.prop concatenates a real device's partition build.prop files
# (docs/research/pixel-device-presets.md). Only that member is read, with unzip -p;
# nothing is extracted and nothing in the zip is run.
#
# The build.prop values are taken verbatim. The SoC and board names are not in a
# build.prop, so they come from the table below, one row per codename with the
# AOSP device-tree line it was read from. A codename with no row is refused: a
# Tensor G5 or G6 phone has no published tree (ADR 0034).
set -euo pipefail

ZIP="${1:?usage: make_device_preset.sh <Device_BUILD.zip>}"
[ -r "$ZIP" ] || { echo "cannot read $ZIP" >&2; exit 1; }

# The build.prop properties every preset sets, in the order devices/shiba.conf
# sets them. ro.product.board, ro.hardware, ro.boot.hardware, ro.hardware.power and
# ro.build.product are filled from the device-tree table instead.
BUILD_PROP_NAMES="
ro.build.fingerprint ro.product.model ro.product.name
ro.product.device
ro.build.id ro.build.display.id ro.build.version.incremental
ro.build.description ro.build.flavor
ro.soc.model ro.soc.manufacturer ro.product.first_api_level
ro.product.system.model ro.product.system.name
ro.product.odm.model ro.product.odm.name ro.product.odm.device
ro.product.product.model ro.product.product.name ro.product.product.device
ro.product.system_dlkm.model ro.product.system_dlkm.name ro.product.system_dlkm.device
ro.product.system_ext.model ro.product.system_ext.name ro.product.system_ext.device
ro.product.vendor.model ro.product.vendor.name ro.product.vendor.device
ro.product.vendor_dlkm.model ro.product.vendor_dlkm.name ro.product.vendor_dlkm.device
ro.system.build.fingerprint ro.odm.build.fingerprint ro.product.build.fingerprint
ro.system_dlkm.build.fingerprint ro.system_ext.build.fingerprint
ro.vendor.build.fingerprint ro.vendor_dlkm.build.fingerprint
ro.odm.build.id ro.product.build.id ro.system.build.id ro.system_dlkm.build.id
ro.system_ext.build.id ro.vendor.build.id ro.vendor_dlkm.build.id
ro.odm.build.version.incremental ro.product.build.version.incremental
ro.system.build.version.incremental ro.system_dlkm.build.version.incremental
ro.system_ext.build.version.incremental ro.vendor.build.version.incremental
ro.vendor_dlkm.build.version.incremental
"

# <codename> -> "<SoC name> <board> <SoC source> <board source>", all from
# android.googlesource.com/device/google, branch main, read 2026-10-29.
device_tree_row() {
    case "$1" in
        cheetah) echo "gs201 cheetah gs201/device.mk:46 pantah/cheetah/BoardConfig.mk:25" ;;
        husky) echo "zuma husky zuma/device.mk:51 shusky/husky/BoardConfig.mk:27" ;;
        caiman) echo "zumapro caiman zumapro/device.mk:51 caimito/caiman/BoardConfig.mk:18" ;;
        komodo) echo "zumapro komodo zumapro/device.mk:51 caimito/komodo/BoardConfig.mk:18" ;;
        *) return 1 ;;
    esac
}

PROPS=$(unzip -p "$ZIP" system.prop)

# The value of one property. Refused when absent, when two sections disagree, or
# when it holds a character generate_rules.sh would refuse or a reader would not
# expect: the zip is someone else's file.
prop() {
    local values
    values=$(printf '%s\n' "$PROPS" | sed -n "s/^${1//./\\.}=//p" | sort -u)
    case "$values" in
        '') echo "$ZIP: no $1" >&2; exit 1 ;;
        *$'\n'*) echo "$ZIP: $1 has more than one value" >&2; exit 1 ;;
        *[!A-Za-z0-9\ ._:/,+-]*) echo "$ZIP: $1 has an unexpected character: $values" >&2; exit 1 ;;
    esac
    printf '%s' "$values"
}

codename=$(prop ro.product.device)
release=$(prop ro.build.version.release)
model=$(prop ro.product.model)
row=$(device_tree_row "$codename") || {
    echo "$ZIP: no device-tree source for '$codename'" >&2
    exit 1
}
read -r soc board soc_source board_source <<< "$row"
sha=$(sha256sum "$ZIP" | cut -d' ' -f1)

cat <<EOF
# Device preset: $model ("$codename"), Android $release.
#
# Built by scripts/make_device_preset.sh from $(basename "$ZIP"),
# sha256 $sha,
# a Pixel-Props dump of a real device's build.prop files. Rebuild it from the zip
# rather than editing it (docs/research/pixel-device-presets.md).
#
# Not in any build.prop, so taken from the AOSP device tree (device/google):
# ro.hardware, ro.boot.hardware and ro.hardware.power are the SoC name, $soc
# ($soc_source);
# ro.product.board is $board ($board_source);
# ro.build.product is the codename, as in devices/shiba.conf.

android $release

EOF

for name in $BUILD_PROP_NAMES; do
    # Assigned first: set -e does not see a failure inside an echo's arguments.
    value=$(prop "$name")
    echo "setprop $name $value"
    case "$name" in
        ro.product.name)
            echo "setprop ro.product.board $board"
            echo "setprop ro.hardware $soc"
            echo "setprop ro.boot.hardware $soc"
            echo "setprop ro.hardware.power $soc"
            ;;
        ro.product.device)
            echo "setprop ro.build.product $codename"
            ;;
    esac
done
echo
echo "setting global device_name $model"
