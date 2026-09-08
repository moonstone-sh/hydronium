-- Real, disk-edited "component module" for the DOM-Host/arbitrary-tree
-- proof (docs/HMR_DOM_HOST.md). Same discovery mechanism as
-- hmr_demo/family_counter.lua (require("app.components.counter"), no
-- hand registration) but authored against the real DOM Host via
-- `hydronium_dom`'s `d.button` intrinsic, not the TestHost that proof
-- used -- this is the version that actually renders onto a real
-- browser page. Edit the `+ 1` below to `+ 2` while the demo page is
-- open to prove HMR flows through the real DOM Host for an arbitrary
-- multi-component tree, not a single hand-wired island.
local dom = require("hydronium_dom")
local d = dom.d

return function(props, scope)
  local count, setCount = scope.refresh_registry:signal(props.initial or 0, {
    kind = "signal",
    name = "count",
    block_path = "Counter.setup",
  })
  return function()
    return d.button({
      id = props.id,
      onClick = function() setCount(count() + 1) end,
    }, "Count: " .. tostring(count()))
  end
end
