# Hydronium OKLab utilities

`hydronium/oklab-utils` is a portable, dependency-free color-value library.
It provides opaque sRGB, OKLab, and OKLCH values plus deterministic conversion,
gamut mapping, mixing, and contrast helpers. It is designed to be shared by
terminal, browser, and server renderers.

```sh
moon add hydronium/oklab-utils
```

```lua
local color = require("hydronium_oklab_utils")

local accent = color.oklch(0.72, 0.18, 310)
local rgb = color.to_srgb(accent) -- { r = 214, g = 124, b = 255 }
```

Values are ordinary immutable-by-convention Lua tables. This package performs
math in Lua because UI color conversion is inexpensive and portability matters;
renderers cache lowered values at their own boundary.

## Contrast

Two contrast metrics are provided. `contrast(a, b)` is the WCAG 2 ratio
(1..21). `lc(text, bg)` is APCA-W3 (0.0.98G-4g) lightness contrast, signed
and generally the better instrument for small/bold UI text and for dark
backgrounds, where WCAG 2 is known to be miscalibrated. Both are evaluated
on the same final, gamut-mapped, rounded 8-bit sRGB `to_srgb` produces --
i.e. what a renderer actually paints, not the requested (possibly
out-of-gamut) color.

```lua
local color = require("hydronium_oklab_utils")

-- Pick legible text for a background, then push it to a real target if it
-- falls short (hue/chroma preserved; chroma is shed only as a last resort).
local text = color.readable_on(bg)
local fg, achieved = color.ensure_contrast(text, bg, 60) -- APCA Lc >= 60
```

- `readable_on(bg, opts?)` -- the more legible of `opts.candidates` (default
  near-black/near-white) on `bg`, judged by `|lc|`.
- `ensure_contrast(fg, bg, target, opts?)` -- binary-searches `fg`'s OKLCH
  lightness (and, only if that can't reach `target`, its chroma) toward
  whichever of black/white raises contrast against `bg`. `opts.metric` is
  `"apca"` (default) or `"wcag"`. Always returns a color and the score it
  actually achieves, even when `target` is unreachable.

**Usage example**: `hydronium/cli`'s filter-bar chips
(`cli/src/ui/search_bar.lua`, see its own "CHIP COLOR DERIVATION" comment)
are the reference example of composing these two calls into a real UI
element -- deriving a chip's background/text pair from a hue, separating it
from the real detected terminal background
(`hydronium_ink.terminal_background`, OSC 11) when needed, and guaranteeing
the text clears APCA's floor for small/bold text. All chip-specific policy
(which hue, which target) lives in that program, not in this package.
