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
