-- The `canvas@1` host capability (js/packages/dom-client canvas_bridge.js):
-- what Lua cannot do through host references -- constructors, frame loops,
-- image loading, device pixel ratio, resize observation. Build-time
-- provenance (hydronium_ballad) and the runtime share this contract, as
-- with hydronium_dom.host.contract for dom@1.
local M = { name = "canvas", version = 1 }

local definitions = {
  path = { "construct", "canvas.create" },
  image_data = { "construct", "canvas.create" },
  image_data_from = { "construct", "canvas.create" },
  matrix = { "construct", "canvas.create" },
  offscreen = { "construct", "canvas.create" },
  load_image = { "assets", "network.read" },
  bitmap = { "assets", "canvas.create" },
  device_pixel_ratio = { "environment", "environment.read" },
  frame_loop = { "animation", "frame.schedule", "returned_disposer" },
  observe_resize = { "layout", "dom.observe", "returned_disposer" },
  -- Optional (clients from hydronium/dom 0.3.9 on): hydronium_dom.canvas checks for them.
  typed = { "construct", "canvas.create", nil, false },
  webgpu = { "environment", "environment.read", nil, false },
}

function M.manifest()
  local methods = {}
  for name, d in pairs(definitions) do
    methods[#methods + 1] = { name = name, group = d[1], effect = d[2], required = d[4] ~= false,
      cleanup = d[3], legacy_global = "__canvas_" .. name }
  end
  table.sort(methods, function(a, b) return a.name < b.name end)
  return { name = M.name, version = M.version, methods = methods,
    provider = { language = "javascript", package = "@hydronium-js/dom-client", module = "canvas_bridge.js", export = "createCanvasBridge" },
    lifecycle = "vm", registration_effect = "host.install" }
end

function M.validate(bridge)
  if type(bridge) ~= "table" then error("canvas bridge must be a table", 2) end
  local missing = {}
  for name, d in pairs(definitions) do
    if d[4] ~= false and type(bridge[name]) ~= "function" then missing[#missing + 1] = name end
  end
  table.sort(missing)
  if #missing > 0 then error("hydronium_dom.canvas: missing canvas bridge function(s): " .. table.concat(missing, ", "), 2) end
  return bridge
end

return M
