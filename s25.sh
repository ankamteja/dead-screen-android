#!/bin/bash
# Galaxy S25 (broken panel) -> full control on this laptop.
# Usage:  ~/tools/scrcpy/s25.sh            auto-pick transport (USB first, then Wi-Fi)
#         ~/tools/scrcpy/s25.sh wifi       force Wi-Fi
#         ~/tools/scrcpy/s25.sh off        mirror with the phone's own panel powered off
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/s25-common.sh"

SCRCPY="${SCRCPY:-$HERE/scrcpy-linux-x86_64-v4.1/scrcpy}"
export ADB

# --- find the phone -----------------------------------------------------------
SERIAL="$(s25_serial)"
usb_state()  { [ -n "$SERIAL" ] && $ADB devices | awk -v s="$SERIAL" '$1==s{print $2}'; }
wifi_target() { s25_wifi_target; }

target=""
if [ "${1:-}" != "wifi" ] && [ "$(usb_state)" = "device" ]; then
    target="$SERIAL"
    echo "[s25] using USB"
else
    target="$(wifi_target)"
    if [ -z "$target" ]; then
        # Not connected yet. If USB is up, learn the IP from it; else try the last known one.
        ip=""
        [ -n "$(usb_state)" ] && ip=$($ADB -s "$SERIAL" shell ip -4 addr show wlan0 2>/dev/null \
                                      | grep -oP 'inet \K[0-9.]+')
        [ -z "$ip" ] && ip=$(cat "$HOME/.cache/s25-ip" 2>/dev/null)
        if [ -z "$ip" ]; then
            echo "[s25] no phone found. Plug in USB, or read the IP off"
            echo "      Settings > Developer options > Wireless debugging and run:"
            echo "      $ADB connect <ip>:$PORT"
            exit 1
        fi
        $ADB connect "$ip:$PORT" >/dev/null 2>&1
        sleep 2
        target="$(wifi_target)"
        [ -z "$target" ] && { echo "[s25] connect to $ip:$PORT failed (phone asleep? new IP? WARP VPN?)"; exit 1; }
    fi
    echo "[s25] using Wi-Fi ($target)"
fi

# remember the IP for next time
case "$target" in *:*) mkdir -p "$HOME/.cache"; echo "${target%:*}" > "$HOME/.cache/s25-ip";; esac

# --- launch -------------------------------------------------------------------
# mouse=sdk: the cursor stays a normal laptop cursor and clicks act like finger taps.
#   Deliberately NOT uhid -- uhid grabs the pointer inside the window, which makes the
#   window feel impossible to leave or close unless you know the release key.
#   Run `MOUSE=uhid ~/tools/scrcpy/s25.sh` if you ever want a true pointer on the phone
#   (release it with left Alt or left Super).
# keyboard=uhid: real key layout from the laptop keyboard, and it suppresses the phone's
#   on-screen keyboard -- which is what you want when the panel is dead.
opts=(
  -s "$target"
  --window-title="Galaxy S25"
  --keyboard=uhid
  --mouse="${MOUSE:-sdk}"
  --gamepad=uhid           # controllers pass through
  --stay-awake             # never sleeps while connected
)

# Auto-tune for the transport. Wi-Fi here is a congested 2.4GHz campus AP
# (~9ms RTT with ~5ms jitter), so we trade resolution and audio for responsiveness:
# fewer bits to push means less time queued behind other traffic on the air.
case "$target" in
  *:*)  # Wi-Fi
    opts+=(
      --max-size=1024        # 1080x2340 -> 473x1024; the single biggest latency win
      --video-codec="${CODEC:-h264}"   # h265 halves the bits; try CODEC=h265 on a busy link
      --video-bit-rate=4M
      --max-fps=30
      --no-audio             # drops a second stream and its sync buffer
    )
    ;;
  *)    # USB - plenty of bandwidth, keep it sharp
    opts+=(--video-bit-rate=16M --max-fps=60)
    ;;
esac

[ "${1:-}" = "off" ] && opts+=(--turn-screen-off)

# `s25.sh virtual` -- mirror a NEW virtual display instead of the phone's physical one.
# This is the answer to "the mirror goes black when the phone's screen turns off":
# a virtual display is composited independently, so it keeps rendering no matter what
# the real panel is doing -- including while the proximity sensor blanks the screen
# during a call. Trade-off: it is a separate workspace, not a view of the phone's own
# home screen, so apps have to be launched inside it. Calls and notifications still
# appear on the physical display.
if [ "${1:-}" = "virtual" ]; then
    opts+=(--new-display=1080x2340/420)
    # keep the size/codec tuning but this display is ours, so no --max-size clamp fight
fi

exec "$SCRCPY" "${opts[@]}"
