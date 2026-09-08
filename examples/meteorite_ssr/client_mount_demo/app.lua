-- Real app entry for the hydronium.client.mount proof -- fetched over
-- HTTP by mount.js like any other real module, not embedded.
local dom = require("hydronium_dom")
local d = dom.d

return function(props, scope)
  local count, setCount = scope.refresh_registry:signal(props.initial or 0, {
    kind = "signal",
    name = "count",
    block_path = "App.setup",
  })
  return function()
    return d.button({
      id = "client-mount-btn",
      onClick = function() setCount(count() + 1) end,
    }, "Count: " .. tostring(count()))
  end
end
