# hydronium/ink-lab

Render Hydronium Ink stories in a resizable browser terminal. Ink calculates
the frame; the browser paints its cells. The boundary preserves Unicode,
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
return inkLab.dom.element(runtime:catalog().stories)
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

The `request` function is deliberately the only transport seam. The package
does not force a development server or expose a Lab endpoint in production.
Use `autoResize: true` to send dimensions while the terminal is dragged, or
call the returned `resize(columns, rows)` method for deterministic presets.

Current boundary: Yoga and Ink run in the native LuaJIT process. A browser Lua
VM may own the protocol later, but this release does not ship Yoga as WASM.
