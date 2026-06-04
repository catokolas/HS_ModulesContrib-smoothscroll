--- === hs._ckol.smoothscroll ===
---
--- Native scroll-output helper for Hammerspoon. Posts trackpad-style
--- gesture CGEvents (NSEventTypeScrollWheel + NSEventTypeGesture pair)
--- from a `CVDisplayLink` callback, so receiving apps recognise the
--- input as a two-finger gesture and run their own scroll-view
--- momentum.
---
--- Designed as the output side of `MouseScrollTweaks.spoon`: the
--- Spoon owns the eventtap and per-tick decision logic; this module
--- owns CGEvent posting. Bypasses the macOS discrete-wheel pipeline
--- entirely, which is why apps' native glide-to-stop feel actually
--- shows up here instead of being defeated by receiver discard.
---
--- See README.md for tuning parameters and limitations (notably:
--- NSTableView / Finder list don't respond to gesture-typed events).

local module = require("hs._ckol.smoothscroll.internal")

return module
