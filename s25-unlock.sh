#!/bin/bash
# Unlock the S25's lock screen over adb, with no video pipeline involved.
#
# Works whether the scrcpy mirror is showing black at the bouncer or has died
# outright -- neither matters here, this only sends key events.
#
#   ~/tools/scrcpy/s25-unlock.sh          prompts for the PIN
#   PIN=1234 ~/tools/scrcpy/s25-unlock.sh pass it in
#   echo <pin> > ~/.config/s25-pin && chmod 600 ~/.config/s25-pin
#                                         remember it (needed for unattended use)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/s25-common.sh"

PINFILE="${PINFILE:-$HOME/.config/s25-pin}"

target="$(s25_target)"
[ -z "$target" ] && { s25_no_device_msg; exit 1; }
case "$target" in *:*) link="Wi-Fi";; *) link="USB";; esac
echo "[unlock] device=$target via $link"

dsh() { $ADB -s "$target" shell "$@"; }

# Each of these runs its own `dumpsys window` -- a few hundred ms, and state changes
# between calls anyway, so caching would only make the answers stale.
# Do NOT use `mCurrentFocus` to decide locked/unlocked:
# this device prints several mCurrentFocus lines and the first is `null`, which reads
# as "unlocked" while isKeyguardShowing is still true. The keyguard flag is the truth.
win() { dsh dumpsys window 2>/dev/null | tr -d '\r'; }
locked()  { win | grep -q 'isKeyguardShowing=true'; }
bouncer() { win | grep 'mCurrentFocus' | grep -qi 'bouncer'; }
focus()   { win | grep 'mCurrentFocus' | grep -v 'null' | head -1; }

# PIN comes from the environment, then the file, then the terminal. Nothing writes it
# to disk on its own -- create $PINFILE yourself if you want unattended unlocking.
PIN="${PIN:-}"
if [ -z "$PIN" ] && [ -r "$PINFILE" ]; then
    PIN=$(tr -d '\r\n' < "$PINFILE")
fi
if [ -z "$PIN" ]; then
    if [ -t 0 ]; then
        read -rsp "[unlock] PIN: " PIN; echo
    else
        echo "[unlock] no PIN: set \$PIN or create $PINFILE"; exit 1
    fi
fi
case "$PIN" in
    ''|*[!0-9]*) echo "[unlock] PIN must be digits only"; exit 1 ;;
esac

# 1. Wake the panel. Locked-and-asleep swallows everything that follows.
dsh input keyevent 224 >/dev/null 2>&1
sleep 1

if ! locked; then
    echo "[unlock] already unlocked ($(focus))"
    exit 0
fi

# 2. Raise the PIN pad. The keyguard shade sits above it; until it is swiped away
#    the digits land nowhere and nothing tells you so. Retry -- the swipe is
#    occasionally eaten while the shade is still animating in.
# On Samsung the woken lock screen focuses NotificationShade, and the swipe promotes
# it to Bouncer -- but that transition takes about two seconds. Re-checking after only
# one second reports "could not raise the PIN pad" on a screen that was about to be
# ready, so give each attempt time to land before deciding it failed.
for _ in 1 2 3 4; do
    bouncer && break
    dsh input keyevent 224 >/dev/null 2>&1        # re-wake: the panel can sleep mid-retry
    dsh input swipe 540 2000 540 800 200 >/dev/null 2>&1
    sleep 2
done
if ! bouncer; then
    dsh input keyevent 82 >/dev/null 2>&1     # KEYCODE_MENU, older fallback
    sleep 1
fi

# 3. Do not send digits unless the bouncer is actually up -- this check is the
#    whole reason the earlier one-liner was unreliable.
if ! bouncer; then
    echo "[unlock] FAILED: could not raise the PIN pad (focus: $(focus))"
    exit 1
fi

# 4. Clear whatever is already in the field first. A half-typed PIN left there by
#    someone poking at a dead panel makes our digits append to theirs, and the only
#    symptom is a bogus "wrong PIN" -- while burning a real failed attempt each time.
for _ in $(seq 1 12); do dsh input keyevent 67 >/dev/null 2>&1; done   # KEYCODE_DEL

# 5. Digits. The bouncer ignores `input text`; it only accepts raw keycodes.
#    KEYCODE_0=7 .. KEYCODE_9=16, so keycode = digit + 7.
for (( i=0; i<${#PIN}; i++ )); do
    dsh input keyevent $(( ${PIN:$i:1} + 7 )) >/dev/null 2>&1
done
dsh input keyevent 66 >/dev/null 2>&1         # Enter, for PINs that do not auto-submit
sleep 2

# 6. Verify rather than assume.
if locked; then
    echo "[unlock] FAILED: still locked -- wrong PIN?"
    exit 1
fi
echo "[unlock] OK: unlocked ($(focus))"

# Keep it awake so it does not re-lock a minute from now. Only holds while the
# cable supplies power -- a cable drop drops this too.
dsh svc power stayon true >/dev/null 2>&1
