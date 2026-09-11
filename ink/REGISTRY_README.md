# Hydronium Ink

`moonstone/hydronium-ink` renders Hydronium trees in a terminal. Its Yoga
backed `Box` layout, styled `Text`, and input hooks run on LuaJIT.

```sh
moon add moonstone/hydronium-ink
```

The package resolves `moonstone/hydronium` and projects the matching native
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
| `hydronium_ink.render` | `render(element, opts?)` | Mounts an app and runs its blocking event loop. `opts.exitOnCtrlC` defaults to `true`; `opts.writeFn` replaces `io.write`. |
| `hydronium_ink.hooks` | `useInput`, `usePaste`, `useApp`, `useWindowSize` | Keyboard, bracketed paste, app exit, and reactive terminal size. |
| `hydronium_ink.hooks` | `useFocus`, `useFocusManager`, `useCursor`, `useBoxMetrics`, `useAnimation` | Focus traversal, cursor placement, measured layout, and timed updates. |

`Box` supports Yoga flexbox properties such as `flexDirection`, `justifyContent`,
`alignItems`, `flexGrow`, `padding`, `margin`, `width`, `height`, and
`borderStyle = "single"`. `Text` supports `color`, `backgroundColor`, `bold`,
`dimColor`, `italic`, `underline`, `strikethrough`, `inverse`, and fixed-width
truncation with `width` plus `wrap = "truncate"`, `"truncate-start"`,
`"truncate-middle"`, or `"truncate-end"`.

Hooks belong in the setup call of a component, before it returns its render
function. `useInput` and focus activation options are read at setup time.
They do not rerun reactively when those options change.

`render` also accepts `onTick`, a host-extension callback invoked before each
flush. The `hydronium-create --template ink` starter uses it to watch and
compile `src/App.luax`, then calls `hydronium.core.hmr.replace`. Compatible
component state stays in the same LuaJIT VM. Compile errors leave the previous
component running and are retried after the next edit.
