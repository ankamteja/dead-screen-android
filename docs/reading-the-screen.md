# Reading a screen you cannot see

Three channels can tell you what is on a dead phone's display. They fail in different places, which
is the whole point — when one goes dark, the next still answers.

| Channel | Tool | Gives you | Blocked by |
|---|---|---|---|
| Framebuffer | `screencap`, scrcpy | pixels | `FLAG_SECURE` (returns solid black) |
| Accessibility tree | `s25-tap.sh` | **text** + bounds | a window that never goes idle |
| View hierarchy | `s25-views.sh` | ids, classes, bounds | nothing, in practice |

Work down the table. `s25-tap.sh` is the tool you want, because only it reads labels — you can ask
for `"Use PIN"` by name instead of counting pixels. Drop to `s25-views.sh` when it fails.

## When `uiautomator` returns nothing

```
ERROR: could not get idle state.
```

`uiautomator` waits for the window to stop changing before it will dump. A screen with an animation
that never ends — a rotating one-time-code countdown, an indeterminate spinner, a looping progress
bar — never reaches that state, so the dump never comes.

Two details make this nastier than it reads:

- **It exits 0 anyway.** `uiautomator dump out.xml && do-something-with out.xml` looks like it
  succeeded and quietly operates on a file that was never written. Check for the file, not the
  exit code.
- **Turning animations off does not help.** Zeroing all three of `window_animation_scale`,
  `transition_animation_scale` and `animator_duration_scale` has no effect here — those scale
  *transition* animations, while the offending redraw is the app's own timer.

Sometimes the way out is simply a different screen. An app's settings subscreen usually has no
animated widget, so if it is reachable, `s25-tap.sh` starts working again the moment you get there.

## The fallback: `dumpsys activity top`

The window's view hierarchy can be printed straight from the activity manager. It does not wait for
idleness and it does not care about `FLAG_SECURE`:

```bash
./s25-views.sh                  # every visible view of the focused app
./s25-views.sh -c               # clickable only
./s25-views.sh toolbar          # filter by id or class
./s25-views.sh -p com.some.app  # a package that is not the focused one
```

```
  * menu_overflow                    144x144  at 936,115    tap 1008,187   ActionMenuItemView
  * account_row                     1080x240  at 0,301      tap 540,421    ConstraintLayout
```

Then `adb shell input tap 1008 187`.

What you lose is text: the hierarchy carries no strings. What saves you is that resource ids are
named by developers for developers — `menu_account_settings`, `action_chevron_right_icon`,
`scanQrCodeButton` — and a named id is very often enough to identify a control with confidence.

### Bounds are relative to the parent

This is the part that makes a naive reading of `dumpsys` output wrong. Each view prints as

```
Class{hash flags flags left,top-right,bottom #id app:id/name}
```

and those coordinates are **relative to its parent**, not to the screen. A toolbar button at
`0,12-144,156` is not in the top-left corner; it is 12px down from a toolbar that is itself
offset inside an app bar that is offset inside a content frame. Absolute position is the running
sum of every ancestor's origin, which is why `s25-views.sh` walks the indentation with a stack and
adds each parent's offset as it descends. Its output is already absolute.

Cross-check when both channels work: for a screen `s25-tap.sh` can read, the two tools should
agree on tap coordinates to the pixel.

### Knowing where you are

`dumpsys activity top` also names the Fragment currently attached:

```bash
adb shell dumpsys activity top | grep -A2 'Added Fragments:'
```

Inside a single-activity app this is a far better "where am I" signal than `mCurrentFocus`, which
keeps saying the same activity name through every screen of the app. Watch it change as you tap
and you can navigate blind with real confidence.

Note the same null-line trap documented for `isKeyguardShowing` applies to `mCurrentFocus`: several
lines are printed and the first is often `null`, so filter nulls before taking one.

## What still cannot be read

Terminal emulators, canvas apps, games and video draw their content rather than composing it from
views. None of the three channels sees inside them: `screencap` may work if the app is not secure,
but neither the accessibility tree nor the view hierarchy has any text to give you. For a terminal
specifically, the answer is not to read the screen at all — see
[A Linux shell on the phone](termux-shell.md), which skips the display entirely.
