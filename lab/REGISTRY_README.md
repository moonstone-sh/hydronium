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
