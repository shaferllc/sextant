# Sextant

*Sextant — the navigator's instrument for taking a precise sight.*

A tiny menu bar utility in the spirit of CrossHair: one shortcut throws a
fullscreen crosshair through your pointer, another opens a circular pixel
loupe beside it. No Dock icon, no windows in your way — press the key, take
your sight, press it again.

## Features

- **Crosshair (⌥⌘X)** — a hairline through the pointer spanning every screen.
  Click-through, works over fullscreen apps and all Spaces, follows the mouse.
  Optional live coordinate readout (screen points, top-left origin).
  Configurable color, opacity, and thickness.
- **Loupe (⌥⌘L)** — a circular magnifier floating beside the pointer, showing
  the pixels under it at 2–32× (default configurable, `+` / `−` to change on
  the fly). At high zoom it draws a pixel grid, outlines the pixel under the
  pointer, and shows its hex color beneath — click the loupe or press ⌘C to
  copy the hex. `esc` dismisses it.
- Both toggles also live in the menu bar menu, alongside Settings.
- Settings persist as JSON in `~/Library/Application Support/Sextant/`.
- Dependency-free: SwiftUI + AppKit + Carbon hotkeys + ScreenCaptureKit.

## Build

```
./make-app.sh
```

Builds a release binary, generates the icon, assembles `Sextant.app`, and
installs it to /Applications.

## Permissions

- **Screen Recording** — required by the **loupe only**. macOS treats reading
  the pixels around your pointer (via ScreenCaptureKit) as screen recording.
  The first toggle prompts you; if access is missing, Sextant shows an
  explainer with a button straight to the right pane of System Settings. You
  may need to relaunch Sextant after granting.
- The **crosshair needs no permissions at all**, and the global shortcuts use
  Carbon hotkeys, so no Accessibility access is needed either.

## Not yet

- The shortcuts are fixed at ⌥⌘X and ⌥⌘L (no recorder UI).
- Loupe `+` / `−` / `⌘C` keys work while the loupe has focus (it takes focus
  when opened); clicking the loupe itself always copies.
