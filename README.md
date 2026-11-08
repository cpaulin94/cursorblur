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

The menu shows a live preview of the current settings, a small diagram next to each
slider, and how much latency each one adds.

| Setting | What it does | Added pointer latency |
|---|---|---|
| Strength | Opacity of the trail | 0 ms |
| Trail length | How many past frames are smeared (1 frame = 8.3 ms at 120 Hz) | 0 ms. The trail covers past motion; the pointer itself is not delayed |
| Samples | Copies drawn per frame: smoother trail, more GPU work | 0 ms |
| Head bias | Fades the trail toward its tail | 0 ms |
| Movement threshold | Movements below this draw no trail | 0 ms |
| Hide real cursor | Shows only the cursor drawn by cursorblur | **1–2 frames** (≈ 8–17 ms at 120 Hz, 17–33 ms at 60 Hz) |
| Launch at login | Starts cursorblur automatically (app bundle only) | — |

Why only one setting adds latency: macOS draws the real cursor on a dedicated hardware
layer, updated at scan-out. Everything cursorblur draws goes through a normal window,
which the compositor shows on the next frame or the one after. With the real cursor
visible, that delay only affects the trail behind it. With the real cursor hidden, the
cursor you see is cursorblur's, so the delay applies to the pointer itself.

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
