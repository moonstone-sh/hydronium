--[[
  Development warnings: mistakes that do not raise an error but quietly
  misbehave. Each distinct warning is reported once per Lua state.

  Output goes to the handler installed with dev.set_handler(fn), else to a
  host-provided global `__hydronium_dev_warn(message)` (the docs site's
  playground shows these under the result), else to print.
]]

local scheduler = require("hydronium.core.scheduler")

local dev = {}
local seen = {}
local handler = nil

function dev.set_handler(fn)
  handler = fn
end

function dev.warn(key, message)
  if seen[key] then return end
  seen[key] = true
  local text = "[hydronium] " .. message
  local host = rawget(_G, "__hydronium_dev_warn")
  if handler then handler(text)
  elseif host then host(text)
  elseif print then print(text) end
end

--- Forget which warnings were shown (tests).
function dev.reset()
  seen = {}
end

-- A component's first call is its setup; a primitive created on any later
-- call (its render function, or a component without setup running again)
-- is created anew on every render and loses its state.
function dev.check_render_creation(kind)
  local component = scheduler.getCurrentRenderingComponent()
  if not component or component.inSetup then return end
  local name = component.name or "Component"
  dev.warn(kind .. "@" .. tostring(component.type), string.format(
    "%s was called while rendering <%s>, outside its setup, so it is created again on every render (a signal loses its value). Create it in setup: return a render function from %s and call %s before it.",
    kind, name, name, kind))
end

return dev
