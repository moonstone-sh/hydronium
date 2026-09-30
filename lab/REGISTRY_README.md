# hydronium/lab

Define ordinary Lua or LUAX component stories and combine them in an explicit
registry. This package owns metadata and shared workbench UI; an adapter owns
rendering, discovery and HTTP lifecycle.

## Install and run a registry

In an empty directory:

```sh
moon init . --name demo --interpreter luajit@2.1
moon add hydronium/lab hydronium/ink
```

Save this as label.stories.lua:

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

Save this as demo.lua:

```lua
local lab = require("hydronium_lab")
local stories = lab.registry({ dofile("label.stories.lua") })
local item = stories.manifest()[1]
print(item.id .. " | " .. item.title)
```

```sh
moon exec -- luajit demo.lua
```

Expected output: label/hello | Hello label. No browser or development server
starts: this checks the registry independently of its renderer.

## Open the story in a browser

The browser Ink workbench needs Moonstone and native LuaJIT/Yoga on arm64 or
x86-64 macOS, or glibc Linux. Windows and browser-only Yoga are not supported.
The packaged browser assets include xterm.js; no CDN or Bun install is needed
to launch Lab. Bun is needed only when rebuilding its browser sources.

Move the story to src/label.stories.lua (create src if necessary), then:

```sh
moon add --tool hydronium/lab-cli
moon exec -- hydronium-lab init
```

```sh
moon run lab
```

Open http://127.0.0.1:6100/__hydronium/lab and select Hello label. The preview
shows cyan text in a 40×12 terminal. The default CLI searches src; place stories
there or configure roots in hydronium.lab.lua. A .stories.luax file is an
ordinary LUAX module returning a story or collection; the host installs its
loader, so each story needs no compilation shim.

For embedded use, pass story modules to lab.registry or a normalized path
inventory to lab.discovery.plan. This library never scans the filesystem.
Story IDs must be unique in a registry. Sizes must be positive integer cells.

## Development API: controls and playback (unreleased)

The examples above use the published story/registry API. The following needs
a development build containing the Lab controls changes; it is not available
merely by installing the latest published package.

Replace the story with the following, then restart Lab:

```lua
local H = require("hydronium")
local ink = require("hydronium_ink")
local lab = require("hydronium_lab")

local function Label()
  local args = lab.useStoryArgs()
  return function() return H.h(ink.Text, nil, args().label) end
end

local function LabelControls()
  return H.h("label", nil, "Label ",
    H.h("input", { ["data-lab-control"] = "label", ["aria-label"] = "Label" }))
end

return lab.story({
  id = "label/hello", title = "Hello label",
  args = { label = "Hello, Lab" },
  controls = { label = { type = "text", label = "Label" } },
  controls_view = LabelControls,
  render = function() return H.h(Label) end,
})
```

Type in the Label field: the existing Ink preview updates without remounting.
Remove the controls_view entry to use the default generated field. Users own
widgets; ControlsOutlet is passive, while DefaultControls requests automatic
fields. Story args are JSON-shaped values. useStoryArgs() returns an args
getter, patch setter and reset function under the story provider.

The controls view is a DOM surface even when the story renders Ink. Named
input bindings work with the default SSR shell; arbitrary Lua event handlers
need browser hydration. A custom hydrated control view can use the same hooks
when mounted under the story provider.

Pause freezes virtual time while input and resizing remain active. Choose an
interval and press Step to advance one inspection frame. Restart remounts at
zero with current args and pauses. Forward seek is supported; backward
inspection requires restart followed by advancement. This does not reverse
arbitrary component effects. usePlayback() reads nowMs, frame, playing and
intervalMs under the same provider.

Compose PlayPause, FrameStep, TimeDisplay, FrameInterval and Restart from
hydronium_lab.controls, or use Timeline for the default composition.
See [the controls guide](https://github.com/moonstone-sh/hydronium/blob/feat/lab-controls-playback/docs/LAB_CONTROLS.md)
for transport operations and the observable browser store.

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
