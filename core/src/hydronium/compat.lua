--[[
  hydronium.compat -- the one place Hydronium's runtime packages bridge Lua
  dialects (LuaJIT, PUC Lua 5.1-5.5).

  This untagged file is the fallback: it works on every supported Lua and
  detects the dialect once, at load time. `compat@lua54.lua` is the same
  API with the 5.4 answers written out and no checks at all; Moonstone
  projects it as `hydronium/compat.lua` on a Lua 5.4 environment, and the
  browser bundlers (lua-wasm and Wasmoon both run 5.4) pick it explicitly.

  Why there is no `@luajit` / `@lua51` variant: the browser bundlers and
  LuaLS (embedded Lua 5.4) read this package's files out of the consumer's
  environment, where Moonstone keeps only the variant chosen for the HOST
  interpreter. A LuaJIT-only file there would be shipped to a 5.4 engine.
  Variants in browser-visible namespaces may therefore only target `lua54`
  (tests/core/compat_spec.lua enforces this). See docs/LUA_FLAVORS.md.

  The detection below is written as plain `jit` / `_VERSION` comparisons so
  a flavor-specializing bundler (Quaver) can fold it to one branch.

  API (identical in every variant):
    compat.unpack(list, i?, j?)          table.unpack / unpack
    compat.load(source, chunkname?, env?) compile TEXT only; `env` sandboxes
                                          the chunk on every dialect
    compat.tointeger(x)                   math.tointeger semantics: the
                                          integer value of `x`, or nil
--]]

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

local function integral(x)
  if type(x) == "number" and x == math.floor(x) and x > -math.huge and x < math.huge then return x end
  return nil
end

if jit ~= nil then
  -- LuaJIT: the 5.1 library, plus load(string, name, mode, env).
  M.unpack = unpack
  local native_load = load
  function M.load(source, chunkname, env)
    local problem = text_only(source)
    if problem then return nil, problem end
    if env == nil then return native_load(source, chunkname, "t") end
    return native_load(source, chunkname, "t", env)
  end
  M.tointeger = integral
elseif _VERSION == "Lua 5.1" then
  -- PUC Lua 5.1: load() takes only a reader function; environments are
  -- per-function (setfenv).
  M.unpack = unpack
  local native_loadstring, native_setfenv = loadstring, setfenv
  function M.load(source, chunkname, env)
    local problem = text_only(source)
    if problem then return nil, problem end
    local chunk, err = native_loadstring(source, chunkname)
    if chunk and env ~= nil then native_setfenv(chunk, env) end
    return chunk, err
  end
  M.tointeger = integral
else
  -- Lua 5.2+: table.unpack and load(chunk, name, mode, env). An explicit
  -- nil `env` would become the chunk's _ENV, so it is only passed when set.
  M.unpack = table.unpack
  local native_load = load
  function M.load(source, chunkname, env)
    if type(source) ~= "string" then return nil, text_only(source) end
    if env == nil then return native_load(source, chunkname, "t") end
    return native_load(source, chunkname, "t", env)
  end
  -- 5.2 has integers-as-floats only and no math.tointeger.
  M.tointeger = math.tointeger or integral
end

return M
