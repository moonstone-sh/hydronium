--[[
  Hydronium Core Symbols
  Unique symbols and tokens for internal tagging and VNode type identification.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local unpack = table.unpack or unpack

local symbols = {}

local function createSymbol(name)
  local sym = {
    __hydronium_symbol = true,
    name = name,
  }
  setmetatable(sym, {
    __tostring = function()
      return "Hydronium.Symbol(" .. name .. ")"
    end,
    __eq = function(a, b)
      return type(a) == "table" and type(b) == "table" and a.name == b.name and a.__hydronium_symbol == true and b.__hydronium_symbol == true
    end,
  })
  return sym
end

symbols.VNODE = createSymbol("VNODE")
symbols.ELEMENT = createSymbol("ELEMENT")
symbols.COMPONENT = createSymbol("COMPONENT")
symbols.FRAGMENT = createSymbol("FRAGMENT")
symbols.TEXT = createSymbol("TEXT")
symbols.BOUNDARY = createSymbol("BOUNDARY")
symbols.INTRINSIC = createSymbol("INTRINSIC")
symbols.SUSPENSE = createSymbol("SUSPENSE")
symbols.ISLAND = createSymbol("ISLAND")
symbols.SCRIPT = createSymbol("SCRIPT")
-- Marks a `hydronium.dom` descriptor as an island/script authoring
-- primitive rather than an ordinary HTML/SVG intrinsic -- see
-- hydronium/dom/init.lua. Distinct from symbols.INTRINSIC so `d.lua`/`d.js`
-- cannot be mistaken for a real (fake) `<lua>`/`<js>` HTML element.
symbols.ISLAND_DESCRIPTOR = createSymbol("ISLAND_DESCRIPTOR")
symbols.SCRIPT_DESCRIPTOR = createSymbol("SCRIPT_DESCRIPTOR")

symbols.SCOPE = createSymbol("SCOPE")
symbols.CONTEXT = createSymbol("CONTEXT")
symbols.REF = createSymbol("REF")

symbols.SIGNAL = createSymbol("SIGNAL")
symbols.COMPUTED = createSymbol("COMPUTED")
symbols.EFFECT = createSymbol("EFFECT")

function symbols.isSymbol(val)
  return type(val) == "table" and val.__hydronium_symbol == true
end

function symbols.isType(val, symbol)
  return val == symbol or (symbols.isSymbol(val) and symbols.isSymbol(symbol) and val.name == symbol.name)
end

return symbols
