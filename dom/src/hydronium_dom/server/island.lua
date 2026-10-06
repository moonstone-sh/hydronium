--[[
  hydronium_dom.server.island -- render a module's component as a Lua island.

    local island = require("hydronium_dom.server.island")
    island("components.Counter", { start = 3 }, { hydrate = "visible" })

  is `<d.lua.island module="components.Counter" props={...} hydrate="visible">`
  around `<Counter start={3} />`, without spelling the module, props and
  children twice. The server renders the component in place; the browser
  (/js/bootstrap/islands.js) requires the same module with the same props and
  hydrates the markup. Props cross through the client plan, so they must be
  plain data (strings, numbers, booleans, tables of those).

  Server-only by design: it requires by a computed module id, which the
  client bundler refuses, and no island needs it -- a component that is
  already running in the browser renders its children directly.
--]]

local element = require("hydronium.core.element")
local d = require("hydronium_dom").d

local function check_props(value, path)
  local kind = type(value)
  if kind == "function" or kind == "userdata" or kind == "thread" then
    error("hydronium_dom.server.island: props" .. path .. " is a " .. kind
      .. "; island props must be plain data (they are serialized into the client plan)", 4)
  end
  if kind == "table" then
    for key, item in pairs(value) do check_props(item, path .. "." .. tostring(key)) end
  end
end

--- @param module_id string Module whose return value is the component.
--- @param props? table Plain-data props.
--- @param opts? { hydrate?: "load"|"idle"|"visible" }
return function(module_id, props, opts)
  if type(module_id) ~= "string" then
    error("hydronium_dom.server.island: module id must be a string, got " .. type(module_id), 2)
  end
  props = props or {}
  check_props(props, "")
  local Component = require(module_id)
  -- element.h may annotate its props table; the plan keeps the caller's.
  local own = {}
  for key, value in pairs(props) do own[key] = value end
  return element.h(d.lua.island, {
    module = module_id,
    props = props,
    hydrate = opts and opts.hydrate or "load",
  }, element.h(Component, own))
end
