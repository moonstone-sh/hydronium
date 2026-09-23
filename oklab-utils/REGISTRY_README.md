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
