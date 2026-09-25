# Hydronium Ink

`hydronium/ink` renders Hydronium trees in a terminal. Its Yoga
backed `Box` layout, styled `Text`, and input hooks run on LuaJIT.

```sh
moon add hydronium/ink
```

The package resolves `hydronium/core` and projects the matching native
Yoga library into the Moonstone environment. Supported targets are arm64 and
x86-64 macOS, plus glibc Linux. Windows is not supported.

## A counter

`render.render()` mounts the root and owns the terminal event loop. It returns
when `useApp().exit()` runs or when Ctrl-C ends the app.

```lua
local h = require("hydronium")
local ink = require("hydronium_ink")
local render = require("hydronium_ink.render")
local hooks = require("hydronium_ink.hooks")

local function Counter()
  local count, set_count = h.signal(0)
  local app = hooks.useApp()

  hooks.useInput(function(input)
    if input == "+" then
      set_count(count() + 1)
    elseif input == "q" then
      app.exit()
    end
  end)

  return function()
    return ink.Box({ borderStyle = "single", paddingX = 1 },
      ink.Text({ color = "cyan", bold = true }, "Count: " .. count()),
      ink.Newline(),
      ink.Text({ dimColor = true }, "+ to increment, q to quit")
    )
  end
end

render.render(h.h(Counter))
```

Run it through Moonstone:

```sh
moon exec -- luajit app.lua
```

The repository includes a [small LUAX demo](../examples/ink_demo/) and an
[interactive todo application](../examples/ink_todo/). The todo is the fuller
example of `useInput`, `useApp`, `useWindowSize`, `Box`, `Spacer`, and
`Newline` working together.

## API

| Module | API | Use |
| --- | --- | --- |
| `hydronium_ink` | `Box`, `Text`, `Newline`, `Spacer`, `Transform` | Terminal intrinsic descriptors. |
| `hydronium_ink.render` | `render(element, opts?)` | Mounts an app and runs its blocking event loop. `opts.exitOnCtrlC` defaults to `true`; `opts.writeFn` replaces the default sink; `opts.altScreen` starts in the terminal's alternate screen buffer. |
| `hydronium_ink.session` | `create(element, opts?)` | Non-blocking in-memory driver with `dispatch`, `write`, `paste`, `resize`, `step`, `frame`, `cursor`, `status`, and `close`. Used by deterministic interaction tests and `hydronium/ink-lab`. |
| `hydronium_ink.hooks` | `useInput`, `usePaste`, `useApp`, `useWindowSize` | Keyboard, bracketed paste, app exit, and reactive terminal size. |
| `hydronium_ink.hooks` | `useFocus`, `useFocusManager`, `useCursor`, `useBoxMetrics`, `useAnimation` | Focus traversal, cursor placement, measured layout, and timed updates. |
| `hydronium_ink.hooks` | `useAltScreen` | Enter/leave the alternate screen buffer (DECSET 1049) at runtime, for a fullscreen view. `render()` always leaves it on the way out, including on an error. |
| `hydronium_ink.hooks` | `useColorProfile` | Reactive `"truecolor"\|"ansi256"\|"ansi16"\|"none"` -- see "Color profile" below. |
| `hydronium_ink` | `colorProfile`, `byProfile`, `adaptive` | Plain (non-hook) profile lookup, and per-profile prop values -- see "Color profile" below. |

`Box` supports Yoga flexbox properties such as `flexDirection`, `justifyContent`,
`alignItems`, `flexGrow`, `padding`, `margin`, `width`, `height`, and
`borderStyle = "single"`. A `Box` with `overflow = "scroll"` is a controlled
viewport: set `scrollTop` and/or `scrollLeft` from application state, normally
updated by `useInput`; `useBoxMetrics(ref)` reports the effective and maximum
offsets after layout. `Text` supports `color`, `backgroundColor`, `bold`,
`dimColor`, `italic`, `underline`, `strikethrough`, `inverse`, and fixed-width
truncation with `width` plus `wrap = "truncate"`, `"truncate-start"`,
`"truncate-middle"`, or `"truncate-end"`; `wrap = "wrap"` and `"hard"`
perform word and hard reflow respectively. `Transform` receives a plain line
and may return it with standard SGR styling; Ink parses that into its normal
styled cell grid.

## Color capability

Palette names such as `"red"`, `"brightBlue"`, and `"default"` refer to the
user's live terminal palette. Absolute `"#RRGGBB"` values and
`hydronium_oklab_utils.oklab`/`oklch` values use sRGB and lower at the render
boundary. Choose a target when predictable output matters:

```lua
render.render(app, { color = "truecolor" }) -- or ansi256, ansi16, auto
```

`auto` reads conventional `COLORTERM` and `TERM` hints. It defaults to ANSI-16
when no capability is known. Alpha is deliberately unsupported: terminal cells
cannot blend reliably against an unknown background.

Hooks belong in the setup call of a component, before it returns its render
function. `useInput` and focus activation options are read at setup time.
They do not rerun reactively when those options change.

## Color profile

`color`/`capability` above is the ANSI *encoding depth* a resolved color is
quantized to. The *color profile* is a separate, richer axis -- it adds
`"none"` (no color at all: `NO_COLOR`, or an explicit `FORCE_COLOR=0`/
`colorProfile = "none"`) -- that Ink **exposes to your components and lets
you decide what, if anything, to do about**. Nothing strips color
automatically just because `NO_COLOR` is set; a plain `color = "#rrggbb"` or
`color = "cyan"` prop paints exactly the same regardless of profile. Opting
in is what `useColorProfile`/`byProfile`/`adaptive` below are for.

```lua
local hooks = require("hydronium_ink.hooks")
local ink = require("hydronium_ink")

-- Inside a component's render closure (reactive -- re-reads on a live
-- profile change, e.g. Ink Lab's profile control):
local profile = hooks.useColorProfile() -- "truecolor"|"ansi256"|"ansi16"|"none"

-- Outside a mounted component tree (a plain function, no hook context):
local profile = ink.colorProfile() -- same "auto" NO_COLOR/FORCE_COLOR detection
```

A **session** seeds its profile from the real environment by default
(`NO_COLOR` -> `"none"`; `FORCE_COLOR=0/1/2/3` -> `none`/`ansi16`/`ansi256`/
`truecolor`; otherwise the same `COLORTERM`/`TERM` auto-detection `color`
already uses), or an explicit override:

```lua
session.create(app, { colorProfile = "ansi16" }) -- or render.render(app, { colorProfile = ... })
```

`Session:setColorProfile(profile)`/`Session:colorProfile()` change/read it at
runtime (what Ink Lab's own profile control uses to preview one story under
every profile without remounting it).

Any `color`/`backgroundColor`/`borderColor`, or structural prop
(`inverse`/`bold`/`dimColor`/`italic`/`underline`/`strikethrough`), may be
given **per profile** instead of one fixed value, via `ink.byProfile` (or its
alias `ink.adaptive`, which reads better on a single color):

```lua
ink.Text({
  color = ink.adaptive({
    truecolor = oklch(0.75, 0.10, 221), -- a real hue
    ansi16 = "cyan",                     -- ansi16's own RGB is theme-guessed,
                                          -- so lean on a named palette color
                                          -- (or skip it -- see the fallback below)
  }),
  inverse = ink.byProfile({ none = true }), -- NO_COLOR: fall back to reverse video
}, "status")
```

**Fallback chain**: an exact entry for the live profile wins. Missing that,
it uses the next RICHER profile's entry that IS defined (`ansi16` with only
`truecolor` given uses `truecolor`, which then quantizes normally --
"auto-lowering" is just the existing capability-based quantization running
on it, not a second pass here). A *color* prop specifically strips to no
color at `"none"` when no explicit `none` entry is given (rather than
inheriting a richer profile's real color, which would defeat the point of
`"none"`); a *structural* prop (`inverse`/`bold`/etc.) has no such special
case and keeps inheriting normally, since it has no color to strip.

**Why ansi16 gets no absolute-color help**: ansi16's 16 RGB values are
**theme-defined** -- a real terminal's own theme remaps them, so computing
contrast against an assumed RGB for one is false precision, not a real
guarantee. ansi256 (slots 16-255) are fixed, standard RGB, so contrast math
against them is real; `hydronium_ink.color.effective_srgb(color, capability)`
returns what a color will *actually* paint once quantized, for verifying
(and, with `hydronium_oklab_utils.ensure_contrast`, nudging) a target after
quantization rather than only in continuous space. See
`hydronium/cli`'s `ui/search_bar.lua` for a worked reference: truecolor and
ansi256 keep the same OKLCH chip design (ansi256 re-verified/nudged
post-quantization); ansi16 and `"none"` switch to inverse/bold against the
terminal's own default colors instead of guessing a hue.

## Controlled scrolling

Scrolling is deliberately application-controlled. This lets a view decide
which focused widget, key bindings, or data-loading policy owns the offset.

```lua
local top, set_top = h.signal(0)

hooks.useInput(function(_, key)
  if key.downArrow then set_top(top() + 1) end
  if key.upArrow then set_top(math.max(top() - 1, 0)) end
end)

return function()
  return ink.Box({ width = 48, height = 12, overflow = "scroll", scrollTop = top() }, rows())
end
```

The host clamps offsets to the laid-out content. Bind a ref and call
`hooks.useBoxMetrics(ref)` if the view needs the effective offset or
`scrollMaxTop`/`scrollMaxLeft` for a scrollbar or paging controls.

`render` also accepts `onTick`, a host-extension callback invoked before each
flush. The `hydronium-create --template ink` starter uses it to consume a
Ballad-generated source inventory when present (or its checked-in topology in
source mode), compile a coherent changed batch, and flush it through
`hydronium.core.hmr_host`. Compatible component state stays in the same LuaJIT
VM. Compile errors, unsafe effect boundaries, removed modules, and rejected
batches leave the previous program running and report that a controlled restart
is required.

## Current scope

Ink is a LuaJIT terminal host. Interactive raw-mode input is supported on
macOS and glibc Linux. Windows needs a separately verified Win32 console
backend before it can be advertised as interactive; it is not currently a
supported target. These are explicit host boundaries, not silent fallback
behavior.
