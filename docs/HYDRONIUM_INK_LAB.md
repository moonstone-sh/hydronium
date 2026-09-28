# Hydronium Ink Lab

Ink Lab is a component workbench built on Hydronium's own renderers. It has no
Storybook runtime and no second terminal layout engine.

## Architecture

```text
Ink story
   │
   ▼
hydronium_ink.session ──► canonical styled cell frame (hydronium_ink_lab.snapshot)
                                │
                                ▼
                  style-interned, run-length wire frame (hydronium_ink_lab.frame)
                                │
                                ▼
                    canonical model for tooling and tests

Ink terminal host ──► native ANSI stream ──► xterm.js browser preview
                                           │
                                           └──► input bytes back to Ink session
```

`hydronium_ink.session` owns the component lifecycle, hook registries, key
parser, focus, animations, window-size signal, and Ink terminal host. It never
reads stdin or waits. A caller advances it with `write`, `dispatch`, `paste`,
`resize`, and `step`. The normal `ink.render()` path is now the POSIX TTY loop
around this same session.

`hydronium_ink_lab.snapshot` projects that session frame into one JSON-safe
record per cell (grapheme, foreground/background color value, rendition
flags). That per-cell shape is still exactly what any direct consumer of
`snapshot.from_session` gets; it is simply not what goes over the wire on
every animation tick any more. `hydronium_ink_lab.frame` compresses it into
"frame protocol v2" before a `Runtime:request` response reaches a transport:
a per-session style table interns each distinct fg/bg/bold/dim/italic/
underline/strikethrough/inverse combination once, referenced by a small
integer id thereafter, and rows are encoded as `{styleId, [ch, ...]}` runs
instead of one object per cell. `open`/`resize`/`color`/`colorProfile`/
`snapshot` produce a self-contained "full" frame (every style it uses,
embedded); every other op (`step`/`input`/`bytes`/`paste`/`interaction`)
produces a "delta" -- only the cells that changed since the previous frame,
as `{y, x, styleId, [ch, ...]}` row runs (0-based `y`/`x`), plus any styles the peer hasn't
seen yet. Palette references remain palette references, so a Lab theme can
show the user's terminal palette. Absolute colors remain sRGB in truecolor
mode and project to the same ANSI-256 or ANSI-16 slots as the native encoder
in those preview modes. No layer parses ANSI output.

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
| `open` | `story`, optional `args`, `columns`, `rows`, `color` | Full frame |
| `input` | `input`, `key` | Delta frame |
| `bytes` | `bytes` | Delta frame |
| `paste` | `text` | Delta frame |
| `resize` | `columns`, `rows` | Full frame |
| `color` | `color` | Full frame, projected to the selected capability |
| `colorProfile` | `colorProfile` | Full frame |
| `step` | optional `nowMs` | Delta frame |
| `interaction` | `name`, optional `nowMs` | Delta frame |
| `snapshot` | — | Full frame (also the client's resync request) |
| `close` | — | Closed acknowledgement |

"Full frame" and "delta frame" are the `hydronium_ink_lab.frame`-encoded
wire shape (`version = 2`, `kind = "full" | "delta"`), not the raw
`hydronium_ink_lab.snapshot` per-cell record -- see Architecture above. Every
frame carries a `seq`; a delta also carries `base` (the `seq` of the frame it
diffs against). A client that receives a delta whose `base` it doesn't
recognize (a dropped or reordered response) should not paint it -- request a
fresh `snapshot` instead, which is always a full, self-contained frame.

The runtime does not choose HTTP, WebSocket, Meteorite, or an in-page Lua VM.
The browser's `createInkLab({request})` accepts any asynchronous function with
that request/response contract.

## Browser shell

`hydronium_ink_lab.dom.element(runtime:catalog().stories)` returns ordinary
Hydronium DOM. After mounting it, call `createInkLab` from
`hydronium_ink_lab/client/virtual_terminal.js`. The client adds story, size,
color and interaction controls; maintains a canonical model for tooling;
and writes the native ANSI stream into xterm. Browser keyboard and paste
arrive as input bytes. Wheel events over inline previews are normalized to
cell rows and coalesced into `scroll` requests: at most one runs at a time,
and reversing direction discards the pending movement in the old direction.
`resize(columns, rows)` is deterministic. With
`autoResize: true`, a `ResizeObserver` translates a dragged browser surface
into terminal dimensions.

Animation ticks (`op: "step"`) run on a steady cadence (`animationIntervalMs`
to `createInkLab`, default ~55ms) rather than a canvas-size-based throttle --
delta encoding made an idle or small-change tick cheap regardless of canvas
size, so there is no longer a reason to poll a large terminal more slowly.
The next tick is still only scheduled after the previous one settles (no
request backlog), and a run of genuinely idle deltas (empty `changes`, no
cursor/status change) backs the cadence off toward a ceiling; any real input
or interaction snaps it back to the base cadence immediately
(`createAnimationPacer`).

## Boundaries

- The native LuaJIT process still runs Ink and Yoga. Yoga is not shipped as
  browser WASM.
- Story discovery is explicit rather than based on directory scanning.
- Screenshot baselines and browser automation are not included yet.
- Authentication and session isolation belong to the development server that
  exposes the protocol. Do not expose an unauthenticated Lab runtime in a
  production application.

## Browser terminal adapter

Runtime responses additionally contain `ansi` (native host output),
`terminal` (`columns`, `rows`, `inline`, `scrollable`), and `focus` (a
zero-based cell rectangle and navigation token, or false). Physical terminal
rows can differ from the full canonical frame height for inline forms.
Explicit snapshot requests force a native redraw for resynchronization.

The xterm adapter owns input, paste, selection, Unicode widths and ANSI
rendering. The controller owns story selection, dimensions, canvas panning
and focus following. Zoom changes the terminal font size rather than
scaling terminal DOM, preserving mouse coordinates and sharp text.

Bun builds xterm and the controller into the existing `virtual_terminal.js`
asset and combines xterm CSS with `ink-source.css` into `ink.css`. Both ship
inside the registry source package; no extra asset routes or CDN are needed.
The Lab page permits inline styles for xterm's generated renderer CSS while
keeping scripts restricted to the same origin. Dependency versions and
licenses are pinned in `ink-lab/bun.lock` and `client/XTERM-LICENSES.txt`.
