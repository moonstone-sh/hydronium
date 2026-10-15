-- hydronium_luax.compat for Lua 5.4 (also LuaLS's embedded Lua and the
-- browser engines). Same API as the untagged fallback `compat.lua`, with no
-- dialect checks. tests/core/compat_spec.lua compares the two.

local M = {}

local native_load = load
function M.load(source, chunkname, env)
  if type(source) ~= "string" then
    return nil, "hydronium_luax.compat.load: source must be a string, got " .. type(source)
  end
  if env == nil then return native_load(source, chunkname, "t") end
  return native_load(source, chunkname, "t", env)
end

local char = utf8.char
function M.utf8_char(code)
  if code < 0 or code > 0x10FFFF then return "\239\191\189" end -- U+FFFD
  return char(code)
end

return M
