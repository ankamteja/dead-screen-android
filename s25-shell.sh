#!/bin/bash
# A Linux shell on the phone, from this terminal -- no phone screen needed.
#
# Termux is a normal unprivileged app, so its userland lives in a private data
# dir that `adb shell` (uid 2000) cannot read. `run-as` is the way in: it drops
# to the app's uid, and it works because the Termux build installed here is the
# GitHub debug-signed one. A Play/F-Droid release build would refuse, and this
# script with it.
#
#   ./s25-shell.sh                 interactive bash inside Termux
#   ./s25-shell.sh 'pkg upgrade'   run one command, print output, exit
set -u

# Resolve through symlinks so this can live on PATH as e.g. ~/.local/bin/s25.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
. "$HERE/s25-common.sh"

PKG=com.termux
FILES=/data/data/$PKG/files

target="$(s25_target)"
[ -z "$target" ] && { s25_no_device_msg; exit 1; }

if ! $ADB -s "$target" shell "run-as $PKG true" >/dev/null 2>&1; then
    echo "[shell] run-as refused for $PKG."
    echo "        Either Termux is not installed, or the installed build is not debuggable."
    echo "        Reinstall the GitHub debug APK:  adb install -r termux-app_*_arm64-v8a.apk"
    exit 1
fi

# Termux binaries are dynamically linked against its own libs and expect its own
# PREFIX. Without these three exports even `ls` fails to load.
env_setup="export PREFIX=$FILES/usr HOME=$FILES/home; \
export LD_LIBRARY_PATH=\$PREFIX/lib; \
export PATH=\$PREFIX/bin:\$PATH; \
export TERM=${TERM:-xterm-256color} LANG=en_US.UTF-8; \
cd \$HOME;"

if [ $# -gt 0 ]; then
    $ADB -s "$target" shell "run-as $PKG sh -c '$env_setup $*'"
else
    echo "[shell] Termux on $target -- exit or Ctrl-D to leave"
    $ADB -s "$target" shell -t "run-as $PKG sh -c '$env_setup exec bash -l'"
fi
