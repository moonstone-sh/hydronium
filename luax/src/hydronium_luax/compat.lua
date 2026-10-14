--[[
  hydronium_luax.compat -- the one place the LUAX toolchain bridges Lua
  dialects. It deliberately does not depend on `hydronium` (LUAX compiles
  for any runtime; see tests/luax/no_core_coupling_spec.lua).

  This untagged file is the fallback for every supported Lua; it detects the
  dialect once, with `jit` / `_VERSION` comparisons a flavor-specializing
  bundler can fold. `compat@lua54.lua` is the same API without checks.
  Only a `@lua54` variant may exist: LuaLS (embedded Lua 5.4) and the DOM
  Lab browser bundle load this package out of the consumer's environment,
  where Moonstone keeps only the host interpreter's variant. See
  docs/LUA_FLAVORS.md.

  API (identical in every variant):
    compat.load(source, chunkname?, env?)  compile TEXT only
    compat.utf8_char(code)                 UTF-8 bytes for a code point;
                                           U+FFFD outside 0..0x10FFFF
--]]

local M = {}

local REPLACEMENT = "\239\191\189" -- U+FFFD

local function encode(code)
  if code < 0 or code > 0x10FFFF then return REPLACEMENT end
  if code <= 0x7F then return string.char(code) end
  if code <= 0x7FF then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  end
  if code <= 0xFFFF then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function not_text(source)
  if type(source) ~= "string" then
    return "hydronium_luax.compat.load: source must be a string, got " .. type(source)
  end
  if source:byte(1) == 27 then return "hydronium_luax.compat.load: attempt to load a binary chunk" end
  return nil
end

if jit ~= nil then
  local native_load = load
  function M.load(source, chunkname, env)
    local problem = not_text(source)
    if problem then return nil, problem end
    if env == nil then return native_load(source, chunkname, "t") end
    return native_load(source, chunkname, "t", env)
  end
  M.utf8_char = encode
elseif _VERSION == "Lua 5.1" then
  local native_loadstring, native_setfenv = loadstring, setfenv
  function M.load(source, chunkname, env)
    local problem = not_text(source)
    if problem then return nil, problem end
    local chunk, err = native_loadstring(source, chunkname)
    if chunk and env ~= nil then native_setfenv(chunk, env) end
    return chunk, err
  end
  M.utf8_char = encode
else
  local native_load = load
  function M.load(source, chunkname, env)
    if type(source) ~= "string" then return nil, not_text(source) end
    if env == nil then return native_load(source, chunkname, "t") end
    return native_load(source, chunkname, "t", env)
  end
  if utf8 and utf8.char then
    local char = utf8.char
    function M.utf8_char(code)
      if code < 0 or code > 0x10FFFF then return REPLACEMENT end
      return char(code)
    end
  else
    M.utf8_char = encode -- 5.2 has no utf8 library
  end
end

return M
