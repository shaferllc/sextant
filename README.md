# Sextant

*Sextant — the navigator's instrument for taking a precise sight.*

A tiny menu bar utility for measuring, aligning, and reading the screen: a
fullscreen crosshair through your pointer, a circular pixel loupe beside it, a
ruler you drag across any two points, sticky guides, a layout grid, and a
freeze that holds a menu still while you take your sight. No Dock icon, no
windows in your way — press the key, take your sight, press it again.

## The instruments

- **Crosshair (⌥⌘X)** — a hairline through the pointer spanning every screen.
  Click-through, works over fullscreen apps and all Spaces, follows the mouse.
  Solid or dashed, with an optional gap around the pointer so you can see what
  you're aiming at, and a live coordinate readout (screen points, top-left
  origin).
- **Loupe (⌥⌘L)** — a circular magnifier floating beside the pointer, showing
  the pixels under it at 2–32× (`+` / `−` to change on the fly). At high zoom
  it draws a pixel grid, outlines the sampled square, and shows its colour
  beneath — click the loupe or press ⌘C to copy. `esc` dismisses it.
- **Measure (⌥⌘M)** — drag between any two points, on one screen or across
  several, for a live `width × height`, the diagonal, and the angle. `⇧`
  constrains to horizontal, vertical, or 45°; `⌘C` copies the numbers; `G`
  turns the measurement into guides; `esc` puts the ruler away.
- **Guides (⌥⌘G, clear with ⌥⇧⌘G)** — drop a crossed pair wherever the pointer
  is. They stay where you left them across screens and across launches, and the
  crosshair and the ruler snap onto them.
- **Layout grid (⌥⌘R)** — columns, gutters, margins, and a baseline rhythm laid
  over every screen, so you can hold a design up against the running app.
- **Freeze (⌥⌘F)** — pins a still of every display on top of the live screen.
  Menus, tooltips, and hover states hold still long enough to measure or pick a
  colour from. While frozen the loupe reads out of the still, so it is exact
  and costs nothing. Click anywhere, or press the key again, to thaw.
- **Palette (⌥⌘P)** — the last 24 colours you copied, in a floating window.
  Click a swatch to copy it, and export the set as your chosen format, CSS
  custom properties, a SwiftUI `Color` extension, or JSON.

## Reading colour

While the loupe is open:

| Key | What |
| --- | ---- |
| `+` / `−` | Zoom, 2× → 32× |
| `[` / `]` | Sample square: 1 px exact, or a 3/5/11 px average |
| `F` | Cycle the copy format |
| `X` | Park the current colour, then read the live WCAG contrast against it |
| `←` `↑` `→` `↓` | Nudge the pointer one device pixel (`⇧` for ten) |
| `⌘C` or click | Copy the colour |
| `esc` | Close the loupe |

Seven copy formats: hex, `rgb()`, `hsl()`, bare components, float components, a
SwiftUI `Color(...)`, and an AppKit `NSColor(...)`. The contrast readout gives
the ratio and the WCAG grade (AAA / AA / AA Large / Fail) as you move, which is
the fastest way to find out whether that grey passes.

## Settings

Five tabs: crosshair, loupe, grid, shortcuts, general. **Every global shortcut
is rebindable** — click the field, press the keys — and Sextant can launch at
login. Settings, guides, and the palette persist as plain JSON in
`~/Library/Application Support/Sextant/`.

Dependency-free: SwiftUI + AppKit + Carbon hotkeys + ScreenCaptureKit.

## Build

```
./make-app.sh
```

Builds a release binary, generates the icon, assembles `Sextant.app`, and
installs it to /Applications.

## Permissions

- **Screen Recording** — required by the **loupe** and the **freeze** only.
  macOS treats reading the pixels around your pointer (via ScreenCaptureKit) as
  screen recording. The first toggle prompts you; if access is missing, Sextant
  shows an explainer with a button straight to the right pane of System
  Settings. You may need to relaunch Sextant after granting.
- The **crosshair, guides, grid, and ruler need no permissions at all**, and the
  global shortcuts use Carbon hotkeys, so no Accessibility access is needed
  either.

## Not yet

- The loupe's one-key controls work while the loupe has focus (it takes focus
  when opened); clicking the loupe itself always copies.
- Guides can be cleared all at once but not dragged after they're dropped.
- The grid is a single configuration, not a set of saved presets.
