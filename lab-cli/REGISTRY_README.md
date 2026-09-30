# hydronium/lab-cli

Discover component stories and launch a browser workbench in an existing
Moonstone project. The CLI selects an explicit renderer/host adapter and keeps
its dependencies in development and tool profiles.

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


## Use another host adapter

In hydronium.lab.lua, replace host = "meteorite" with a table:

```lua
host = { package = "acme/lab-host", module = "acme_lab_host" }
```

This is a configuration fragment, not a standalone module. Add the selected
package as a development dependency. Its module must expose plan(input) and
return files, command and url. The CLI does no ambient plugin scanning.

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

## DOM and mixed renderer Lab

Use `hydronium-lab init --renderer dom` or `--renderer mixed` for browser stories. Declare `renderer = "dom"` or `"ink"` on collections and stories to share one catalog. Controls update live args; each renderer runs in an isolated preview. DOM uses browser time; Ink retains virtual playback. See [the DOM and mixed Lab guide](https://github.com/moonstone-sh/hydronium/blob/main/docs/LAB_DOM.md).

```sh
moon add --tool hydronium/lab-cli
moon exec -- hydronium-lab init --renderer mixed
moon run lab
```

```lua
local lab = require("hydronium_lab")
return lab.collection({ renderer = "dom", component = require("Button"),
  args = { label = "Hello" }, controls = { label = { type = "text" } },
  stories = { default = {} } })
```

Keep native Ink imports in Ink story modules. Add compiled CSS with `styles = { "public/app.css" }` in `hydronium.lab.lua`; run its compiler in watch mode separately.
