-- Real app entry for the hydronium-ballad + real Meteorite SSR->hydrate
-- proof (docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md's M4/M5). Compiled
-- and bundled by hydronium-ballad's real client plugin (see
-- ../partiture.lua) into one package_preload_v1 chunk under
-- dist/client/, then fetched and hydrated by mount.js against this
-- exact same file's real SSR output (see src/main.lua's /hydrate-demo
-- route) -- one real file, both sides, so any behavioral difference
-- would be a real hydration bug, not an authoring mismatch between two
-- hand-written copies.
local dom = require("hydronium_dom")
local d = dom.d

return function(props)
  local count, setCount = require("hydronium").signal(props.initial or 0)
  return function()
    return d.button({
      id = "hydrate-demo-btn",
      onClick = function() setCount(count() + 1) end,
    }, "Count: " .. tostring(count()))
  end
end
