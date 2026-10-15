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

--- Where a Lua function is defined, for diagnostics: short source and first
--- line, or nil (C functions, stripped chunks, or no debug library).
function M.function_location(fn)
  local getinfo = debug and debug.getinfo
  local info = getinfo and type(fn) == "function" and getinfo(fn, "S")
  if info and info.short_src and info.linedefined and info.linedefined > 0 then
    return info.short_src, info.linedefined
  end
  return nil
end

--- Declared parameter count and vararg flag of a Lua function, or nil when
--- the runtime can't tell (PUC 5.1, C functions, no debug library).
function M.function_arity(fn)
  local getinfo = debug and debug.getinfo
  local info = getinfo and type(fn) == "function" and getinfo(fn, "u")
  if info and info.nparams ~= nil then
    return info.nparams, info.isvararg
  end
  return nil
end

return M
