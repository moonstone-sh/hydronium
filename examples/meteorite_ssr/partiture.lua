-- Real hydronium-ballad build for this example's /hydrate-demo route
-- (docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md M5): resolves and bundles
-- hydrate_demo/app.lua plus the real hydronium/hydronium_dom framework
-- source into ONE package_preload_v1 chunk under dist/client/, which
-- src/main.lua's /hydrate-demo route serves via meteorite.site and
-- fetches client-side via mount.js's `chunkUrls` option.
--
-- Run: moon exec ballad -- play partiture.lua
--
-- Framework source roots are resolved relative to THIS package's own
-- moonstone.toml path: dependencies (../../core, ../../dom) rather than
-- hardcoded absolute paths, so this keeps working if the workspace is
-- ever relocated -- unlike the ad hoc scratch probes used to develop
-- hydronium-ballad itself, this is a real, permanent part of the example.
local ballad = require("ballad")
local hb = require("hydronium_ballad")

return ballad.partiture(function(p)
  local client = p:use(hb.plugins.client)

  local app_src = p.source.files({ "app.lua" }, {
    root = "hydrate_demo",
    metadata = { hydronium = { target = "client" } },
  })
  local core_src = p.source.files({ "**/*.lua" }, {
    root = "../../core/src",
    metadata = { hydronium = { target = "shared" } },
  })
  local dom_src = p.source.files({ "**/*.lua" }, {
    root = "../../dom/src",
    metadata = { hydronium = { target = "shared" } },
  })

  local resolved = client.resolve(app_src, {
    entries = { "app" },
    depends_on = { core_src, dom_src },
  })
  local minified = client.minify(resolved, { level = "safe" })
  local bundled = client.bundle(minified, { entry = "app" })

  p.sink.directory(bundled, { out = "dist", file_graph = true })
end)
