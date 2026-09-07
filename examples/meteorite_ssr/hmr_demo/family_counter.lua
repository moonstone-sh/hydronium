-- Real, disk-edited "component module" for the HMR generalization proof.
-- Discovered purely by require("app.components.counter") -- no hand
-- registration, no descriptor list. Edit the `+ 1` below to `+ 2` while
-- the demo page is open to prove the generalized refresh path.
local element = require("hydronium.core.element")

return function(props, scope)
  local count, setCount = scope.refresh_registry:signal(props.initial or 0, {
    kind = "signal",
    name = "count",
    block_path = "Counter.setup",
  })
  return function()
    return element.h("button", {
      onClick = function() setCount(count() + 1) end,
    }, "Count: " .. tostring(count()))
  end
end
