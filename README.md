# cursorblur

Real-time motion blur for the macOS mouse cursor — runs at your display's refresh rate (120 Hz on ProMotion).

A single-file AppKit app (`cursorblur.swift`, ~400 lines, no Xcode project) that draws interpolated, fading copies of the current system cursor along its recent path, in a transparent click-through overlay on every screen.

## Quick start

```bash
git clone https://github.com/cpaulin94/cursorblur.git && cd cursorblur && ./build.sh run
```

Options:

```bash
./build.sh run          # build and launch
./build.sh run --hide   # launch with the real cursor hidden (blur only)
```

Settings and Quit live in the **◐** menu bar icon.

**Requirements:** macOS 14+, Xcode Command Line Tools (`xcode-select --install`).
No Accessibility permission needed — it only reads `NSEvent.mouseLocation`.

## Settings

| Setting | What it does |
|---|---|
| Samples | Number of cursor copies drawn along the trail |
| Strength | Overall opacity of the blur |
| Head bias | Weights opacity toward the newest position |
| Min distance | Movement threshold below which no blur is drawn |
| Frames | Length of the trail, in display frames |
| Hide real cursor | Shows only the blurred trail |

Settings persist in `UserDefaults`.

## How it works

- One borderless, transparent `NSWindow` per screen at `.cursorWindow` level, `ignoresMouseEvents = true`, joined to all Spaces.
- A `CADisplayLink` (`NSView.displayLink`, macOS 14+) ticks at the screen refresh rate, sampling the mouse position into a short history.
- The view draws N copies of `NSCursor.currentSystem` (respecting its hot spot) interpolated along that history, invalidating only the dirty rect.
- "Hide real cursor" uses the private `CGSSetConnectionProperty("SetsCursorInBackground")` + `CGDisplayHideCursor`, with balanced hide counts so the cursor is always restored on Quit, SIGINT/SIGTERM and app termination.

## Roadmap

- Launch at login
- Signed & notarized `.app` bundle / Homebrew cask
- Metal renderer for very high sample counts

## License

MIT — see [LICENSE](LICENSE).
