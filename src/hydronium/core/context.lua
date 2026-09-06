--[[
  Hydronium Context System
  Hierarchical dependency injection and scoped context propagation.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local element = require("hydronium.core.element")

local unpack = table.unpack or unpack

local contextModule = {}

local contextStack = {}
local currentContextMap = {}
local contextIdCounter = 0

function contextModule.createContext(defaultValue)
  contextIdCounter = contextIdCounter + 1
  local ctxId = contextIdCounter

  local context = {
    _typeof = symbols.CONTEXT,
    id = ctxId,
    defaultValue = defaultValue,
  }

  -- Provider component as callable table
  context.Provider = setmetatable({
    __context = context,
    name = "ContextProvider",
  }, {
    __call = function(_, props)
      return element.createElement(symbols.FRAGMENT, nil, props and props.children)
    end,
  })

  return context
end

function contextModule.getCurrentContextMap()
  return currentContextMap
end

function contextModule.pushContext(contextMap)
  table.insert(contextStack, currentContextMap)
  currentContextMap = contextMap
end

function contextModule.popContext()
  if #contextStack > 0 then
    currentContextMap = table.remove(contextStack)
  else
    currentContextMap = {}
  end
end

function contextModule.getContextStackDepth()
  return #contextStack
end

function contextModule.resetContextStack(targetDepth, prevMap)
  targetDepth = targetDepth or 0
  while #contextStack > targetDepth do
    table.remove(contextStack)
  end
  currentContextMap = prevMap or contextStack[#contextStack] or {}
end

function contextModule.withContext(contextMap, fn, ...)
  contextModule.pushContext(contextMap)
  local args = { ... }
  local n = select("#", ...)
  local ok, r1, r2, r3 = pcall(function()
    return fn(unpack(args, 1, n))
  end)
  contextModule.popContext()
  if not ok then
    error(r1, 0)
  end
  return r1, r2, r3
end

function contextModule.useContext(context)
  if not context or context._typeof ~= symbols.CONTEXT then
    error("[Hydronium CONTEXT Error]: useContext must be passed a valid Context object", 2)
  end
  if currentContextMap and currentContextMap[context] ~= nil then
    return currentContextMap[context]
  end
  return context.defaultValue
end

return contextModule
