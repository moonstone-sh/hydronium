--[[
  Hydronium Ref System
  Object refs and callback refs with safe binding and unbinding.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")

local unpack = table.unpack or unpack

local refModule = {}

function refModule.createRef(initialValue)
  return {
    _typeof = symbols.REF,
    current = initialValue,
  }
end

function refModule.bindRef(ref, instance)
  if ref == nil then
    return
  end
  if type(ref) == "function" then
    pcall(ref, instance)
  elseif type(ref) == "table" then
    ref.current = instance
  end
end

function refModule.unbindRef(ref)
  if ref == nil then
    return
  end
  if type(ref) == "function" then
    pcall(ref, nil)
  elseif type(ref) == "table" then
    ref.current = nil
  end
end

return refModule
