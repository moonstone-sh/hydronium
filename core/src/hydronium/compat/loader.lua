-- Text-only compilation capability. Not a dependency of primitive helpers.
---@type HydroniumCompatLoader
local M = {}

local function text_only(source)
  if type(source) ~= "string" then
    return "hydronium.compat.load: source must be a string, got " .. type(source)
  end
  if source:byte(1) == 27 then
    return "hydronium.compat.load: attempt to load a binary chunk"
  end
  return nil
end

if jit ~= nil then
  -- LuaJIT: the 5.1 library, plus load(string, name, mode, env).
  local native_load = load
  function M.load(source, chunkname, env)
    local problem = text_only(source)
    if problem then return nil, problem end
    if env == nil then return native_load(source, chunkname, "t") end
    return native_load(source, chunkname, "t", env)
  end
elseif _VERSION == "Lua 5.1" then
  -- PUC Lua 5.1: load() takes only a reader function; environments are
  -- per-function (setfenv).
  local native_loadstring, native_setfenv = loadstring, setfenv
  function M.load(source, chunkname, env)
    local problem = text_only(source)
    if problem then return nil, problem end
    local chunk, err = native_loadstring(source, chunkname)
    if chunk and env ~= nil then native_setfenv(chunk, env) end
    return chunk, err
  end
else
  -- Lua 5.2+: table.unpack and load(chunk, name, mode, env). An explicit
  -- nil `env` would become the chunk's _ENV, so it is only passed when set.
  local native_load = load
  function M.load(source, chunkname, env)
    if type(source) ~= "string" then return nil, text_only(source) end
    if env == nil then return native_load(source, chunkname, "t") end
    return native_load(source, chunkname, "t", env)
  end
end

return M
