--[[
  Development warnings: mistakes that do not raise an error but quietly
  misbehave. Each distinct warning is reported once per Lua state.

  Output goes to the handler installed with dev.set_handler(fn), else to the
  host's dev@1 capability, `warn(message)` (the docs site's playground
  installs one to show these under the result), else to print. The former
  `__hydronium_dev_warn` global was removed.
]]

local scheduler = require("hydronium.core.scheduler")
local compat = require("hydronium.compat")
local hosts = require("hydronium.runtime.hosts")

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
  local host = hosts.get("dev", 1)
  if handler then handler(text)
  elseif host and type(host.warn) == "function" then host.warn(text)
  elseif print then print(text) end
end

--- Forget which warnings were shown (tests).
function dev.reset()
  seen = {}
end

--- A component for messages: its name when it has one, else where its
--- function is defined (local functions have no name at run time).
function dev.describe(component)
  local name = component.name
  if name and name ~= "Component" and name ~= "Anonymous" then return "<" .. name .. ">" end
  local source, line = compat.function_location(component.type)
  if source then
    return "the component defined at " .. source:gsub("^.*[/\\]", "") .. ":" .. line
  end
  return "<" .. (name or "Component") .. ">"
end

-- A component's first call is its setup; a primitive created on any later
-- call (its render function, or a component without setup running again)
-- is created anew on every render and loses its state.
function dev.check_render_creation(kind)
  local component = scheduler.getCurrentRenderingComponent()
  if not component or component.inSetup then return end
  dev.warn(kind .. "@" .. tostring(component.type), string.format(
    "%s was called while rendering %s, outside its setup, so it is created again on every render (a signal loses its value). Create it in setup: return a render function from the component and call %s before it.",
    kind, dev.describe(component), kind))
end

return dev
