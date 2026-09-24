-- Ink implementation of hydronium_virtual.bind's host protocol. Ink scroll
-- props are controlled, so callers own the signal that becomes scrollTop/Left.
local measure = require("hydronium_ink.measure")
local M = {}

function M.createVirtualHost(ref, options)
  options = options or {}
  local axis = options.axis or "vertical"
  if axis ~= "vertical" and axis ~= "horizontal" then error("hydronium.ink virtual axis must be vertical or horizontal", 2) end
  if type(options.setScroll) ~= "function" then error("hydronium.ink.createVirtualHost requires setScroll(offset)", 2) end
  local viewport_listener, offset_listener = nil, nil
  local host = {}
  function host:refresh()
    local metrics = measure.measureElement(ref)
    if viewport_listener then viewport_listener(axis == "horizontal" and metrics.clientWidth or metrics.clientHeight) end
    if offset_listener then offset_listener(axis == "horizontal" and metrics.scrollLeft or metrics.scrollTop) end
  end
  function host.observeViewport(fn) viewport_listener = fn; host:refresh(); return function() viewport_listener = nil end end
  function host.observeOffset(fn) offset_listener = fn; host:refresh(); return function() offset_listener = nil end end
  function host.scrollTo(offset) options.setScroll(offset) end
  function host.observeItem(_, _) return function() end end -- Ink rows are cell-sized; callers measure explicitly if variable.
  return host
end

return M
