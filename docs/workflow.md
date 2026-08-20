# The whole workflow, end to end

How a phone with a dead panel goes from "brick in a drawer" to "headless Linux box you ssh into",
and — more usefully — *why each step is the step*. Read this when something breaks and you need to
know which layer to poke.

The chain is five layers. Each one only works if the one under it does, so when something fails,
walk down until a layer answers, and the fault is the layer above it.

```
5. services      sshd, tmux, Termux:Boot        -- work survives disconnects and reboots
4. shell         run-as + Termux                -- a real userland, no root
3. control       input tap / input keyevent     -- act on what you found
2. sight         3 ways to read the screen      -- find what to act on
1. transport     adb over USB or Wi-Fi          -- everything rides on this
```

## Layer 1 — transport

```bash
adb devices -l
```

`device` means you are in. `unauthorized` means the phone is showing an RSA prompt that you cannot
see — replug and accept it blind, or fix it from a machine whose key it already trusts. Nothing
listed at all is a cable or port problem, not a software one.

Two facts shape everything above this layer:

- **A reboot costs you the phone.** Android refuses USB data until the first unlock after boot, and
  every remote tool here needs USB data. On a phone you cannot see, a reboot means no adb, no
  mirror, no shell, until somebody unlocks it by touch and muscle memory. Treat rebooting as an
  operation with a real cost, not a first-line fix.
- **Wi-Fi via `adb tcpip 5555` does not survive a reboot either**, for the same reason plus the
  daemon restarting. Only a real `adb pair` does, and that needs a code you would have to read off
  the screen.

## Layer 2 — sight

Three channels can tell you what is on screen, and they fail in different places. Try them in
this order; the first that answers is the most useful, because only it gives you *text*.

| Channel | Tool | Gives | Dies on |
|---|---|---|---|
| Framebuffer | `screencap`, scrcpy | pixels | `FLAG_SECURE` → solid black |
| Accessibility tree | `s25-tap.sh` | **labels** + bounds | a window that never idles |
| View hierarchy | `s25-views.sh` | ids + bounds | little in practice |

```bash
./s25-tap.sh            # everything labelled on screen, and where
./s25-views.sh -c       # fallback: clickable views by resource id
```

The failure signatures are worth memorising, because two of them lie:

- An all-black `screencap` (~15 KB PNG) is **not** a dead display. It is `FLAG_SECURE`. The lock
  screen, banking apps and authenticators all do this, and scrcpy is blocked too — the mirror shows
  black even though the phone is composing frames perfectly.
- `ERROR: could not get idle state.` means an animation on screen never stops, so `uiautomator`
  never dumps. **It exits 0 anyway**, so a `dump && read` chain quietly reads nothing. Check for the
  file, not the exit code.
- `dumpsys` bounds are **relative to the parent view**. Read them as absolute and every tap lands
  somewhere wrong. `s25-views.sh` already resolves this; raw `dumpsys` output does not.

## Layer 3 — control

```bash
adb shell input tap <x> <y>          # coordinates from either sight tool
adb shell input keyevent 8 16 11 14  # digits: keycode = digit + 7; 66 = Enter
adb shell input swipe x1 y1 x2 y2 <ms>
```

What accepts what is not obvious, and guessing wastes a lot of time:

- The **system** credential screen (lock screen, "enter your PIN to continue") takes keycodes, and
  **ignores `input text` entirely**.
- **App-drawn keypads** take neither. They are custom views, so you must tap coordinates.
- A long-press is `input swipe x y x y 900` — the same point, held.

Verify where you are before and after every step. Inside a single-activity app `mCurrentFocus`
barely changes, so the better oracle is the fragment:

```bash
adb shell dumpsys activity top | grep -A2 'Added Fragments:'
```

And when checking the lock: use `isKeyguardShowing`, never `mCurrentFocus` — several focus lines
get printed and the first is often `null`, so a `grep -m1` cheerfully reports "unlocked" on a
locked phone.

### The pattern that makes blind operation safe

Every action is *find → verify → act → verify*. Never fire a tap at a remembered coordinate: an
extra dialog, a different layout, a scrolled list, and the tap lands on something else entirely.
`s25-tap.sh` enforces the important half of this by **refusing to act when a label matches more
than one place on screen** — an ambiguous match on a payments or credential screen is not a
recoverable mistake.

Screens whose text you cannot read at all (`s25-views.sh` gives ids, not words) deserve more care,
not less: confirm the fragment changed after each tap, and stop if it did not.

## Layer 4 — a real shell

`adb shell` is uid 2000 with Android's stripped toolbox. Termux is a full userland — but it lives
in private app storage that uid 2000 cannot read, so:

```bash
./s25-shell.sh 'uname -a'    # run-as com.termux + Termux's own PREFIX/LD_LIBRARY_PATH/PATH
```

Two constraints define this layer:

- **`run-as` only works on a debuggable build.** Termux's GitHub APKs are; F-Droid and Play builds
  are not. Reinstall from elsewhere and this door closes — the script says so rather than failing
  obscurely.
- **Play Protect blocks the install** as "built for an older version of Android", with no "Install
  anyway" button, and `adb install --bypass-low-target-sdk-block` does *not* help: that flag
  defeats the platform's own check, which is a different gate. See
  [termux-shell.md](termux-shell.md) for the verification-toggle route, and put the setting back
  when you are done.

**Anything multi-line must travel as base64.** Text crosses your shell, adb's, and the phone's;
`\n` gets eaten and heredocs die on `can't create temporary file /data/local/...: Permission
denied`. Pipe `base64 -w0` in, decode on the far side, and compare `md5sum` on both ends.

## Layer 5 — services

```bash
./s25-ssh.sh -t     # forward + ssh + attach tmux, in one
```

Three pieces, each solving a specific way that "it worked when I set it up" stops being true:

- **`adb forward`** because there is no route to the phone otherwise — client isolation, CGNAT, and
  a changing address. It tunnels over the cable. It is also **per adb connection**, so it vanishes
  on replug and ssh then says `connection refused`.
- **tmux** because an ssh session dies with the cable. A job started inside tmux does not.
- **Termux:Boot + `termux-wake-lock`** because Android suspends the CPU and kills what it calls
  phantom processes. Also: `settings put global settings_enable_monitor_phantom_procs false`.

Termux:Boot must be **launched once by hand** — Android never delivers broadcasts to an app in the
"stopped" state, so an installed-but-never-opened Termux:Boot silently does nothing forever. Check
it without rebooting:

```bash
adb shell dumpsys package com.termux.boot | grep -E 'RECEIVE_BOOT_COMPLETED: granted|stopped='
```

`granted=true` **and** `stopped=false` together mean it will fire.

## Debugging: which layer is broken?

Work down until something answers.

| Symptom | Check | Usual cause |
|---|---|---|
| `connection refused` on ssh | `adb forward --list` | forward gone after replug |
| ssh asks for a password | `authorized_keys` on the phone | key arrived mangled — resend as base64 |
| `run-as: package not debuggable` | which APK is installed | Termux replaced with a release build |
| Mirror is black | `dumpsys window \| grep isKeyguardShowing` | locked, or a `FLAG_SECURE` screen |
| `could not get idle state` | — | animated screen; use `s25-views.sh` |
| Taps do nothing | `dumpsys activity top` fragment | screen changed under you; re-find the target |
| Everything is dead at once | `adb devices` | cable, or the phone rebooted |

## Hygiene

The tooling touches a lot that should never leave the machine, so:

- Serials, PINs and IPs live in `~/.config/` and `~/.cache/`, never in the repo. `.gitignore`
  covers `s25-pin`, `s25-serial` and `*ui*.xml`; `tests/run.sh` greps for identifiers on every run.
- Accessibility dumps contain **whatever was on screen** — messages, balances, one-time codes.
  `s25-tap.sh` deletes them from both machines on exit. Keep it that way.
- Turning off Play Protect's verification is a hole for the length of one install, not a setting to
  leave off. `settings get global package_verifier_user_consent` should read `1` when you finish.
