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

# Prints either a listing (no target text) or a single "x y" line to tap.
out=$(python3 - "$LOCAL" "$want" "$first" "$clickonly" <<'PY'
import re, sys, xml.etree.ElementTree as ET

path, want, first, clickonly = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
try:
    root = ET.parse(path).getroot()
except ET.ParseError as e:
    sys.exit(f"[tap] could not parse the dump: {e}")

items = []
for n in root.iter("node"):
    label = (n.get("text") or n.get("content-desc") or "").strip()
    if not label:
        continue
    if clickonly and n.get("clickable") != "true":
        continue
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    items.append((label, (x1 + x2) // 2, (y1 + y2) // 2, n.get("clickable") == "true"))

# A label often appears on both a node and its parent, at the same centre. Those are
# one button, not two -- collapsing them keeps the ambiguity check meaningful instead
# of firing on every nested view.
seen, unique = set(), []
for label, x, y, click in items:
    key = (label.lower(), x, y)
    if key in seen:
        continue
    seen.add(key)
    unique.append((label, x, y, click))
items = unique

if not items:
    sys.exit("[tap] nothing with a label on screen")

if not want:
    for label, x, y, click in items:
        print(f"  {'*' if click else ' '} {label[:58]:<58} tap {x},{y}")
    print('\n  (* = clickable)   tap one with:  s25-tap.sh "<text>"')
    sys.exit(0)

hits = [i for i in items if want.lower() in i[0].lower()]
if not hits:
    sys.exit(f"[tap] no match for {want!r}. Run with no arguments to see what is on screen.")
if len(hits) > 1 and not first:
    print(f"[tap] {len(hits)} matches for {want!r} -- refusing to guess. Use -a, or be more specific:")
    for label, x, y, _ in hits:
        print(f"    {label[:58]:<58} tap {x},{y}")
    sys.exit(1)

label, x, y, _ = hits[0]
print(f"TAP {x} {y} {label[:58]}")
PY
) || { echo "$out"; exit 1; }

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
