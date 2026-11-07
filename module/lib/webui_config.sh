#!/system/bin/sh
# Line surgery on the user config, shared by the WebUI helpers.
#
# The config is never regenerated: a hand-edited user config keeps its own
# comments and order (ADR 0019). A helper adds one line at the end or drops one
# line that matches exactly, and nothing else in the file changes.
#
# The user config does not exist until the first choice is made, so a missing
# file reads as empty and the first append creates it.
#
# Lines are compared as whole strings, never as patterns. Directive arguments
# contain dots, and a dot is a regex metacharacter: `grep -qx` once matched
# `angle com.a_b` for `com.a.b` (ADR 0019).
#
# Sourced, after lib/user_config.sh.

noemulator_webui_has_line() {
    [ -e "$NOEMULATOR_USER_CONFIG" ] || return 1
    while IFS= read -r webui_config_line || [ -n "$webui_config_line" ]; do
        [ "$webui_config_line" = "$1" ] && return 0
    done < "$NOEMULATOR_USER_CONFIG"
    return 1
}

# A config hand-edited and saved without a final newline would otherwise take
# the new line onto the end of its last one. If that line is a comment, which
# the shipped config's last line is, the directive becomes part of the comment.
noemulator_webui_append_line() {
    if [ -s "$NOEMULATOR_USER_CONFIG" ] &&
        [ -n "$(tail -c 1 "$NOEMULATOR_USER_CONFIG")" ]; then
        printf '\n' >> "$NOEMULATOR_USER_CONFIG"
    fi
    printf '%s\n' "$1" >> "$NOEMULATOR_USER_CONFIG"
}

noemulator_webui_drop_line() {
    [ -e "$NOEMULATOR_USER_CONFIG" ] || return 0
    webui_config_rewritten="$NOEMULATOR_USER_CONFIG.webui"
    : > "$webui_config_rewritten"
    while IFS= read -r webui_config_line || [ -n "$webui_config_line" ]; do
        [ "$webui_config_line" = "$1" ] && continue
        printf '%s\n' "$webui_config_line" >> "$webui_config_rewritten"
    done < "$NOEMULATOR_USER_CONFIG"
    mv "$webui_config_rewritten" "$NOEMULATOR_USER_CONFIG"
}

# Drop every line holding <directive>, however it is indented: a hand-edited
# config may space it differently from what the WebUI writes.
noemulator_webui_drop_directive() {
    [ -e "$NOEMULATOR_USER_CONFIG" ] || return 0
    webui_config_tab=$(printf '\t')
    webui_config_rewritten="$NOEMULATOR_USER_CONFIG.webui"
    : > "$webui_config_rewritten"
    while IFS= read -r webui_config_line || [ -n "$webui_config_line" ]; do
        webui_config_trimmed=$webui_config_line
        while :; do
            case $webui_config_trimmed in
                ' '*|"$webui_config_tab"*) webui_config_trimmed=${webui_config_trimmed#?} ;;
                *) break ;;
            esac
        done
        case "$webui_config_trimmed" in
            "$1 "*|"$1$webui_config_tab"*) continue ;;
        esac
        printf '%s\n' "$webui_config_line" >> "$webui_config_rewritten"
    done < "$NOEMULATOR_USER_CONFIG"
    mv "$webui_config_rewritten" "$NOEMULATOR_USER_CONFIG"
}
