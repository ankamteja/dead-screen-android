#!/bin/bash
# rsync files to/from the phone's shared storage over the existing Termux sshd.
#
# Storage symlinks live at ~/storage/{shared,dcim,downloads,pictures,music,movies,...}
# on the phone (see docs -- created by hand via `pm grant` + manual symlinks since
# termux-setup-storage's broadcast needs the Termux app UI running, which a dead
# screen can't provide). shared/ is the whole of /storage/emulated/0.
#
#   ./s25-sync.sh pull dcim ~/Pictures/s25-dcim/       phone -> laptop
#   ./s25-sync.sh push ~/Documents/foo.pdf downloads   laptop -> phone
#   ./s25-sync.sh ls downloads                         list a remote folder
#
# Remote paths are relative to ~/storage/ on the phone unless they start with /.
# Reuses s25-ssh.sh's host discovery (Wi-Fi if reachable, else USB forward), so
# whatever gets you a shell also gets you a sync.
set -eu

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/s25-common.sh"

SSH_PORT="${SSH_PORT:-8022}"
IPCACHE="${IPCACHE:-$HOME/.cache/s25-ip}"

reachable() {
    timeout 3 bash -c "exec 3<>/dev/tcp/$1/$SSH_PORT" 2>/dev/null
}

target="$(s25_target)"
host=""
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

if [ -z "$host" ]; then
    if [ -z "$target" ]; then
        echo "[sync] no device over USB, and nothing listening on port $SSH_PORT over Wi-Fi."
        s25_no_device_msg
        exit 1
    fi
    # USB-only: forward and use localhost, same trick as s25-ssh.sh.
    if ! $ADB -s "$target" forward --list 2>/dev/null | grep -q "tcp:$SSH_PORT "; then
        $ADB -s "$target" forward "tcp:$SSH_PORT" "tcp:$SSH_PORT" >/dev/null
    fi
    host="localhost"
fi

ssh_opts=(-p "$SSH_PORT" -o "HostKeyAlias=termux-${target:-$host}" -o StrictHostKeyChecking=accept-new)
RSYNC_RSH="ssh ${ssh_opts[*]}"

resolve() {
    case "$1" in
        /*) echo "$1" ;;
        *) echo "storage/$1" ;;
    esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
    pull)
        [ $# -eq 2 ] || { echo "usage: s25-sync.sh pull <remote> <local>"; exit 1; }
        remote="$(resolve "$1")"
        rsync -e "$RSYNC_RSH" -avh --progress "$host:$remote" "$2"
        ;;
    push)
        [ $# -eq 2 ] || { echo "usage: s25-sync.sh push <local> <remote>"; exit 1; }
        remote="$(resolve "$2")"
        rsync -e "$RSYNC_RSH" -avh --progress "$1" "$host:$remote"
        ;;
    ls)
        [ $# -eq 1 ] || { echo "usage: s25-sync.sh ls <remote>"; exit 1; }
        remote="$(resolve "$1")"
        rsync -e "$RSYNC_RSH" -avh --list-only "$host:$remote/"
        ;;
    *)
        echo "usage: s25-sync.sh {pull|push|ls} ..."
        exit 1
        ;;
esac
