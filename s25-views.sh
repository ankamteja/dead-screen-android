#!/bin/bash
# Locate on-screen views when the accessibility tree is unavailable.
#
# s25-tap.sh is the tool you want first -- it reads labels. But `uiautomator dump`
# refuses to produce anything on a screen that never goes idle:
#
#     ERROR: could not get idle state.
#
# An animation that never stops -- a TOTP countdown, an indeterminate spinner, a
# looping progress bar -- keeps the window busy forever, and the dump never comes.
# Worse, `uiautomator` **exits 0 in that case**, so `dump && read-the-file` looks
# like it worked and silently reads nothing.
#
# `dumpsys activity top` renders the same window from the view hierarchy instead,
# and it does not care about idleness or about FLAG_SECURE. The trade is that it
# carries no text: you get resource ids, classes and bounds. Often that is enough,
# because ids are named (menu_account_settings, action_chevron_right_icon).
#
#   ./s25-views.sh                 every visible view of the focused app
#   ./s25-views.sh toolbar         only views whose id or class matches
#   ./s25-views.sh -p com.foo.bar  a specific package rather than the focused one
#   ./s25-views.sh -c              clickable views only
#
# Then tap what you found:  adb shell input tap <x> <y>
set -u

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/s25-common.sh"

pkg=""; clickonly=0
while getopts "p:c" o 2>/dev/null; do
    case $o in p) pkg="$OPTARG";; c) clickonly=1;; esac
done
shift $((OPTIND-1))
want="${1:-}"

target="$(s25_target)"
[ -z "$target" ] && { s25_no_device_msg; exit 1; }
dsh() { $ADB -s "$target" shell "$@"; }

if [ -z "$pkg" ]; then
    # Several mCurrentFocus lines get printed and the first is often null, the same
    # trap documented for isKeyguardShowing -- so filter nulls before taking one.
    pkg=$(dsh dumpsys window 2>/dev/null | grep mCurrentFocus | grep -iv null | head -1 \
          | grep -oE '[a-z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+/' | head -1 | tr -d '/')
    [ -z "$pkg" ] && { echo "[views] could not tell which app is focused -- pass -p <package>"; exit 1; }
    echo "[views] focused package: $pkg"
fi

# The dump goes to a file rather than a pipe: the parser arrives on stdin as a
# heredoc, so stdin is already spoken for.
DUMP=$(mktemp "${TMPDIR:-/tmp}/s25-views.XXXXXX")
trap 'rm -f "$DUMP"' EXIT
dsh dumpsys activity top > "$DUMP" 2>/dev/null
[ -s "$DUMP" ] || { echo "[views] empty dump from dumpsys activity top"; exit 1; }

python3 "$HERE/lib/parse-views.py" "$pkg" "$want" "$clickonly" "$DUMP"
