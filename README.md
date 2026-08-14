# headless-android

Use an Android phone whose screen is dead — mirror, control, unlock and back it up from a Linux
laptop over one USB-C cable.

A phone with a broken panel is not a broken phone. The display *controller* still composites
every frame; only the glass stopped showing them. `adb` and `scrcpy` can pull those frames out.
These scripts wrap that into something you can actually live on: the mirror opens by itself when
you plug in, survives the USB dropouts a damaged port produces, and gets you past the lock screen
even though **the lock screen is invisible in the mirror** (see [Why the lock screen is
black](#why-the-lock-screen-is-black)).

Tested on a Galaxy S25 (`SM-S931B`, Android 16) with Fedora 43 and scrcpy 4.1.

## Requirements

- `adb` (Fedora: `sudo dnf install android-tools`)
- [scrcpy](https://github.com/Genymobile/scrcpy) — **not packaged for Fedora** (absent from the
  Fedora repos, RPM Fusion and Flathub), so use the upstream prebuilt:

  ```bash
  curl -LO https://github.com/Genymobile/scrcpy/releases/download/v4.1/scrcpy-linux-x86_64-v4.1.tar.gz
  curl -LO https://github.com/Genymobile/scrcpy/releases/download/v4.1/SHA256SUMS.txt
  sha256sum -c SHA256SUMS.txt --ignore-missing     # verify before extracting
  tar xzf scrcpy-linux-x86_64-v4.1.tar.gz
  ```

  Extract it next to these scripts, or point `$SCRCPY` at your own binary.
- USB debugging enabled on the phone. If the screen is already dead and you have never enabled it,
  see [Enabling USB debugging blind](#enabling-usb-debugging-blind).

No device serial is hardcoded. With one phone attached everything auto-detects; with several, run
`echo <serial> > ~/.config/s25-serial` or set `$S25_SERIAL`.

## Scripts

| Script | What it does |
|---|---|
| `s25.sh` | open the mirror — USB if authorized, else Wi-Fi |
| `s25-unlock.sh` | type the PIN over adb, with no video involved |
| `s25-watch.sh` | keep a mirror open whenever the phone is connected; relaunch when it drops |
| `s25-backup.sh` | resumable pull of shared storage to `~/s25-backup` |
| `s25-common.sh` | shared device selection (sourced, not run) |

### Mirroring

```bash
./s25.sh
```

Mouse clicks act as finger taps, the laptop keyboard types directly, audio and clipboard sync
both ways.

| Command | What it does |
|---|---|
| `./s25.sh` | auto: USB, else Wi-Fi |
| `./s25.sh wifi` | force Wi-Fi (rides out a flaky cable) |
| `./s25.sh off` | mirror with the phone's own panel powered down |
| `./s25.sh virtual` | mirror a *new virtual display* — never blanks, works even while the phone's screen is off or proximity-blanked during a call |
| `MOUSE=uhid ./s25.sh` | true pointer on the phone (release it with left Alt) |

In-window keys — MOD is left Alt or left Super:
`MOD+f` fullscreen · `MOD+n` notifications · `MOD+s` app switcher ·
`MOD+o` phone panel off · `MOD+Shift+o` panel on · drag an APK onto the window to install it

**`--mouse=sdk` is the default on purpose.** `uhid` gives the phone a real pointer, but it *grabs*
the cursor inside the window — the window then feels impossible to leave or close unless you know
that left Alt releases it. `sdk` keeps a normal cursor whose clicks land as taps.

### Auto-open on plug-in

`s25-watch.sh` polls for the phone, opens the mirror, and relaunches it if it dies. It tells a
deliberate close (clean exit after a decent run — then it waits for a real replug) apart from a
crash (exponential backoff, capped at 30s). Install it as a user service:

```bash
cp systemd/s25-mirror.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now s25-mirror
```

This matters more than it sounds. A phone with a damaged USB port re-enumerates constantly —
`WARN: Device disconnected`, and the mirror is simply gone. The supervisor makes that a two-second
flicker instead of something you have to notice and fix.

### Backup

```bash
./s25-backup.sh
```

Pulls to `~/s25-backup`. Re-runnable: each folder is stamped in `.done/` on success and skipped
next time, so an interruption costs one subfolder rather than the whole transfer. Big trees
(`DCIM`, `Android/media`) are expanded per-subfolder for the same reason. Use USB — roughly
200 MB/s versus 3 MB/s over congested 2.4GHz Wi-Fi.

`Android/data` and `Android/obb` are skipped (app sandboxes `adb` mostly cannot read, dominated by
regenerable cache). `Android/media` is **included** — that is where WhatsApp keeps its media on
Android 11+.

Verify against the phone rather than trusting exit code 0:

```bash
for d in DCIM Download Pictures Recordings Movies Music Documents; do
  printf "%-12s phone=%s laptop=%s\n" "$d" \
    "$(adb shell "find /sdcard/$d -type f 2>/dev/null | wc -l" | tr -d '\r')" \
    "$(find ~/s25-backup/$d -type f 2>/dev/null | wc -l)"
done
```

## Why the lock screen is black

Android marks the lock screen a secure surface. `adb exec-out screencap` returns an all-black PNG
there — which is well known — but **scrcpy's capture is blocked too**, and that is much less
obvious because scrcpy does not use `screencap`. Recording the mirror at the bouncer produces a
solid black 1080x2340 frame with nothing on it but a stray back-chevron.

So on a phone with a dead panel you get a perfect catch-22: you cannot see the PIN pad in the
mirror, and you cannot see it on the phone either.

`s25-unlock.sh` sidesteps it by never touching video:

```bash
./s25-unlock.sh            # prompts for the PIN
PIN=1234 ./s25-unlock.sh   # or pass it in
```

It wakes the phone (`KEYCODE_WAKEUP`), swipes the shade away, **verifies the bouncer is actually
focused before sending a single digit**, types, then re-checks. Last line is the verdict —
`OK: unlocked`, `already unlocked`, `could not raise the PIN pad`, or `still locked -- wrong PIN?`.

Two things make this work where a naive version doesn't:

- **The bouncer ignores `input text`.** Digits must be sent as raw keycodes:
  `KEYCODE_0=7 … KEYCODE_9=16`, so keycode = digit + 7, then `66` for Enter.
- **Check `isKeyguardShowing`, never `mCurrentFocus`.** This phone prints several `mCurrentFocus`
  lines and the first is `null`, so a `grep -m1` reports "unlocked" while the device is very much
  locked. That exact bug made the first version of the script a silent no-op.

  ```bash
  adb shell dumpsys window | grep -m1 isKeyguardShowing     # true = locked
  ```

## Tapping buttons you cannot see

`FLAG_SECURE` blocks screen *capture*, not the **accessibility tree**. When an app renders as a
black rectangle in the mirror, its buttons are still fully readable — with exact pixel bounds —
through `uiautomator`. That's the same channel a screen reader uses.

```bash
./s25-tap.sh                 # list every labelled element and where it is
./s25-tap.sh "Use PIN"       # tap the one matching that text
./s25-tap.sh -c              # clickable elements only
./s25-tap.sh -a "Unlock"     # tap the first match instead of stopping on ambiguity
```

Matching is case-insensitive substring. On multiple distinct matches it lists them and **stops
rather than guessing** — tapping the wrong button on a payments screen isn't a recoverable
mistake. Labels repeated at the same coordinates (a node and its parent) collapse to one entry.

This is what gets you through app locks on a dead panel. A real example — PhonePe, which blanks
its lock screen: the sequence is an invisible *"Unlock now"* button, then the system biometric
prompt, then an invisible *"Use PIN"*, and only then a credential screen that accepts keycodes.
None of it is visible in the mirror; all of it is visible to `s25-tap.sh`.

Note that **app-drawn PIN pads ignore `input keyevent` entirely** — they're custom views, not text
fields. Only the *system* credential screen takes keycodes. For an app keypad you must tap
coordinates.

The dump can contain whatever is on screen, so the script deletes it from both the phone and the
laptop on exit, and `*ui*.xml` is gitignored.

### Unattended unlocking

```bash
echo <your-pin> > ~/.config/s25-pin && chmod 600 ~/.config/s25-pin
mkdir -p ~/.config/systemd/user/s25-mirror.service.d
printf '[Service]\nEnvironment=AUTO_UNLOCK=1\n' > ~/.config/systemd/user/s25-mirror.service.d/auto-unlock.conf
systemctl --user daemon-reload && systemctl --user restart s25-mirror
```

Nothing writes that PIN file for you. Note `AUTO_UNLOCK=1 systemctl --user restart ...` does *not*
work — the variable never reaches the unit, which is why the drop-in exists.

Worth doing even with `svc power stayon true` set: stayon only prevents the *next* lock. If the
phone is already locked when you plug in, you still get a black window on first connect unless
something unlocks it.

## Connection problems

```bash
adb devices -l          # what's connected and in what state
```

- **`unauthorized`** → the phone is showing an "Allow USB debugging?" dialog. Tap Allow and tick
  "Always allow from this computer". If no dialog appears, unplug and replug.
- **Nothing listed** → phone is off the bus. Check `lsusb -d 04e8:` (04e8 = Samsung). Try another
  C-to-C cable; charge-only cables and worn ports produce exactly this.
- **The mirror dies by itself** → look for `WARN: Device disconnected`. That is re-enumeration, not
  a software fault. `s25.sh wifi` rides it out; `s25-watch.sh` recovers from it.
- **Window is black** → almost certainly the lock screen. See above.
- **`no permissions`** → add a udev rule and reload:

  ```
  # /etc/udev/rules.d/51-android.rules
  SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0660", TAG+="uaccess"
  ```

  `TAG+="uaccess"` grants the logged-in seat access by ACL — the modern replacement for the
  obsolete `plugdev` group. **Do not "fix" this with `sudo adb start-server`:** that server
  presents `/root/.android/adbkey`, so the phone's "always allow" grant attaches to the root key
  while your normal `adb` presents `~/.android/adbkey`, and the device silently reverts to
  `unauthorized` with no visible cause.

## Wireless

Two different mechanisms, and the difference matters:

- `adb tcpip 5555` + `adb connect <ip>:5555` — works immediately, but **does not survive a phone
  reboot**. After a restart nothing listens on 5555.
- `adb pair <ip>:<port> <code>` from Settings → Developer options → Wireless debugging — persistent
  across reboots, but needs a pairing code read off the phone's screen.

```bash
adb tcpip 5555
adb shell ip -4 addr show wlan0 | grep -oP 'inet \K[0-9.]+'   # the phone's IP
adb connect <that-ip>:5555
```

`adb tcpip` restarts adbd and **re-triggers the RSA prompt on both transports** — tick "Always
allow from this computer" or USB reverts to `unauthorized`.

Note Fedora's `adb` is built **without mDNS**, so `adb mdns services` fails and wireless devices
cannot be auto-discovered. Read the IP off the phone or learn it over USB, as above.

Wi-Fi is slower and jitterier than USB, so `s25.sh` auto-tunes for it: `--max-size=1024`,
4 Mbps, 30 fps, no audio. Downscaling is by far the biggest latency win — fewer bits means less
time queued behind other traffic on the air.

## Enabling USB debugging blind

If the panel died *before* you ever enabled it, the phone can still be driven by ear. Touch
usually still works even with no image.

1. Wake, swipe up, type the PIN by muscle memory.
2. Turn on **TalkBack** — "Hi Bixby, turn on TalkBack", or hold Volume Up + Volume Down for 3
   seconds (only if that shortcut is bound; One UI often ships it unbound, so try voice first).
   Swipe right/left to move focus, **double-tap to activate**, two-finger swipe to scroll,
   swipe down-then-left for Back.
3. Settings → About phone → Software information → **Build number**, activate 7 times. TalkBack
   announces the countdown ("You are now 3 steps away from being a developer") — the only feedback
   this step ever gives. Confirm TalkBack actually reads "Build number" before tapping, or you will
   tap seven times into nothing and get no error.
4. Settings → Developer options → **USB debugging**. Confirm TalkBack says "USB debugging" before
   activating — **OEM unlocking sits in the same list and is a data-wipe path**.
5. Plug in, then accept the RSA dialog with "Always allow from this computer" ticked.

Two things that are easy to get wrong:

- **Do not reboot the phone.** Android blocks USB data entirely until the first unlock after boot.
  If the phone is currently past that point, a reboot moves it somewhere strictly worse.
- **"Charging only" does not block adb.** ADB is a separate USB function from MTP, so the Default
  USB configuration setting is irrelevant. Leave it alone.

## What cannot be done this way

- **Samsung Secure Folder.** It is Knox user 150 with its own encryption — `/storage/emulated/150`,
  `/data/user/150` and `/data/media/150` are all `Permission denied` to adb's uid, and root would
  need a bootloader unlock, which wipes the device. Knowing the Secure Folder password does not
  help: it unlocks the UI, not the filesystem to another user. The only route is opening Secure
  Folder on the device and using **"Move out of Secure Folder"**, then re-running the backup.
- **Video capture without adb.** DisplayPort Alt Mode sends the phone's screen *out*, but a laptop's
  USB-C and HDMI ports are sources, not sinks — a laptop cannot receive video. That route needs a
  USB-C→HDMI adapter plus a UVC capture card.
- **Samsung DeX for PC** (Windows/macOS only, tethered PC mode discontinued) and **Phone Link**
  (needs Windows).

## License

MIT — see [LICENSE](LICENSE).
