--[[
  Hydronium Error Handling & Diagnostic Boundary
  Structured phase errors, component stack tracing, and resilient ErrorBoundary.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")

local unpack = table.unpack or unpack

local errors = {}

local HydroniumError = {}
HydroniumError.__index = HydroniumError

function HydroniumError.new(phase, message, originalError, componentStack)
  local self = setmetatable({}, HydroniumError)
  self.isHydroniumError = true
  self.phase = phase or "unknown"
  self.message = tostring(message or originalError or "An unknown error occurred")
  self.originalError = originalError
  self.componentStack = componentStack or {}
  return self
end

function HydroniumError:formatComponentStack()
  if type(self.componentStack) == "string" then
    return self.componentStack
  end
  if type(self.componentStack) == "table" and #self.componentStack > 0 then
    local lines = {}
    for i = 1, #self.componentStack do
      table.insert(lines, "    at " .. tostring(self.componentStack[i]))
    end
    return table.concat(lines, "\n")
  end
  return ""
end

function HydroniumError:__tostring()
  local stackStr = self:formatComponentStack()
  local out = string.format("[Hydronium %s Error]: %s", string.upper(self.phase), self.message)
  if stackStr ~= "" then
    out = out .. "\nComponent Stack:\n" .. stackStr
  end
  if self.originalError and tostring(self.originalError) ~= self.message then
    out = out .. "\nCaused by: " .. tostring(self.originalError)
  end
  return out
end

errors.HydroniumError = HydroniumError

function errors.isHydroniumError(err)
  return type(err) == "table" and err.isHydroniumError == true
end

function errors.wrapPhaseError(phase, err, componentName, stack)
  if errors.isHydroniumError(err) then
    if componentName then
      table.insert(err.componentStack, 1, componentName)
    end
    return err
  end

  local componentStack = {}
  if componentName then
    table.insert(componentStack, componentName)
  end
  if stack then
    if type(stack) == "table" then
      for i = 1, #stack do
        table.insert(componentStack, stack[i])
      end
    else
      table.insert(componentStack, tostring(stack))
    end
  end

  return HydroniumError.new(phase, tostring(err), err, componentStack)
end

--- ErrorBoundary Component
--- Props:
---   fallback: function(err, retry) or VNode
---   onError: function(err) [optional]
---   children: child nodes
function errors.ErrorBoundary(props)
  -- The ErrorBoundary itself is treated specially by the reconciler/component runtime.
  -- Returning a marker table allowing the reconciler to establish boundary semantics.
  return {
    _typeof = symbols.VNODE,
    kind = symbols.BOUNDARY,
    tag = errors.ErrorBoundary,
    props = props or {},
    children = props and props.children or {},
  }
end

return errors
