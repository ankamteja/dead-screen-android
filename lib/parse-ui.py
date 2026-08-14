#!/usr/bin/env python3
"""Turn a uiautomator dump into a listing, or into one tap target.

Kept as its own file rather than a heredoc inside s25-tap.sh so the matching rules
-- which decide where a tap lands on a screen nobody can see -- are directly testable.
See tests/run.sh.

    parse-ui.py DUMP.xml WANT FIRST CLICKONLY

WANT empty          -> print a listing, exit 0
WANT matches one    -> print "TAP <x> <y> <label>", exit 0
WANT matches many   -> list them, exit 1 (unless FIRST=1)
WANT matches none   -> message, exit 1
"""
import re, sys, xml.etree.ElementTree as ET

BOUNDS = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


def collect(path, clickonly):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        # OSError covers a dump that never landed -- adb can fail silently and leave
        # no file at all, and a traceback there hides what actually went wrong.
        sys.exit(f"[tap] could not parse the dump: {e}")

    items = []
    for n in root.iter("node"):
        label = (n.get("text") or n.get("content-desc") or "").strip()
        if not label:
            continue
        if clickonly and n.get("clickable") != "true":
            continue
        m = BOUNDS.match(n.get("bounds", ""))
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        items.append((label, (x1 + x2) // 2, (y1 + y2) // 2, n.get("clickable") == "true"))

    # A label usually appears on both a node and its parent, at the same centre. That is
    # one button, not two -- collapsing them keeps the ambiguity check meaningful instead
    # of firing on every nested view.
    seen, unique = set(), []
    for label, x, y, click in items:
        key = (label.lower(), x, y)
        if key in seen:
            continue
        seen.add(key)
        unique.append((label, x, y, click))
    return unique


def main(argv):
    if len(argv) != 5:
        sys.exit(__doc__)
    path, want = argv[1], argv[2]
    first, clickonly = argv[3] == "1", argv[4] == "1"

    items = collect(path, clickonly)
    if not items:
        sys.exit("[tap] nothing with a label on screen")

    if not want:
        for label, x, y, click in items:
            print(f"  {'*' if click else ' '} {label[:58]:<58} tap {x},{y}")
        print('\n  (* = clickable)   tap one with:  s25-tap.sh "<text>"')
        return 0

    hits = [i for i in items if want.lower() in i[0].lower()]
    if not hits:
        sys.exit(f"[tap] no match for {want!r}. Run with no arguments to see what is on screen.")
    if len(hits) > 1 and not first:
        print(f"[tap] {len(hits)} matches for {want!r} -- refusing to guess. Use -a, or be more specific:")
        for label, x, y, _ in hits:
            print(f"    {label[:58]:<58} tap {x},{y}")
        return 1

    label, x, y, _ = hits[0]
    print(f"TAP {x} {y} {label[:58]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
