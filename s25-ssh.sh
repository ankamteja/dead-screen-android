#!/bin/bash
# ssh into the phone's Termux, over the USB cable.
#
# There is no route to port 8022 on the phone from the laptop -- campus and home
# networks isolate clients, carriers put you behind CGNAT, and the phone's address
# changes anyway. `adb forward` sidesteps all of it by tunnelling over the cable
# that is already there, so this works on any network and on none.
#
# The forward lives in the adb connection, not on the phone, so it disappears on
# every replug. That is the one piece of state worth automating, and the reason
# this script exists.
#
#   ./s25-ssh.sh                 shell on the phone
#   ./s25-ssh.sh -t              attach the long-lived tmux session instead
#   ./s25-ssh.sh 'uptime'        run one command and exit
#
# Requires sshd set up in Termux -- see docs/termux-shell.md.
set -u

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/s25-common.sh"

PKG=com.termux
SSH_PORT="${SSH_PORT:-8022}"        # what sshd listens on, on the phone
LOCAL_PORT="${LOCAL_PORT:-$SSH_PORT}"
SESSION="${SESSION:-lab}"

attach=0
while getopts "t" o 2>/dev/null; do
    case $o in t) attach=1;; esac
done
shift $((OPTIND-1))

target="$(s25_target)"
[ -z "$target" ] && { s25_no_device_msg; exit 1; }

# Start sshd if it isn't up. run-as only works on a debuggable build, so treat a
# failure here as advisory -- sshd may well be running already and reachable.
if $ADB -s "$target" shell "run-as $PKG true" >/dev/null 2>&1; then
    if ! $ADB -s "$target" shell "run-as $PKG sh -c 'pgrep sshd >/dev/null'" 2>/dev/null; then
        echo "[ssh] sshd not running -- starting it"
        "$HERE/s25-shell.sh" 'sshd' >/dev/null 2>&1
    fi
fi

# adb forward is idempotent, but re-adding prints noise, so only add what is missing.
if ! $ADB -s "$target" forward --list 2>/dev/null | grep -q "tcp:$LOCAL_PORT "; then
    $ADB -s "$target" forward "tcp:$LOCAL_PORT" "tcp:$SSH_PORT" >/dev/null \
        || { echo "[ssh] could not forward tcp:$LOCAL_PORT -- is something else on that port?"; exit 1; }
fi

# Every phone would otherwise be "localhost:8022" in known_hosts and the second one
# would look like a man-in-the-middle attack on the first. Keying the entry to the
# adb target keeps them apart.
ssh_opts=(-p "$LOCAL_PORT" -o "HostKeyAlias=termux-$target" -o StrictHostKeyChecking=accept-new)

if [ $# -gt 0 ]; then
    exec ssh "${ssh_opts[@]}" localhost "$@"
elif [ "$attach" = 1 ]; then
    # -t forces a pty: without it tmux refuses to attach, saying "open terminal failed".
    exec ssh -t "${ssh_opts[@]}" localhost \
        "tmux attach -t $SESSION || tmux new-session -s $SESSION"
else
    exec ssh "${ssh_opts[@]}" localhost
fi
