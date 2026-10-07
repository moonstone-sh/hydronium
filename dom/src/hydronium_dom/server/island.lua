--[[
  hydronium_dom.server.island -- render a module's component as a Lua island.

    local island = require("hydronium_dom.server.island")
    island("components.Counter", { start = 3 }, { hydrate = "visible" })

    -- or a drop-in component, so markup (LUAX, MDX) stays unchanged:
    local Counter = island.component("components.Counter", { hydrate = "visible" })
    <Counter start={3} />

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

local M = {}

--- @param module_id string Module whose return value is the component.
--- @param props? table Plain-data props.
--- @param opts? { hydrate?: "load"|"idle"|"visible" }
local function island(module_id, props, opts)
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

--- A component that renders `module_id` as an island with the props it is
--- given. Islands cannot take children: they would be server-only markup the
--- browser's copy of the component never receives.
--- @param module_id string
--- @param opts? { hydrate?: "load"|"idle"|"visible" }
function M.component(module_id, opts)
  if type(module_id) ~= "string" then
    error("hydronium_dom.server.island.component: module id must be a string, got " .. type(module_id), 2)
  end
  return function(props)
    local data = {}
    for key, value in pairs(props or {}) do
      if key == "children" then
        -- Children arrive as a frozen list proxy (userdata with __len).
        local ok, count = pcall(function() return #value end)
        if ok and count > 0 then
          error("hydronium_dom.server.island: " .. module_id .. " is an island and cannot take children", 2)
        end
      else
        data[key] = value
      end
    end
    return island(module_id, data, opts)
  end
end

return setmetatable(M, { __call = function(_, ...) return island(...) end })
