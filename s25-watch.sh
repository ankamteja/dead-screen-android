#!/bin/bash
# Watch for the S25 and keep a mirror window open whenever it is connected.
#
# Handles two things:
#   1. auto-launch  -- plug the cable in, the window appears by itself
#   2. auto-recover -- this phone's USB port re-enumerates a lot, which kills scrcpy
#                      outright ("WARN: Device disconnected"). Instead of staying dead,
#                      we wait for it to come back and relaunch.
#
# Run it by hand, or as a user service:  systemctl --user enable --now s25-mirror
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/s25-common.sh"

LAUNCH="$HERE/s25.sh"
UNLOCK="$HERE/s25-unlock.sh"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

connected() {
    # Re-resolved every poll: at boot there is no device yet, so a serial captured
    # once at startup would be empty forever.
    [ -n "$(s25_target)" ]
}

backoff=3
while true; do
    if ! connected; then
        sleep 3
        backoff=3          # a fresh connection deserves a fresh, fast retry
        continue
    fi

    log "device present -- starting mirror"

    # Never let it sit at the lock screen: scrcpy captures the Bouncer as a black
    # frame, so a locked phone looks exactly like a broken mirror. Re-applied on
    # every recovery because stayon dies with the cable that dropped it.
    $ADB -s "$(s25_target)" shell svc power stayon true >/dev/null 2>&1
    if [ "${AUTO_UNLOCK:-0}" = 1 ] && [ -x "$UNLOCK" ]; then
        out=$("$UNLOCK" 2>&1 | tail -1); log "unlock: $out"
    fi

    start=$(date +%s)
    "$LAUNCH"
    rc=$?
    ran=$(( $(date +%s) - start ))
    log "mirror exited (rc=$rc) after ${ran}s"

    # A clean exit after a decent run means the user closed the window on purpose --
    # don't fight them by immediately reopening it. Wait for a real unplug/replug.
    if [ "$rc" = 0 ] && [ "$ran" -gt 10 ]; then
        log "closed by user -- waiting for reconnect before reopening"
        while connected; do sleep 3; done
        backoff=3
        continue
    fi

    # Otherwise it died on us. Back off progressively so a persistent fault does not
    # spin the CPU relaunching several times a second.
    if [ "$ran" -lt 10 ]; then
        backoff=$(( backoff * 2 )); [ "$backoff" -gt 30 ] && backoff=30
    else
        backoff=3
    fi
    log "retrying in ${backoff}s"
    sleep "$backoff"
done
