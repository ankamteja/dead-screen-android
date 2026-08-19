"""Turn `dumpsys activity top` into absolute, tappable coordinates.

Split out of s25-views.sh so it can be tested against a fixture with no phone
attached -- the same reason lib/parse-ui.py exists.

    parse-views.py <package> <filter> <clickonly:0|1> <dump-file>
"""
import re
import sys

pkg, want, clickonly, path = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
lines = open(path).read().splitlines()

# Keep only the block for this package: from its ACTIVITY header to the next one.
start = None
for i, l in enumerate(lines):
    if l.lstrip().startswith("ACTIVITY ") and pkg in l:
        start = i
    elif start is not None and l.lstrip().startswith("ACTIVITY "):
        lines = lines[start:i]
        break
else:
    if start is None:
        sys.exit(f"[views] no top activity for {pkg!r} -- is it in the foreground?")
    lines = lines[start:]

# Each view prints as  Class{hash flags flags left,top-right,bottom #id app:id/name}
# with indentation for depth. Bounds are relative to the PARENT, so absolute
# position is the running sum of every ancestor's origin -- hence the stack.
rx = re.compile(r"^(\s*)([\w.$]+)\{[0-9a-f]+ (\S+) (\S+) (-?\d+),(-?\d+)-(-?\d+),(-?\d+)(.*?)\}\s*$")
stack, rows, seen = [], [], False

for l in lines:
    if "View Hierarchy:" in l:
        seen = True
        stack = []
        continue
    if not seen:
        continue
    m = rx.match(l)
    if not m:
        continue
    indent = len(m.group(1))
    cls, flags, rest = m.group(2), m.group(3), m.group(9)
    x1, y1, x2, y2 = map(int, m.group(5, 6, 7, 8))

    while stack and stack[-1][0] >= indent:
        stack.pop()
    ax = (stack[-1][1] if stack else 0) + x1
    ay = (stack[-1][2] if stack else 0) + y1
    stack.append((indent, ax, ay))

    # flags field is like "V.ED..C.." -- V = visible, C = clickable.
    if flags[0] != "V" or x2 - x1 == 0 or y2 - y1 == 0:
        continue
    clickable = len(flags) > 6 and flags[6] == "C"
    if clickonly and not clickable:
        continue

    rid = re.search(r"(?:app|android):id/(\S+)", rest)
    name = rid.group(1) if rid else cls.rsplit(".", 1)[-1]
    if want and want.lower() not in name.lower() and want.lower() not in cls.lower():
        continue
    rows.append((clickable, name, ax, ay, x2 - x1, y2 - y1, cls.rsplit(".", 1)[-1]))

if not rows:
    sys.exit(f"[views] nothing matched{' ' + repr(want) if want else ''}")

for clickable, name, ax, ay, w, h, cls in rows:
    print(f"  {'*' if clickable else ' '} {name[:40]:<40} {w:>4}x{h:<4} at {ax},{ay}"
          f"   tap {ax + w // 2},{ay + h // 2}   {cls}")
print("\n  (* = clickable)   act on one with:  adb shell input tap <x> <y>")
