# hydronium/ink-lab

Preview native Ink stories in a resizable browser terminal. Ink emits ANSI;
the bundled xterm.js preview preserves styled text, palette colors and cursor
state. Yoga runs in native LuaJIT rather than browser WASM.

## Install, add a story and launch

The browser Ink workbench needs Moonstone and native LuaJIT/Yoga on arm64 or
x86-64 macOS, or glibc Linux. Windows and browser-only Yoga are not supported.
The packaged browser assets include xterm.js; no CDN or Bun install is needed
to launch Lab. Bun is needed only when rebuilding its browser sources.

Start in an empty directory, or omit moon init in an existing project:

```sh
moon init . --name story-demo --interpreter luajit@2.1
moon add --tool hydronium/lab-cli
moon exec -- hydronium-lab init
mkdir -p src
```

Save this as src/label.stories.lua:

```lua
local H = require("hydronium")
local ink = require("hydronium_ink")
local lab = require("hydronium_lab")

return lab.story({
  id = "label/hello", title = "Hello label",
  args = { label = "Hello, Lab" },
  sizes = { { name = "compact", columns = 40, rows = 12 } },
  render = function(args)
    return H.h(ink.Text, { color = "cyan" }, args.label)
  end,
})
```

```sh
moon run lab
```

Open http://127.0.0.1:6100/__hydronium/lab and select Hello label. You should
see cyan text in a 40×12 terminal. Resize using the cell inputs or size menu;
keyboard input goes to the native Ink session. Mouse dragging selects terminal
text; drag empty canvas space or use the hand tool to pan.

init adds Lab, Ink Lab and its Meteorite adapter as development dependencies,
and the Meteorite executable as a tool. It is safe to rerun. Lab routes belong
to this development server, not automatically to your production application.

## Choose roots, port and mount path

Save hydronium.lab.lua at the project root:

```lua
return {
  roots = { "src" },
  module_roots = { "src" },
  base_path = "/tools/components",
  host = "meteorite",
}
```

```sh
moon exec --dev -- hydronium-lab dev --port 6101 --no-open
```

Open http://127.0.0.1:6101/tools/components. --no-open keeps the CLI from
opening a browser. --dry-run prints the launch plan without starting the host.
If discovery reports no stories, check the configured roots and the exact
.stories.lua or .stories.luax suffix. If 6100 is occupied, select another port.


## Test the same story without HTTP

With the project above, save inspect.lua at the project root:

```lua
local lab = require("hydronium_lab")
local inkLab = require("hydronium_ink_lab")
local stories = lab.registry({ dofile("src/label.stories.lua") })
local runtime = inkLab.new(stories)
local frame = runtime:request({ op = "open", story = "label/hello" })
assert(frame ~= nil)
print("Opened label/hello")
runtime:request({ op = "close" })
```

```sh
moon exec --dev -- luajit inspect.lua
```

Expected output: Opened label/hello. This drives the same native session without
mounting the browser shell. For a custom HTTP adapter, keep one runtime per
session and connect runtime:request to the browser client's request function.
Serve the complete shared Workbench and Ink asset set; importing xterm.js alone
does not create a Lab workbench. The default adapter handles these routes.

## Development API: args and frame inspection (unreleased)

Use lab.useStoryArgs() in component setup and read its getter in the render
function. Patching args updates the existing story without remounting it.
Pause, choose an interval and Step to inspect animation frames. Restart resets
component state at zero while retaining args, size and color settings. Seeking
moves forward; restart before inspecting an earlier time.

For a custom browser toolbar, createInkLab returns setArgs, play, pause,
advance, seek, restart and an observable state store. Inputs and resize remain
usable while paused. These virtual-time APIs require the development version;
they are not reversible recording/replay.

## Development API: customize the workbench (unreleased)

These commands need a development build with Lab customization. After init:

```sh
moon exec --dev -- hydronium-lab customize
```

This creates .lab/Workbench.luax. Edit its ordinary DOM markup or compose the
public Workbench and Ink components, restart Lab and reload the browser. Keep
required named surfaces such as data-lab-terminal when replacing the preview.
Existing files are preserved. To copy the default markup too, run this instead
of the small-entry command:

```sh
moon exec --dev -- hydronium-lab customize --copy-shell
```

It writes .lab/Workbench.luax and .lab/LabChrome.luax. Copied files are yours
and do not receive upstream markup updates. Runtime/controller code remains
imported from packages. An explicit document and module_roots in
hydronium.lab.lua can select another entry.

Story-specific controls do not require copying the shell. Use controls_view
with ordinary data-lab-control inputs; the default workbench generates fields
when no custom view is supplied. Pause, Step and Restart inspect virtual time
without requiring a custom document. See
[the runnable controls example](https://github.com/moonstone-sh/hydronium/blob/feat/router-named-slots/lab/REGISTRY_README.md#development-api-controls-and-playback-unreleased)
for a complete story and its DOM controls.
