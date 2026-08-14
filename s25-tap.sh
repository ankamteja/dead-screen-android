#!/bin/bash
# See and tap what the mirror cannot show you.
#
# FLAG_SECURE blocks screen *capture*, not the accessibility tree. So when an app
# renders as a solid black rectangle in scrcpy -- lock screens, banking apps,
# authenticators -- its buttons are still fully readable through uiautomator, with
# exact pixel bounds. Same channel TalkBack uses.
#
#   ./s25-tap.sh                 list every labelled element and where it is
#   ./s25-tap.sh "Use PIN"       tap the element whose text/description matches
#   ./s25-tap.sh -a "Unlock"     tap the FIRST match instead of stopping on ambiguity
#   ./s25-tap.sh -c              list only clickable elements
#
# Matching is case-insensitive substring. On multiple matches it lists them and
# stops rather than guessing -- tapping the wrong button on a payments screen is
# not a recoverable mistake.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/s25-common.sh"

first=0; clickonly=0
while getopts "ac" o 2>/dev/null; do
    case $o in a) first=1;; c) clickonly=1;; esac
done
shift $((OPTIND-1))
want="${1:-}"

target="$(s25_target)"
[ -z "$target" ] && { s25_no_device_msg; exit 1; }
dsh() { $ADB -s "$target" shell "$@"; }

REMOTE=/sdcard/.s25-ui.xml
LOCAL=$(mktemp /tmp/s25-ui.XXXXXX.xml)
# A dump contains whatever is on screen, which can be personal. Never leave it
# behind on either machine.
cleanup() { rm -f "$LOCAL"; dsh rm -f "$REMOTE" >/dev/null 2>&1; }
trap cleanup EXIT

if ! dsh uiautomator dump "$REMOTE" >/dev/null 2>&1; then
    echo "[tap] dump failed -- is the screen on? try: $HERE/s25-unlock.sh"
    exit 1
fi
dsh cat "$REMOTE" > "$LOCAL" 2>/dev/null
[ -s "$LOCAL" ] || { echo "[tap] empty dump"; exit 1; }

# Prints either a listing (no target text) or a single "TAP x y label" line.
# The matching rules live in lib/parse-ui.py so they can be tested without a phone.
out=$(python3 "$HERE/lib/parse-ui.py" "$LOCAL" "$want" "$first" "$clickonly") \
    || { echo "$out"; exit 1; }

case "$out" in
    TAP\ *)
        set -- $out
        x=$2; y=$3; shift 3
        echo "[tap] '$*' at $x,$y"
        dsh input tap "$x" "$y"
        sleep 1
        echo "[tap] now focused: $(dsh dumpsys window 2>/dev/null | grep mCurrentFocus \
              | grep -iv null | head -1 | sed 's/.*[/ ]//;s/}.*//')"
        ;;
    *) echo "$out" ;;
esac
