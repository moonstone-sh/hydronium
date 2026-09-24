-- Hydronium-facing lifecycle adapter over a host's small virtual-scroll protocol.
local core = require("hydronium.core")
local M = {}

local function require_method(host, name)
  if type(host[name]) ~= "function" then error("hydronium.virtual host requires " .. name, 3) end
end

function M.bind(virtualizer, host)
  if type(virtualizer) ~= "table" then error("hydronium.virtual.bind requires a virtualizer", 2) end
  if type(host) ~= "table" then error("hydronium.virtual.bind requires a host", 2) end
  require_method(host, "observeViewport")
  require_method(host, "observeOffset")
  require_method(host, "scrollTo")
  local cleanups = {}
  local function observe(method, callback)
    local cleanup = host[method](callback)
    if type(cleanup) == "function" then cleanups[#cleanups + 1] = cleanup end
  end
  observe("observeViewport", function(size) virtualizer:setViewportSize(size) end)
  observe("observeOffset", function(offset) virtualizer:setScrollOffset(offset) end)
  local binding = {}
  function binding:observeItem(index, item)
    require_method(host, "observeItem")
    local cleanup = host.observeItem(item, function(size) virtualizer:measure(index, size) end)
    if type(cleanup) == "function" then cleanups[#cleanups + 1] = cleanup end
  end
  function binding:scrollToIndex(index, align)
    local offset = virtualizer:scrollToIndex(index, align)
    host.scrollTo(offset)
    return offset
  end
  function binding:dispose()
    local pending, errors = cleanups, {}
    cleanups = {}
    for _, cleanup in ipairs(pending) do local ok, err = pcall(cleanup); if not ok then errors[#errors + 1] = err end end
    if #errors > 0 then error(errors[1], 0) end
  end
  if core.getScope() then core.onCleanup(function() binding:dispose() end) end
  return binding
end

return M
