-- Versioned JSON wire contract shared by SSR and browser hydration.
local json = require("hydronium_router.history.state")

local M = { VERSION = 1 }

local function fail(message, level)
  error("hydronium_router hydration state: " .. message, level or 3)
end

local function string_array(value, label)
  if type(value) ~= "table" then fail(label .. " must be an array", 4) end
  for index = 1, #value do
    if type(value[index]) ~= "string" or value[index] == "" then
      fail(label .. "[" .. index .. "] must be a non-empty string", 4)
    end
  end
end

function M.validate(value)
  if type(value) ~= "table" then fail("envelope must be an object", 2) end
  if value.version ~= M.VERSION then
    fail("unsupported version " .. tostring(value.version) .. "; expected " .. M.VERSION, 2)
  end
  if type(value.canonical_url) ~= "string" or value.canonical_url == "" then fail("canonical_url must be a string", 2) end
  if type(value.route_id) ~= "string" or value.route_id == "" then fail("route_id must be a string", 2) end
  string_array(value.route_chain, "route_chain")
  if type(value.params) ~= "table" then fail("params must be an object", 2) end
  if type(value.resources) ~= "table" then fail("resources must be an object", 2) end
  -- Encoding is also the portable shape check: no functions, mixed tables,
  -- cycles, userdata, or non-finite numbers cross the boundary.
  json.encode(value)
  return value
end

function M.encode(value) return json.encode(M.validate(value)) end

function M.decode(source)
  if type(source) == "table" then return M.validate(source) end
  return M.validate(json.decode(source))
end

return M
