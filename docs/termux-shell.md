# A Linux shell on the phone

`adb shell` already gives you *a* shell, but a deliberately poor one: it runs as uid 2000 with
Android's stripped toolbox, no package manager, and no writable prefix. Termux supplies a real
userland — `bash`, `apt`, `git`, `python`, `openssh`, ~2000 packages — without root.

The catch is that Termux is an ordinary unprivileged app, so all of that lives in
`/data/data/com.termux/files`, which uid 2000 cannot read. `run-as` bridges the gap, and
`s25-shell.sh` wraps the whole thing:

```bash
./s25-shell.sh                      # interactive bash on the phone
./s25-shell.sh 'apt update'         # run one command, print output, exit
./s25-shell.sh 'uname -a; df -h'    # ...or several
```

Put it on `$PATH` if you use it often — the script resolves symlinks, so this works:

```bash
ln -s "$PWD/s25-shell.sh" ~/.local/bin/s25
s25 'echo hello from the phone'
```

No mirror, no video, no phone screen involved. This is the most useful thing in this repo when the
panel is fully dead: a phone you can `ssh`-feel your way around from a laptop terminal.

## Installing Termux

Termux is **not on Play** in any usable form — the Play build was abandoned in 2020 because Play's
policies are incompatible with an app that installs its own packages. Take the GitHub release.

```bash
# Pick the arch that matches:  adb shell getprop ro.product.cpu.abi
V=0.119.0-beta.3
BASE=https://github.com/termux/termux-app/releases/download/v$V
curl -LO "$BASE/termux-app_v$V%2Bapt-android-7-github-debug_arm64-v8a.apk"
curl -L "$BASE/termux-app_v$V%2Bapt-android-7-github-debug_sha256sums" | grep arm64
sha256sum termux-app_*_arm64-v8a.apk      # compare the two by eye before installing
```

Two variants ship per architecture: `apt-android-7` (Android 7+) and `apt-android-5`. Take
`apt-android-7` on anything modern.

### Play Protect will block it, and the usual flag does not help

The install fails with **"Unsafe app blocked — this app was built for an older version of
Android"**, because Termux targets an old API level on purpose (targeting a current one would cost
it the ability to execute files in its own data directory). The dialog offers only *OK* and *More
details*, and **there is no "Install anyway" button** — expanding *More details* just adds a
sentence.

`adb install --bypass-low-target-sdk-block` does **not** fix this. That flag defeats the *platform's*
low-target-SDK check; the block you are hitting is Play Protect's, a separate gate.

What works is turning off Play Protect's scan of adb-side installs for the length of the install
and putting it straight back:

```bash
adb shell settings get global package_verifier_user_consent      # note the value first

adb shell settings put global package_verifier_user_consent -1
adb shell settings put global verifier_verify_adb_installs 0

adb install -r termux-app_*_arm64-v8a.apk

adb shell settings put global package_verifier_user_consent 1    # restore, immediately
adb shell settings put global verifier_verify_adb_installs 1
```

**Restore both.** Left off, every future adb-side install skips malware scanning — a much larger
hole than the one you opened to get one known-good APK on. Verify with `settings get` rather than
assuming.

### First run

Launch it once so it can unpack its bootstrap (needs network, takes a few seconds):

```bash
adb shell monkey -p com.termux -c android.intent.category.LAUNCHER 1
```

Three prompts appear, none of them visible if the panel is dead — drive them with `s25-tap.sh`:

| Prompt | Answer |
|---|---|
| "Android app compatibility" (debuggable build) | `./s25-tap.sh "Don't show again"` |
| "Allow Termux to send you notifications?" | `./s25-tap.sh -a "Allow"` — say yes; the notification is what keeps a session alive |
| Terminal appears | done |

Confirm the bootstrap landed:

```bash
adb shell 'run-as com.termux ls files/usr/bin | wc -l'    # a few hundred
```

### Stop Android killing your sessions

Android 12+ reaps "phantom processes" — child processes an app spawns that the system did not
account for, which is precisely what a shell does every time you run anything. Long jobs die at
seemingly random points.

```bash
adb shell settings put global settings_enable_monitor_phantom_procs false
```

This survives until a factory reset on most devices, but not always across major OS upgrades —
recheck it if background jobs start dying again.

## How `s25-shell.sh` works

```bash
run-as com.termux sh -c 'export PREFIX=/data/data/com.termux/files/usr
                         export LD_LIBRARY_PATH=$PREFIX/lib
                         export PATH=$PREFIX/bin:$PATH
                         exec bash -l'
```

`run-as` re-executes as the app's own uid, which is what makes its data directory readable. The
three exports are not optional: Termux binaries are dynamically linked against Termux's own libc
and expect Termux's prefix, so without `LD_LIBRARY_PATH` even `ls` fails to load.

For an interactive session the wrapper adds `adb shell -t`, which allocates a pty — without it
you get a shell with no job control, no line editing and no prompt.

### The one requirement: a debuggable build

`run-as` only works on apps built debuggable, and **the GitHub APKs are** (`github-debug` is right
there in the filename). The F-Droid and Play builds are release-signed, and on those `run-as`
refuses:

```
run-as: package not debuggable: com.termux
```

So if you ever "upgrade" Termux by installing it from F-Droid, this shell stops working and the
script tells you why. Nothing else about Termux changes — only this back door.

If you would rather not depend on that, run `sshd` inside Termux and reach it over the cable.
`s25-ssh.sh` does the whole dance:

```bash
./s25-ssh.sh              # a shell on the phone
./s25-ssh.sh -t           # attach the long-lived tmux session instead
./s25-ssh.sh 'uptime'     # run one command and exit
./s25-ssh.sh -u           # force the USB tunnel
```

It tries Wi-Fi first and falls back to the cable. When the phone is reachable on the network there
is no reason to tunnel, and going direct means the cable can come out entirely -- which is worth
something on a phone kept plugged in purely for adb, since a battery held at charge all day is a
battery aging for no reason. Discovery order is `$S25_HOST`, then the address cached in
`~/.cache/s25-ip`, then asking the phone over USB while it is still attached and caching the
answer for later. "Reachable" means something is listening on port 8022, not that the host
answers ping -- a phone with no sshd running is not usable, and finding that out immediately beats
a 30-second timeout.

Two things decide whether the Wi-Fi path works at all, and neither is about the phone:

- **Client isolation.** Many guest, campus and hotel networks stop clients talking to each other,
  and then only the USB tunnel works. Test with a ping in either direction before assuming.
- **A DHCP lease that moves.** The cached address goes stale on reconnect; plug in once and the
  script re-learns it. A DHCP reservation on your own router avoids this permanently.

Note the phone's sshd listens on every interface, so on a shared network the port is visible to
every other host on it. Key-only auth is what makes that acceptable -- there is no password to
guess. Do not undo `PasswordAuthentication no`.

### Why it tunnels rather than dialling the phone directly

There is usually no route to the phone's port 8022. Campus and office Wi-Fi isolate clients from
each other, mobile data puts you behind CGNAT, and the address changes every time it reconnects
anyway. `adb forward tcp:8022 tcp:8022` sidesteps all of that by carrying the connection over the
USB cable that is already attached, so it works on any network and on none.

The forward is state held by the adb connection, not by the phone, so **it disappears on every
replug** and `ssh` then fails with `connection refused` — which looks alarming and only means the
tunnel is gone. Re-adding it is most of what the wrapper does; it also starts `sshd` if it is not
running, and pins the host key to an alias per device so that two phones do not both claim to be
`localhost:8022` and read as a man-in-the-middle attack on each other.

### Setting it up

Use a key, not a password — `sshd` on a phone is a listening service, and a password is the one
thing worth not having on it:

```bash
# from the laptop, with the phone attached
base64 -w0 ~/.ssh/id_ed25519.pub | \
  xargs -I{} ./s25-shell.sh "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
    echo {} | base64 -d > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

./s25-shell.sh 'sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" \
                $PREFIX/etc/ssh/sshd_config'
./s25-shell.sh 'pkg install -y openssh tmux'
./s25-ssh.sh 'echo it works'
```

Note the base64 detour. A key pushed with a plain `echo 'ssh-ed25519 AAAA...'` arrives mangled:
the text crosses your shell, `adb`'s, and the phone's, and the `\n` is eaten on the way, leaving a
file `sshd` silently ignores. Anything multi-line — this key, a config file, a boot script — should
travel as base64 and be decoded on the far side. Verify with `md5sum` on both ends rather than
trusting that it looked fine.

Heredocs fail the same trip, and more loudly:

```
sh: can't create temporary file /data/local/shXXXX.tmp: Permission denied
```

### Surviving a reboot

Termux:Boot runs anything in `~/.termux/boot/` after the phone starts. Install it from the same
GitHub release channel as Termux itself — **the signatures must match or it cannot talk to
Termux** — then launch it once, which is what clears Android's "stopped" flag and lets the app
receive `BOOT_COMPLETED` at all.

```bash
~/.termux/boot/start-lab.sh
```
```sh
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock                                    # or Android suspends the CPU mid-job
sshd
tmux has-session -t lab 2>/dev/null || tmux new-session -d -s lab
```

Keep both apps out of Doze while you are at it:

```bash
adb shell dumpsys deviceidle whitelist +com.termux
adb shell dumpsys deviceidle whitelist +com.termux.boot
```

**Do not casually reboot to test this on a phone with a dead panel.** Android blocks USB data until
the first unlock after boot, and an unlock script cannot run without adb — so a reboot costs you
every remote route into the phone until someone unlocks it by touch. Verify the receiver is armed
instead, which is checkable without rebooting:

```bash
adb shell dumpsys package com.termux.boot | grep -E 'RECEIVE_BOOT_COMPLETED: granted|stopped='
```

`granted=true` and `stopped=false` together mean the broadcast will be delivered.

## Everyday use

```bash
s25 'pkg upgrade -y'
s25 'pkg install -y git python nano'
```

Shared storage (`/sdcard`) is not readable until you grant it. On Android 13+ the permission that
actually matters is `MANAGE_EXTERNAL_STORAGE`, and it is an **appop**, not a runtime permission —
`pm grant` fails on it:

```bash
adb shell appops set --uid com.termux MANAGE_EXTERNAL_STORAGE allow
s25 'ls /sdcard/DCIM'
```

`termux-setup-storage`, which creates the tidy `~/storage/dcim` style symlinks, wants to raise a
permission dialog and so does nothing useful when called from `s25-shell.sh` with no one at the
screen. The appop above is the headless equivalent; just use `/sdcard` paths directly.

`$HOME` is `/data/data/com.termux/files/home`. It is private app storage, so it survives reboots
but is **erased when the app is uninstalled** — keep anything you care about in `/sdcard` or pull
it to the laptop with `adb pull`.
