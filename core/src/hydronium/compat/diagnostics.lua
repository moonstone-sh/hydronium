-- Optional debug introspection; callers retain the existing nil fallback.
---@type HydroniumCompatDiagnostics
local M = {}

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
