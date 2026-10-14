-- hydronium.compat for Lua 5.4 (also what the browser engines run).
-- Same API as the untagged fallback `compat.lua`, with no dialect checks.
-- Keep the two in step: tests/core/compat_spec.lua compares them.

local M = {}

M.unpack = table.unpack

local native_load = load
function M.load(source, chunkname, env)
  if type(source) ~= "string" then
    return nil, "hydronium.compat.load: source must be a string, got " .. type(source)
  end
  if env == nil then return native_load(source, chunkname, "t") end
  return native_load(source, chunkname, "t", env)
end

M.tointeger = math.tointeger

return M
