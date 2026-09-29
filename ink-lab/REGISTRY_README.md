# hydronium/ink-lab

Render Hydronium Ink stories in a resizable browser terminal. Ink calculates
the frame and emits ANSI; the bundled xterm.js browser preview renders it. The boundary preserves Unicode,
terminal palette references, sRGB colors, text attributes, and cursor state.

Add it to an existing Hydronium project like Storybook's development surface:

```sh
moon add hydronium/lab hydronium/ink-lab
```

Serve the included stylesheet from the package's client directory once in your
browser entry:

```html
<link rel="stylesheet" href="/hydronium-ink-lab/client/lab.css">
```

```lua
local lab = require("hydronium_lab")
local inkLab = require("hydronium_ink_lab")

local stories = lab.registry({ require("stories.counter") })
local runtime = inkLab.new(stories)

-- Connect this to your HTTP/WebSocket/in-page Lua bridge.
local response = runtime:request({ op = "open", story = "counter/basic" })
```

Mount the shell as an ordinary Hydronium DOM component:

```lua
local H = require("hydronium")
local components = require("hydronium_ink_lab.components")
return H.h(components.Shell, { project_name = "My stories" })
```

Then enhance the mounted tree in the browser:

```js
import { createInkLab } from "/hydronium-ink-lab/client/virtual_terminal.js";

await createInkLab({
  root: "[data-hydronium-ink-lab]",
  request: message => fetch("/__lab", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(message),
  }).then(response => response.json()),
});
```

The client loads the catalog through the supplied `request` function. The
shared Workbench styles and Ink styles must also be served when composing
this manually. The default Meteorite Lab adapter mounts the full asset set
and injects its URLs; use `hydronium/lab-cli init` for that setup.

The `request` function is deliberately the only transport seam. The package
does not force a development server or expose a Lab endpoint in production.
Use `autoResize: true` to send dimensions while the terminal is dragged, or
call the returned `resize(columns, rows)` method for deterministic presets.

Current boundary: Yoga and Ink run in the native LuaJIT process. A browser Lua
VM may own the protocol later, but this release does not ship Yoga as WASM.

## Inspect and customize stories

Controls patch args in the existing session without remounting it. The browser
client exposes `setArgs`, `play`, `pause`, `advance`, `seek` and
`restart`, plus an observable `state` store. Virtual time starts at zero;
step and forward seek advance it deterministically. Backward inspection uses
restart followed by forward advancement.

Story-specific, saved user and standard dimension presets share one menu.
Zoom adjusts terminal font size; mouse dragging selects text. Drag empty canvas
space, use the hand tool, or hold Space to pan; touch dragging also pans.
Focus metadata brings the active terminal control into view.

Use `hydronium-lab customize` for a project-owned `.lab/Workbench.luax`.
The [controls guide](../docs/LAB_CONTROLS.md) covers DOM control outlets,
playback primitives, default components and copying the shell. These control,
playback and customization APIs are unreleased.
