#!/bin/bash
# Shared device-selection logic. Sourced by the other scripts; not run directly.
#
# The device serial is deliberately NOT hardcoded. Resolution order:
#   1. $S25_SERIAL
#   2. ~/.config/s25-serial
#   3. the only USB device adb can see (the common case)
#
# Serials are device identifiers, so keeping them out of the scripts means this
# repo carries no hardware fingerprint of whoever runs it.

ADB="${ADB:-$(command -v adb || echo /usr/bin/adb)}"
PORT="${PORT:-5555}"
SERIALFILE="${SERIALFILE:-$HOME/.config/s25-serial}"

# All non-network devices in state "device" -- i.e. plugged in and authorized.
s25_usb_serials() {
    $ADB devices 2>/dev/null | awk '$2=="device" && $1 !~ /:[0-9]+$/ {print $1}'
}

# Resolve the USB serial, or print nothing if it can't be determined.
s25_serial() {
    if [ -n "${S25_SERIAL:-}" ]; then echo "$S25_SERIAL"; return; fi
    if [ -r "$SERIALFILE" ]; then
        local s; s=$(tr -d ' \r\n' < "$SERIALFILE")
        [ -n "$s" ] && { echo "$s"; return; }
    fi
    # Exactly one candidate is unambiguous; more than one is not, so refuse to guess.
    local list; list=$(s25_usb_serials)
    [ "$(printf '%s\n' "$list" | grep -c .)" = 1 ] && echo "$list"
}

s25_wifi_target() {
    $ADB devices 2>/dev/null | awk -v p=":$PORT" '$1 ~ p && $2=="device"{print $1}' | head -1
}

# Pick a transport: USB first (far faster and more stable), else an existing Wi-Fi
# connection. Prints the adb target, or nothing.
s25_target() {
    local serial; serial=$(s25_serial)
    if [ -n "$serial" ] && [ "$($ADB devices | awk -v s="$serial" '$1==s{print $2}')" = "device" ]; then
        echo "$serial"; return
    fi
    s25_wifi_target
}

s25_no_device_msg() {
    cat <<EOF
[s25] no authorized device found.
      Plug in the USB cable and check:  $ADB devices -l
      If it says "unauthorized", tap Allow on the phone.
      If you have several devices attached, pick one:
          echo <serial> > $SERIALFILE
EOF
}
