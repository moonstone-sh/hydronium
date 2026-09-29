# hydronium/lab

Small, explicit component-story registries for Hydronium tools. A registry is
ordinary Lua, so stories compose through `require` and remain visible to
Moonstone and Ballad dependency analysis.

```lua
local lab = require("hydronium_lab")

return lab.registry({
  lab.story({
    id = "status/healthy",
    title = "Healthy status",
    args = { name = "api" },
    render = function(args) return Status({ name = args.name }) end,
    sizes = { { name = "compact", columns = 40, rows = 12 } },
  }),
})
```

For an embedded host, discovery stays explicit: require story modules and pass
them to `lab.registry`, or provide a normalized path inventory to
`lab.discovery.plan`. The package itself never scans the filesystem. The
separate `hydronium/lab-cli` tool supplies portable `*.stories.lua[x]`
enumeration for the ordinary workbench workflow.

`hydronium_lab.host.contract({ base_path = "/tools/lab" })` describes the
versioned browser boundary: layered Workbench/renderer assets plus catalog and
session transport URLs. An HTTP adapter mounts that contract; `hydronium/lab`
does not depend on Meteorite.

## Controls and playback

Story files are normal Lua/LUAX modules. A story or collection may declare
`controls` metadata and a `controls_view` DOM component. Users own the inputs;
Lab validates and binds shared args. `lab.useStoryArgs()` returns a getter,
patch setter and reset function; `lab.usePlayback()` reads virtual playback
state under the story provider.

The default workbench opts into generated fields through `DefaultControls`.
`ControlsOutlet` is passive, including when empty. Ordinary
`data-lab-control="argument"` inputs work in custom server-rendered control
views; hydrated views can use the hooks. DOM controls and Ink previews are
separate rendering surfaces. Arbitrary Lua event callbacks in SSR controls
require hydration to run in the browser.

Compose `PlayPause`, `FrameStep`, `TimeDisplay`, `FrameInterval` and
`Restart` individually, or use the default `Timeline`. The Ink adapter
supplies virtual time; other adapters own their playback implementation.
[Controls and playback](../docs/LAB_CONTROLS.md) documents the complete contract.

These controls and playback APIs are unreleased development features.
