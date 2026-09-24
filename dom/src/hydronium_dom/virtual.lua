-- Lua-facing DOM virtual host. `ref.current` is the real DOM handle supplied
-- by the existing Hydronium DOM bridge; no DOM object is inspected in Lua.
local M = {}
function M.createVirtualHost(ref, options)
  options = options or {}
  local axis = options.axis or "vertical"
  local observe, observe_item, scroll = _G.__dom_observe_virtual_container, _G.__dom_observe_virtual_item, _G.__dom_scroll_virtual_container
  if type(observe) ~= "function" or type(observe_item) ~= "function" or type(scroll) ~= "function" then error("hydronium.dom virtual bridge is not installed", 2) end
  local cleanup, viewport, offset = nil, nil, nil
  local function start()
    if cleanup then return end
    cleanup = observe(ref.current, axis, function(value) if viewport then viewport(value) end end, function(value) if offset then offset(value) end end)
  end
  local function stop_if_unused()
    if not viewport and not offset and cleanup then cleanup(); cleanup = nil end
  end
  return {
    observeViewport = function(fn)
      viewport = fn; start()
      return function() viewport = nil; stop_if_unused() end
    end,
    observeOffset = function(fn)
      offset = fn; start()
      return function() offset = nil; stop_if_unused() end
    end,
    observeItem = function(item, callback)
      local element = type(item) == "table" and item.current or item
      if not element then error("hydronium.dom virtual item requires a mounted ref or DOM handle", 2) end
      return observe_item(element, axis, callback)
    end,
    scrollTo = function(offset) scroll(ref.current, axis, offset) end,
  }
end
return M
