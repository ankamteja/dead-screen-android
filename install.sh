#!/bin/bash
# Set up the auto-open service, wherever this repo happens to live.
#
# The systemd unit needs an absolute path to s25-watch.sh, so it cannot ship as a
# working file -- it gets templated here from wherever you cloned to.
#
#   ./install.sh            check dependencies, install and enable the service
#   ./install.sh --check    check dependencies only, change nothing
#   ./install.sh --no-enable  install the unit but do not start it
#   ./install.sh --uninstall  stop, disable and remove the unit
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/s25-mirror.service"

say()  { printf '  %s\n' "$*"; }
good() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '  \033[31mERROR\033[0m %s\n' "$*"; exit 1; }

mode="install"
case "${1:-}" in
    --check)     mode="check" ;;
    --no-enable) mode="no-enable" ;;
    --uninstall) mode="uninstall" ;;
    "")          ;;
    *)           die "unknown option: $1 (try --check, --no-enable, --uninstall)" ;;
esac

if [ "$mode" = "uninstall" ]; then
    systemctl --user disable --now s25-mirror.service 2>/dev/null
    rm -f "$UNIT"
    rm -rf "$UNIT_DIR/s25-mirror.service.d"
    systemctl --user daemon-reload
    good "removed $UNIT"
    say "Your scripts and backups were left alone."
    exit 0
fi

echo "checking:"

command -v adb >/dev/null || die "adb not found. Fedora: sudo dnf install android-tools"
good "adb $(adb version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1)"

command -v python3 >/dev/null || die "python3 not found (needed by s25-tap.sh)"
good "python3 $(python3 -V 2>&1 | awk '{print $2}')"

# Either bundled next to the scripts, or on PATH, or pointed at by $SCRCPY.
scrcpy_bin=""
for cand in "${SCRCPY:-}" "$HERE"/scrcpy-linux-*/scrcpy "$(command -v scrcpy 2>/dev/null)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && { scrcpy_bin="$cand"; break; }
done
if [ -n "$scrcpy_bin" ]; then
    good "scrcpy $("$scrcpy_bin" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1) ($scrcpy_bin)"
else
    warn "scrcpy not found -- mirroring will not work until you install it."
    say "It is not packaged for Fedora; see the README for the verified prebuilt."
fi

if systemctl --user show-environment >/dev/null 2>&1; then
    good "systemd user session"
else
    warn "no systemd user session -- the auto-open service will not work here."
    say "You can still run ./s25.sh, ./s25-unlock.sh and ./s25-tap.sh by hand."
fi

case "$(adb devices | awk 'NR>1 && NF {print $2; exit}')" in
    device)       good "a device is attached and authorized" ;;
    unauthorized) warn "device attached but UNAUTHORIZED -- tap Allow on the phone" ;;
    *)            say  "no device attached right now (fine -- the service waits for one)" ;;
esac

[ "$mode" = "check" ] && { echo; say "check only, nothing changed."; exit 0; }

echo
echo "installing:"

mkdir -p "$UNIT_DIR"
# Written from scratch rather than copied, so the ExecStart path matches this clone.
cat > "$UNIT" <<EOF
[Unit]
Description=Auto-open the phone mirror whenever the device is connected
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=$HERE/s25-watch.sh
Restart=always
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
good "wrote $UNIT"
say "ExecStart=$HERE/s25-watch.sh"

systemctl --user daemon-reload
if [ "$mode" = "no-enable" ]; then
    good "installed but not enabled (systemctl --user enable --now s25-mirror)"
else
    systemctl --user enable --now s25-mirror.service 2>/dev/null \
        && good "enabled -- the mirror will open by itself when you plug in" \
        || warn "could not enable the service; try: systemctl --user enable --now s25-mirror"
fi

echo
say "Optional: unlock the phone automatically on every connect."
say "  echo <your-pin> > ~/.config/s25-pin && chmod 600 ~/.config/s25-pin"
say "  mkdir -p $UNIT_DIR/s25-mirror.service.d"
say "  printf '[Service]\\nEnvironment=AUTO_UNLOCK=1\\n' > $UNIT_DIR/s25-mirror.service.d/auto-unlock.conf"
say "  systemctl --user daemon-reload && systemctl --user restart s25-mirror"
