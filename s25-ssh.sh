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
# If the phone is reachable over Wi-Fi it goes straight there instead, and then no
# cable is needed at all -- which matters on a phone kept plugged in only for adb,
# since unplugging it is what stops the battery being held at charge all day.
#
#   ./s25-ssh.sh                 shell on the phone (Wi-Fi if reachable, else USB)
#   ./s25-ssh.sh -t              attach the long-lived tmux session instead
#   ./s25-ssh.sh 'uptime'        run one command and exit
#   ./s25-ssh.sh -u              force the USB tunnel
#   S25_HOST=10.0.0.5 ./s25-ssh.sh    skip discovery, use this address
#
# Requires sshd set up in Termux -- see docs/termux-shell.md.
set -u

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/s25-common.sh"

PKG=com.termux
SSH_PORT="${SSH_PORT:-8022}"        # what sshd listens on, on the phone
LOCAL_PORT="${LOCAL_PORT:-$SSH_PORT}"
SESSION="${SESSION:-lab}"

attach=0; force_usb=0
while getopts "tu" o 2>/dev/null; do
    case $o in t) attach=1;; u) force_usb=1;; esac
done
shift $((OPTIND-1))

IPCACHE="${IPCACHE:-$HOME/.cache/s25-ip}"

# Reachable means "something is listening on the ssh port", not "the host pings".
# A phone that answers ping but has no sshd running is not usable, and finding that
# out here rather than after a 30-second ssh timeout is the whole point.
reachable() {
    timeout 3 bash -c "exec 3<>/dev/tcp/$1/$SSH_PORT" 2>/dev/null
}

target="$(s25_target)"

# Wi-Fi first: the address given, else the last known one, else ask the phone over
# USB while it is still attached and remember the answer for when it is not.
host=""
if [ "$force_usb" = 0 ]; then
    for cand in "${S25_HOST:-}" "$(cat "$IPCACHE" 2>/dev/null)"; do
        [ -n "$cand" ] && reachable "$cand" && { host="$cand"; break; }
    done
    if [ -z "$host" ] && [ -n "$target" ]; then
        ip=$($ADB -s "$target" shell ip -4 addr show wlan0 2>/dev/null \
             | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)
        if [ -n "$ip" ] && reachable "$ip"; then
            host="$ip"
            mkdir -p "$(dirname "$IPCACHE")" && printf '%s' "$ip" > "$IPCACHE"
        fi
    fi
fi

if [ -z "$host" ] && [ -z "$target" ]; then
    echo "[ssh] no device over USB, and nothing listening on port $SSH_PORT over Wi-Fi."
    s25_no_device_msg
    exit 1
fi

if [ -n "$host" ]; then
    # Straight over the network -- no forward, no cable.
    ssh_opts=(-p "$SSH_PORT" -o "HostKeyAlias=termux-${target:-$host}" -o StrictHostKeyChecking=accept-new)
    if [ $# -gt 0 ]; then
        exec ssh "${ssh_opts[@]}" "$host" "$@"
    elif [ "$attach" = 1 ]; then
        exec ssh -t "${ssh_opts[@]}" "$host" "tmux attach -t $SESSION || tmux new-session -s $SESSION"
    else
        echo "[ssh] $host over Wi-Fi"
        exec ssh "${ssh_opts[@]}" "$host"
    fi
fi

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
