# hs._ckol.smoothscroll

Native Hammerspoon helper that turns discrete mouse-wheel ticks into
continuous-scroll CGEvents — same `IsContinuous=1` event shape macOS
trackpads emit during their continuous-scroll mode, with smoothly
decreasing per-frame deltas during the momentum tail. Receiving apps
(browsers, AppKit content + list views, Finder, terminals) treat the
stream as one logical scroll, so a single wheel click produces one
visible scroll step with the same magnitude in every app.

Designed as the output side of
[`MouseScrollTweaks.spoon`](https://github.com/catokolas/HS_SpoonsContrib/tree/main/MouseScrollTweaks.spoon).
The Spoon's eventtap handles input + cancellation; this module owns
output: per-vsync CGEvent posting from a `CVDisplayLink` callback.

## What it actually does

For each wheel tick the module:

1. Adds `pxStepSize` to a per-axis buffer, with two-level acceleration:
   a per-tick burst multiplier (compounds while ticks stay within
   `tickGap`) and a fast-scroll multiplier that kicks in after
   `fastSwipeThresh` consecutive bursts.
2. Starts (or continues) a `CVDisplayLink`.
3. Each vsync frame, drains the buffer at `buf / msPerStep · dtMs` and
   feeds the raw per-frame px through a **biased point-delta sub-
   pixelator** (per axis):
   - First emit of a gesture rounds *up* to ±1 even when the accumulated
     point delta is fractional, so a tiny slow click still produces one
     event with delta ±1.
   - Subsequent emits use signed floor — events only post when the
     accumulator crosses ±1, so we don't over-emit one event per
     animator frame for sub-pixel motion.
4. When the buffer empties and `gestureEndGapMs` has passed since the
   last tick, transitions to a **`DragCurve` momentum tail**: each
   frame computes the diff-of-distance from the closed-form drag
   solution (`v'(t) = -dragCoefficient · v^dragExponent`) and feeds
   that through the same subpixelator. When velocity drops below
   `stopSpeed`, the display link stops.

All events posted are type 22 (`NSEventTypeScrollWheel`) with
`IsContinuous=1` and the standard delta variants (line / point / FixedPt
16.16 fractional). No per-event phase markers or companion gesture
events — the entire gesture + momentum sequence is one continuous
scroll stream from the receiver's point of view.

## Lua API

```lua
local link = require("hs._ckol.smoothscroll")

link.configure({
  -- Input shaping (per-tick + burst + fast-scroll multipliers)
  pxStepSize       = 1,
  acceleration     = 1.75,
  tickGap          = 0.13,
  swipeGap         = 0.35,
  swipeTickThresh  = 2,
  fastSwipeThresh  = 3,
  fastFactor       = 1.2,
  fastBase         = 1.15,
  -- Buffer drain rate
  msPerStep        = 90,
  -- When buffer empty AND last tick was this long ago, momentum starts
  gestureEndGapMs  = 80,
  -- DragCurve momentum: v'(t) = -dragCoefficient * v^dragExponent
  dragCoefficient  = 0.023,      -- 1/ms — half-life ≈ 30 ms
  dragExponent     = 1.0,        -- 1.0 = exponential; 2.0 = v² decay
  stopSpeed        = 0.03,       -- px/ms — momentum cutoff (~30 px/s)
  -- Output composition
  linePx           = 10,         -- px per emitted line delta
  invertedFromDevice = 0,        -- NSEvent.directionInvertedFromDevice
  sentinel         = 0xC0DE5C01, -- stamped on kCGEventSourceUserData
})

link.tick(dirX, dirY)            -- enqueue one wheel tick (±1 / 0)
link.cancel()                    -- drop in-flight gesture + momentum
link.stop()                      -- tear down the display link
```

`tick(0, 0)` is a no-op. Vertical wheel = `link.tick(0, ±1)`;
tilt-wheel horizontal = `link.tick(±1, 0)`.

## Install without compiling (pre-built universal binary)

Each release ships a `smoothscroll-<version>-macos-universal.zip`
containing a fat `internal.so` (arm64 + x86_64) plus `init.lua`,
built against `-mmacosx-version-min=13.0`. Pull the latest release
artifact and unzip straight into `~/.hammerspoon`:

```bash
# 1. Download (replace <version> with whatever's current on the Releases page).
curl -L -o smoothscroll.zip \
  https://github.com/catokolas/HS_ModulesContrib-smoothscroll/releases/latest/download/smoothscroll-<version>-macos-universal.zip

# 2. macOS may quarantine a downloaded .so; clear the flag so dlopen accepts it.
xattr -dr com.apple.quarantine smoothscroll.zip 2>/dev/null || true

# 3. Unzip into ~/.hammerspoon. The archive's top-level is hs/, so this
#    lands at ~/.hammerspoon/hs/_ckol/smoothscroll/.
unzip -o smoothscroll.zip -d ~/.hammerspoon

# 4. Quit and relaunch Hammerspoon (Reload Config will NOT pick up a fresh .so).
#    Then verify in the Console:
#      require("hs._ckol.smoothscroll")
```

If `dlopen` still complains about the quarantine after step 2, repeat
the `xattr` after step 3 on the unpacked `.so`:
`xattr -dr com.apple.quarantine ~/.hammerspoon/hs/_ckol/smoothscroll`.

## Build & install from source

```bash
cd smoothscroll
make install       # copies into ~/.hammerspoon/hs/_ckol/smoothscroll/
# or for development:
make link          # symlinks instead, so future `make` picks up automatically
```

Then **quit and relaunch Hammerspoon** (Reload Config does not refresh
native modules — already-loaded `.so` files stay pinned in
`package.loaded`).

To produce a release artifact (universal binary zip) yourself:

```bash
cd smoothscroll
VERSION=0.1
make dist $VERSION     # → dist/smoothscroll-0.1-macos-universal.zip
```

If you have access - publish the artifact as a GitHub Release with the
[`gh`](https://cli.github.com) CLI:

```bash
# From the repo root (the parent of the `smoothscroll/` subdir):
gh release create v$VERSION \
  dist/smoothscroll-$VERSION-macos-universal.zip \
  --title "v$VERSION" \
  --notes "Initial release. Universal arm64 + x86_64 binary built against macOS 13.0+."
```

This creates the git tag `v0.1`, drafts a release named "v0.1" on
GitHub, and attaches the zip as a downloadable asset. The
`curl https://.../releases/latest/download/...` URL in the
install-without-compiling section above resolves to whatever the most
recent release uploads.

To remove an installed copy:

```bash
make uninstall
```

## What's here

```
smoothscroll/
├── smoothscroll/
│   ├── init.lua          # Lua loader
│   ├── internal.m        # CVDisplayLink + biased-subpixelator engine
│   ├── Makefile          # build + make link / make install / make dist
│   └── docs.json         # (placeholder)
├── LICENSE               # MIT
└── README.md             # this file
```

## Acknowledgments

The macOS scroll-event mechanics this module exercises — posting
`NSEventTypeScrollWheel` CGEvents with `IsContinuous=1`, the biased
line-delta rounding observed in real trackpad events, the
`DragCurve`-shaped momentum tail — were studied by reading the
open-source [mac-mouse-fix](https://github.com/noah-nuebling/mac-mouse-fix)
codebase. This module is a from-scratch reimplementation of the
underlying ideas, not a port of MMF source:

- `internal.m` was written against the macOS public APIs
  (`CGEventCreate`, `CGEventSetIntegerValueField`, `CGEventPost`,
  `CVDisplayLink`). No source files were copied from MMF.
- The CGEvent field numbers and per-frame event shape were
  reverse-engineered from observable trackpad-event traces and
  cross-referenced with `CGEventTypes.h` — both are macOS API
  surface, not MMF-specific contributions.
- The biased point-delta sub-pixelator, the `b = 1` / `b = 2` /
  `b = 0.7` DragCurve specialisations, and the per-tick buffer-drain
  emission model are well-known numerical techniques applied here in
  this module's own architecture.

MMF is licensed under the [MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
(a custom non-MIT license that restricts redistribution of source
code copied from MMF). Because no MMF source is copied or
distributed here, that license does not apply to this module.

If this module is useful to you and you haven't already, consider
[supporting mac-mouse-fix](https://github.com/noah-nuebling/mac-mouse-fix#Support-Me)
— the documentation and source code that made the underlying scroll
mechanics legible owe a great deal to its author's ongoing work.

## License

MIT — see [LICENSE](LICENSE).
