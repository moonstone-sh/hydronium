# Hydronium Meteorite integration

This package is the optional development-server adapter for Hydronium Lab. It
owns Meteorite route registration, the browser transport, exact package asset
resolution, and isolated Ink sessions. The standalone Lab CLI consumes the
small `hydronium_meteorite.lab_host.plan(input)` adapter protocol; neither the
Lab story model nor its Workbench depends on Meteorite.

Applications may mount the same adapter explicitly:

```lua
local lab = require("hydronium_meteorite.lab")
lab.mount(app, {
  base_path = "/tools/components",
  config_path = ".hydronium/lab/config.lua",
  redirect_root = false,
})
```

This is the current concrete integration seam. A generic, first-class
`meteorite.dev-extension.v1` lifecycle remains future Meteorite work; this
package does not claim extension collision handling or generalized service
supervision yet. See `../PENDING_METEORITE_LAB.md` for that forward plan.

The default adapter serves the shared DOM workbench, story-owned control views,
renderer assets and serialized session operations. It resolves an optional
project `document` or `.lab/Workbench.luax`; controls use the same story
schema and args as the Ink preview. Keep these routes in the development graph.
[Lab controls](../docs/LAB_CONTROLS.md) describes the unreleased customization
and playback APIs, including the SSR-versus-hydrated control boundary.

## DOM and mixed renderer Lab

Use `hydronium-lab init --renderer dom` or `--renderer mixed` for browser stories. Declare `renderer = "dom"` or `"ink"` on collections and stories to share one catalog. Controls update live args; each renderer runs in an isolated preview. DOM uses browser time; Ink retains virtual playback. See [the DOM and mixed Lab guide](../docs/LAB_DOM.md).
