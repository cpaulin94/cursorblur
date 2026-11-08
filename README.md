# cursorblur

Real-time motion blur for the macOS mouse cursor — runs at your display's refresh rate (120 Hz on ProMotion).

A single-file AppKit app (`cursorblur.swift`, ~400 lines, no Xcode project) that draws interpolated, fading copies of the current system cursor along its recent path, in a transparent click-through overlay on every screen.

## Quick start

```bash
git clone https://github.com/cpaulin94/cursorblur.git && cd cursorblur && ./build.sh run
```

Build commands:

```bash
./build.sh run          # build and launch from the terminal
./build.sh run --hide   # same, with the real cursor hidden (blur only)
./build.sh app          # build build/cursorblur.app (universal: Apple silicon + Intel)
./build.sh release      # build, sign, notarize (if configured) and zip for distribution
```

To install as a regular app: `./build.sh app && cp -R build/cursorblur.app /Applications/`.
From the app's menu you can enable **Launch at login**.

### Signed releases

`./build.sh release` signs ad-hoc by default. With an Apple Developer ID it produces a
notarized, stapled zip that opens on any Mac without Gatekeeper warnings:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=your-notarytool-profile \
./build.sh release
```

Settings and Quit live in the **◐** menu bar icon.

**Requirements:** macOS 14+, Xcode Command Line Tools (`xcode-select --install`).
No Accessibility permission needed — it only reads `NSEvent.mouseLocation`.

## Settings

| Setting | What it does |
|---|---|
| Strength | Overall opacity of the blur |
| Trail length (frames) | How far back the trail reaches, in display frames |
| Samples | Number of cursor copies drawn along the trail |
| Head bias | Weights opacity toward the newest position |
| Movement threshold (pt) | Below this movement no blur is drawn |
| Hide real cursor | Shows only the blurred trail |
| Launch at login | Starts cursorblur automatically (app bundle only) |

Settings persist in `UserDefaults`.

## How it works

- One borderless, transparent `NSWindow` per screen at `.cursorWindow` level, `ignoresMouseEvents = true`, joined to all Spaces.
- A `CADisplayLink` (`NSView.displayLink`, macOS 14+) ticks at the screen refresh rate, sampling the mouse position into a short history.
- The view draws N copies of `NSCursor.currentSystem` (respecting its hot spot) interpolated along that history, invalidating only the dirty rect.
- "Hide real cursor" uses the private `CGSSetConnectionProperty("SetsCursorInBackground")` + `CGDisplayHideCursor`, with balanced hide counts so the cursor is always restored on Quit, SIGINT/SIGTERM and app termination.

## Roadmap

- Notarized binary on GitHub Releases / Homebrew cask
- Metal renderer for very high sample counts

## License

MIT — see [LICENSE](LICENSE).
