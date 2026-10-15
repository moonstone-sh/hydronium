-- Text-only compilation for Lua 5.4.
---@type HydroniumCompatLoader
local M = {}

local native_load = load
function M.load(source, chunkname, env)
  if type(source) ~= "string" then
    return nil, "hydronium.compat.load: source must be a string, got " .. type(source)
  end
  if env == nil then return native_load(source, chunkname, "t") end
  return native_load(source, chunkname, "t", env)
end

return M
