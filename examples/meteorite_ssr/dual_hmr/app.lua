-- M2 dual-HMR coexistence proof (docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md):
-- the Lua-managed half of /dual-hmr. Real, interactive, signal-driven --
-- same "double function" setup/render pattern as
-- hydrate_demo/app.lua (this example's other real client-interactive Lua
-- proof), not an SSR-only static card like this file's other Counter/
-- LuaCounter demos.
--
-- Edit the h3 label below (e.g. "Lua island" -> "Lua isle") while
-- /dual-hmr is open: hydronium.core.family_loader hot-swaps this exact
-- module's RENDER function in the browser's live Lua VM via
-- hmr.js/installHmr, over the same /__hydronium/watch +
-- /__hydronium/dev/module machinery examples/quickstart uses -- see
-- src/main.lua's /dual-hmr route and its two new dev routes for the
-- wiring. The signal created below is NOT re-created by a hot swap (only
-- the render closure is replaced), so clicking first, then editing,
-- proves state survives the edit -- the entire point of family_loader
-- HMR over a plain page reload.
local dom = require("hydronium_dom")
local d = dom.d

-- An ORDINARY signal declaration -- no hand-written refresh descriptor. This
-- is a plain `.lua` file, and it still keeps its value across a hot swap,
-- because the dev-module route serves it through hydronium_luax.loader, whose
-- compile runs hydronium_luax.transforms.refresh and rewrites the line below
-- into the descriptor-carrying `scope.refresh_registry:signal(...)` form.
--
-- The one thing still written by hand is the `scope` parameter: the transform
-- deliberately never invents that binding (its rule 2a), and without it the
-- rewrite is skipped and this signal's value would be lost on every edit.
-- The compiler reports exactly that case as `refresh.missing_scope`.
return function(props, scope)
  local count, setCount = require("hydronium").signal(props.initial or 0)
  return function()
    return d.div({ class = "card", id = "lua-card" }, {
      d.h3(nil, "Lua island (real family_loader HMR)"),
      d.button({
        id = "lua-counter-btn",
        onClick = function() setCount(count() + 1) end,
      }, "Lua count: " .. tostring(count())),
      d.p(nil, "Hot-swapped in the surviving Lua VM by hydronium.core.family_loader -- not a page reload."),
    })
  end
end
