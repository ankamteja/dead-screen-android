#!/bin/bash
# Back up the Galaxy S25's shared storage to a folder on this laptop.
# Re-runnable: each top-level item is pulled into its own directory and marked done,
# so a re-run after an interruption skips what already completed.
#
#   ~/tools/scrcpy/s25-backup.sh            pull to ~/s25-backup
#   DEST=/path ~/tools/scrcpy/s25-backup.sh pull somewhere else
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/s25-common.sh"

DEST="${DEST:-$HOME/s25-backup}"
STAMP="$DEST/.done"

# Prefer USB: on 2.4GHz Wi-Fi this transfer is roughly an order of magnitude slower.
target="$(s25_target)"
[ -z "$target" ] && { s25_no_device_msg; exit 1; }
case "$target" in *:*) link="Wi-Fi";; *) link="USB";; esac

mkdir -p "$DEST" "$STAMP"
echo "[backup] device=$target via $link"
echo "[backup] destination: $DEST"

# Android/data and Android/obb are deliberately excluded: app-private sandboxes that
# adb mostly cannot read, dominated by regenerable caches.
items=(
  /sdcard/DCIM
  /sdcard/Android/media
  /sdcard/Recordings
  /sdcard/Download
  /sdcard/Pictures
  /sdcard/Movies
  /sdcard/Music
  /sdcard/Documents
  /sdcard/Alarms
  /sdcard/Notifications
  /sdcard/myvoice
  /sdcard/log
)

# Is the device actually reachable right now? Used to tell "path is absent" apart from
# "the transport just dropped" -- conflating those two once caused every directory to be
# marked complete without being pulled.
alive() { [ "$($ADB -s "$target" get-state 2>/dev/null)" = "device" ]; }

wait_alive() {
    alive && return 0
    echo "[backup] device unreachable, waiting up to 120s ..."
    for _ in $(seq 1 24); do
        sleep 5
        # a wireless target can need an explicit reconnect after a transport reset
        case "$target" in *:*) $ADB connect "$target" >/dev/null 2>&1;; esac
        alive && { echo "[backup] device back"; return 0; }
    done
    return 1
}

# Big trees are expanded into their immediate subdirectories so an interruption costs
# one subfolder rather than the whole 10GB.
expand() {
    local d="$1"
    local subs
    subs=$($ADB -s "$target" shell "ls -1p '$d' 2>/dev/null | grep '/\$'" 2>/dev/null | tr -d '\r')
    if [ -z "$subs" ]; then echo "$d"; return; fi
    while IFS= read -r s; do
        [ -n "$s" ] && echo "$d/${s%/}"
    done <<< "$subs"
}

expanded=()
for src in "${items[@]}"; do
    case "$src" in
        /sdcard/DCIM|/sdcard/Android/media)
            wait_alive || { echo "[backup] ABORT: device gone"; exit 1; }
            while IFS= read -r e; do expanded+=("$e"); done < <(expand "$src") ;;
        *) expanded+=("$src") ;;
    esac
done

fail=0
for src in "${expanded[@]}"; do
    key=$(echo "$src" | tr '/ ' '__')
    if [ -e "$STAMP/$key" ]; then
        echo "[backup] skip (done): $src"
        continue
    fi

    wait_alive || { echo "[backup] ABORT: device unreachable; nothing marked done. Re-run to resume."; exit 1; }

    if ! $ADB -s "$target" shell "[ -e '$src' ]" 2>/dev/null; then
        # Only trust an "absent" verdict if the device is still answering.
        if alive; then
            echo "[backup] genuinely absent: $src"; touch "$STAMP/$key"
        else
            echo "[backup] transport dropped while checking $src -- not marking done"; fail=1
        fi
        continue
    fi

    echo "[backup] pulling $src ..."
    out="$DEST${src#/sdcard}"
    mkdir -p "$(dirname "$out")"
    # Pull into the PARENT, not into "$out" itself: `adb pull SRC DEST` places SRC *inside*
    # DEST when DEST already exists, which silently produces DCIM/Stories/Stories on a re-run.
    if $ADB -s "$target" pull -a "$src" "$(dirname "$out")/"; then
        touch "$STAMP/$key"          # stamped ONLY after a pull that actually succeeded
        echo "[backup] done: $src"
    else
        echo "[backup] FAILED: $src"
        fail=1
    fi
done

# Loose files sitting directly in /sdcard (CVs, .docx assignments, PDFs).
if [ ! -e "$STAMP/loose_files" ]; then
    echo "[backup] pulling loose files in /sdcard root ..."
    mkdir -p "$DEST/_root_files"
    $ADB -s "$target" shell 'ls -1p /sdcard/ | grep -v "/$"' 2>/dev/null | tr -d '\r' | \
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        $ADB -s "$target" pull -a "/sdcard/$f" "$DEST/_root_files/" >/dev/null 2>&1 \
            && echo "    + $f" || echo "    ! failed: $f"
    done
    touch "$STAMP/loose_files"
fi

echo
echo "[backup] size on disk: $(du -sh "$DEST" 2>/dev/null | cut -f1)"
echo "[backup] file count:   $(find "$DEST" -type f 2>/dev/null | wc -l)"
[ "$fail" = 0 ] && echo "[backup] COMPLETE" || echo "[backup] COMPLETED WITH FAILURES (re-run to retry)"
exit $fail
