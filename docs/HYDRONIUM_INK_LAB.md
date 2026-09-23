# Hydronium Ink Lab

Ink Lab is a component workbench built on Hydronium's own renderers. It has no
Storybook runtime and no second terminal layout engine.

## Architecture

```text
Ink story
   │
   ▼
hydronium_ink.session ──► canonical styled cell frame
                                │
                                ▼
                         Lab protocol snapshot
                                │
                                ▼
                    browser virtual terminal grid
```

`hydronium_ink.session` owns the component lifecycle, hook registries, key
parser, focus, animations, window-size signal, and Ink terminal host. It never
reads stdin or waits. A caller advances it with `write`, `dispatch`, `paste`,
`resize`, and `step`. The normal `ink.render()` path is now the POSIX TTY loop
around this same session.

The browser receives the terminal host's cell frame. Each cell carries its
grapheme, foreground and background color value, and rendition flags. Palette
references remain palette references, so a Lab theme can show the user's
terminal palette. Absolute colors remain sRGB in truecolor mode and project to
the same ANSI-256 or ANSI-16 slots as the native encoder in those preview
modes. No layer parses ANSI output.

## Stories

```lua
local H = require("hydronium")
local ink = require("hydronium_ink")
local lab = require("hydronium_lab")

local healthy = lab.story({
  id = "service/healthy",
  title = "Healthy service",
  args = { name = "api" },
  sizes = {
    { name = "compact", columns = 40, rows = 12 },
    { name = "wide", columns = 100, rows = 24 },
  },
  color = "truecolor",
  render = function(args)
    return H.h(ink.Text, { color = "green" }, args.name .. " online")
  end,
})

return lab.registry({ healthy })
```

Registries are explicit module composition. Lua has no portable filesystem
enumeration API, while `require("stories.service")` is visible to Moonstone,
Ballad, static analysis, and package closure computation.

## Protocol

Create one runtime per browser session or developer connection:

```lua
local inkLab = require("hydronium_ink_lab")
local runtime = inkLab.new(require("stories"))

local response = runtime:request(request)
```

Requests use these operations:

| Operation | Fields | Result |
| --- | --- | --- |
| `catalog` | — | Story metadata |
| `open` | `story`, optional `args`, `columns`, `rows`, `color` | Frame snapshot |
| `input` | `input`, `key` | Frame snapshot |
| `bytes` | `bytes` | Frame snapshot |
| `paste` | `text` | Frame snapshot |
| `resize` | `columns`, `rows` | Frame snapshot |
| `color` | `color` | Frame snapshot projected to the selected capability |
| `step` | optional `nowMs` | Frame snapshot |
| `interaction` | `name`, optional `nowMs` | Frame snapshot |
| `snapshot` | — | Frame snapshot |
| `close` | — | Closed acknowledgement |

The runtime does not choose HTTP, WebSocket, Meteorite, or an in-page Lua VM.
The browser's `createInkLab({request})` accepts any asynchronous function with
that request/response contract.

## Browser shell

`hydronium_ink_lab.dom.element(runtime:catalog().stories)` returns ordinary
Hydronium DOM. After mounting it, call `createInkLab` from
`hydronium_ink_lab/client/virtual_terminal.js`. The client adds story, size,
color and interaction controls; forwards keyboard and paste events; and paints
the styled cell grid. `resize(columns, rows)` is deterministic. With
`autoResize: true`, a `ResizeObserver` translates a dragged browser surface
into terminal dimensions.

## Boundaries

- The native LuaJIT process still runs Ink and Yoga. Yoga is not shipped as
  browser WASM.
- Story discovery is explicit rather than based on directory scanning.
- Screenshot baselines and browser automation are not included yet.
- Authentication and session isolation belong to the development server that
  exposes the protocol. Do not expose an unauthenticated Lab runtime in a
  production application.
