#!/bin/bash
# Tests that need no phone attached.
#
# The tap parser decides where a tap lands on a screen nobody can see, so its rules
# are worth pinning down: a wrong tap on a payments screen is not recoverable.
#
#   tests/run.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
PARSE="$ROOT/lib/parse-ui.py"
PARSEV="$ROOT/lib/parse-views.py"
FIX="$HERE/fixtures/screen.xml"
FIXV="$HERE/fixtures/dumpsys-top.txt"

pass=0; fail=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

# assert <name> <expected-rc> <substring-that-must-appear> -- <parse-ui args...>
assert() {
    local name="$1" want_rc="$2" want_out="$3"; shift 4
    local out rc
    out=$(python3 "$PARSE" "$@" 2>&1); rc=$?
    if [ "$rc" != "$want_rc" ]; then
        bad "$name" "exit $rc, wanted $want_rc -- $out"
    elif [ -n "$want_out" ] && ! grep -qF -- "$want_out" <<<"$out"; then
        bad "$name" "output missing '$want_out' -- $out"
    else
        ok "$name"
    fi
}

echo "parser:"

# A label on a node and its parent at the same centre is ONE button. Before dedupe this
# reported two matches and refused to act on an unambiguous target.
assert "dedupe: nested duplicate is one target" 0 "TAP 540 2060" -- "$FIX" "Camera" 0 0

# Different positions are genuinely ambiguous -- refusing is the whole safety property.
assert "ambiguity: distinct positions refuse"   1 "refusing to guess" -- "$FIX" "Page" 0 0

# ...unless the caller opts in with -a.
assert "ambiguity: -a takes the first"          0 "TAP" -- "$FIX" "Page" 1 0

assert "single match taps exact centre"         0 "TAP 540 1491" -- "$FIX" "Use PIN" 0 0
assert "matching is case-insensitive"           0 "TAP 540 1491" -- "$FIX" "use pin" 0 0
assert "substring matches"                      0 "TAP 540 992"  -- "$FIX" "is locked" 0 0
assert "no match exits nonzero"                 1 "no match for" -- "$FIX" "nonexistent" 0 0

# Unlabelled nodes must not become invisible tap targets, and a malformed bounds
# attribute must be skipped rather than crashing the run.
assert "listing skips unlabelled nodes"         0 "Use PIN"      -- "$FIX" "" 0 0
assert "listing survives malformed bounds"      0 "Camera"       -- "$FIX" "" 0 0
out=$(python3 "$PARSE" "$FIX" "" 0 0)
grep -qF "Broken bounds" <<<"$out" \
    && bad "malformed bounds excluded" "'Broken bounds' should not be listed" \
    || ok "malformed bounds excluded"

# -c must drop the non-clickable rows.
out=$(python3 "$PARSE" "$FIX" "" 0 1)
grep -qF "PhonePe is locked" <<<"$out" \
    && bad "clickonly filters static text" "static label still listed" \
    || ok "clickonly filters static text"

# "Nothing on screen" and "the dump failed" are different faults and must read
# differently -- otherwise a broken dump looks like an empty screen and you retry forever.
assert "labelless screen says so"               1 "nothing with a label" -- "$HERE/fixtures/empty.xml" "" 0 0
assert "unparseable dump says so instead"       1 "could not parse"      -- /dev/null "" 0 0
assert "missing file does not traceback"        1 "could not parse"      -- "$HERE/fixtures/nope.xml" "" 0 0

echo "view parser:"

# assert_views <name> <expected-rc> <substring> -- <parse-views args...>
assert_views() {
    local name="$1" want_rc="$2" want_out="$3"; shift 4
    local out rc
    out=$(python3 "$PARSEV" "$@" 2>&1); rc=$?
    if [ "$rc" != "$want_rc" ]; then
        bad "$name" "exit $rc, wanted $want_rc -- $out"
    elif [ -n "$want_out" ] && ! grep -qF -- "$want_out" <<<"$out"; then
        bad "$name" "output missing '$want_out' -- $out"
    else
        ok "$name"
    fi
}

# The whole point of this parser: dumpsys prints bounds relative to the PARENT, so a
# menu item at 936,12 inside a toolbar at 0,103 is really at 936,115 and taps at
# 1008,187. Reading the raw numbers as absolute puts every tap in the wrong place.
assert_views "bounds resolve against ancestors" 0 "tap 1008,187" -- com.example.app "" 0 "$FIXV"

# A dump holds every top activity. Bleeding views from another package in would offer
# tap targets that are not on screen.
assert_views "other packages excluded"          1 "nothing matched" -- com.example.app other_app_button 0 "$FIXV"
assert_views "named package is readable"        0 "other_app_button" -- com.example.other "" 0 "$FIXV"

# GONE views and collapsed (zero-size) views are not tappable; listing them invites a
# tap into dead space that silently does nothing.
assert_views "invisible views excluded"         1 "nothing matched" -- com.example.app hidden_logo 0 "$FIXV"
assert_views "zero-size views excluded"         1 "nothing matched" -- com.example.app collapsed_button 0 "$FIXV"

assert_views "filter matches id substring"      0 "title_text"   -- com.example.app title 0 "$FIXV"
assert_views "clickonly drops static text"      1 "nothing matched" -- com.example.app title 1 "$FIXV"
assert_views "absent package says so"           1 "no top activity" -- com.example.nope "" 0 "$FIXV"
assert_views "empty dump does not traceback"    1 "no top activity" -- com.example.app "" 0 /dev/null

echo "syntax:"
for f in "$ROOT"/*.sh "$HERE"/run.sh; do
    if bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f")" "bash -n failed"; fi
done
# ast.parse rather than py_compile: same syntax check, but py_compile writes bytecode
# by design and litters __pycache__ directories through the repo on every test run.
if python3 -c '
import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f).read(), f)
' "$PARSE" "$ROOT/docs/make-demo.py" 2>/dev/null; then
    ok "python files parse"
else
    bad "python files parse" "syntax error"
fi

echo "hygiene:"
# Nothing device- or user-specific may reach the repo. This is the check that keeps a
# serial or a PIN from being committed by accident.
if grep -rInE '(RZ[A-Z0-9]{9}|/home/[a-z]+/|[0-9]{15})' \
        --include='*.sh' --include='*.py' --include='*.md' --include='*.service' \
        "$ROOT" 2>/dev/null | grep -v '/tests/run.sh:'; then
    bad "no personal identifiers" "see matches above"
else
    ok "no personal identifiers"
fi

echo
if [ "$fail" = 0 ]; then
    printf '\033[32m%d passed\033[0m\n' "$pass"
else
    printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
fi
exit $((fail > 0))
