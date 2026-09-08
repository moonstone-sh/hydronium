--[[
  Hydronium Scope System
  Hierarchical lifetime management, resilient LIFO cleanup execution, and scope stacks.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
  Does NOT rely on __gc for cleanup semantics.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")

local unpack = table.unpack or unpack

local scopeModule = {}

local scopeStack = {}
local currentScope = nil

local Scope = {}
Scope.__index = Scope

local globalScopeCounter = 0

function Scope.new(parent)
  globalScopeCounter = globalScopeCounter + 1
  local self = setmetatable({}, Scope)
  self._typeof = symbols.SCOPE
  self.scopeId = globalScopeCounter
  self.parent = parent
  self.children = {}
  self.cleanups = {}
  self.idCounters = {}
  self.isDisposed = false

  if parent and not parent.isDisposed then
    table.insert(parent.children, self)
  end

  return self
end

function Scope:id(prefix)
  prefix = prefix or "id"
  self.idCounters[prefix] = (self.idCounters[prefix] or 0) + 1
  return string.format(":r%d:%s_%d", self.scopeId, prefix, self.idCounters[prefix])
end

function Scope:resetIdCounters()
  self.idCounters = {}
end

function Scope:defer(cleanupFn)
  if type(cleanupFn) ~= "function" then
    return
  end
  if self.isDisposed then
    -- If already disposed, execute cleanup immediately in protected call
    local ok, err = pcall(cleanupFn)
    if not ok then
      local wrapped = errors.wrapPhaseError("cleanup", err)
      error(tostring(wrapped), 0)
    end
    return
  end
  table.insert(self.cleanups, cleanupFn)
end

function Scope:createChild()
  return Scope.new(self)
end

--- Dispose this scope and all nested children in LIFO order.
--- Complies with Amendment 2: wrap all cleanups in pcall, collect errors, continue executing.
function Scope:dispose()
  if self.isDisposed then
    return
  end
  self.isDisposed = true

  local caughtErrors = {}

  -- 1. Dispose children in reverse order
  local numChildren = #self.children
  for i = numChildren, 1, -1 do
    local child = self.children[i]
    if child and not child.isDisposed then
      local ok, err = pcall(function()
        child:dispose()
      end)
      if not ok then
        table.insert(caughtErrors, err)
      end
    end
  end
  self.children = {}

  -- 2. Execute registered cleanups in LIFO order
  local numCleanups = #self.cleanups
  for i = numCleanups, 1, -1 do
    local fn = self.cleanups[i]
    local ok, err = pcall(fn)
    if not ok then
      table.insert(caughtErrors, errors.wrapPhaseError("cleanup", err))
    end
  end
  self.cleanups = {}

  -- 3. Detach from parent if parent is still active
  if self.parent and not self.parent.isDisposed then
    local pChildren = self.parent.children
    for i = 1, #pChildren do
      if pChildren[i] == self then
        table.remove(pChildren, i)
        break
      end
    end
  end

  -- If any cleanup failed, bubble or report errors
  if #caughtErrors > 0 then
    if #caughtErrors == 1 then
      error(tostring(caughtErrors[1]), 0)
    else
      local msgs = {}
      for idx, e in ipairs(caughtErrors) do
        table.insert(msgs, string.format("  [%d]: %s", idx, tostring(e)))
      end
      local combined = "[Hydronium CLEANUP Error]: Multiple cleanup failures:\n" .. table.concat(msgs, "\n")
      error(combined, 0)
    end
  end
end

function scopeModule.createScope(fn)
  local scope = Scope.new(currentScope)
  if fn then
    local res
    local ok, err = pcall(function()
      res = scopeModule.runWithScope(scope, fn, scope)
    end)
    if not ok then
      -- If execution failed, dispose scope and rethrow
      pcall(function() scope:dispose() end)
      error(err, 0)
    end
    return res, scope
  end
  return scope
end

function scopeModule.getScope()
  return currentScope
end

function scopeModule.pushScope(scope)
  table.insert(scopeStack, scope)
  currentScope = scope
end

function scopeModule.popScope()
  if #scopeStack > 0 then
    table.remove(scopeStack)
    currentScope = scopeStack[#scopeStack]
  else
    currentScope = nil
  end
end

function scopeModule.getScopeStackDepth()
  return #scopeStack
end

function scopeModule.resetScopeStack(targetDepth)
  targetDepth = targetDepth or 0
  while #scopeStack > targetDepth do
    table.remove(scopeStack)
  end
  currentScope = scopeStack[#scopeStack]
end

function scopeModule.runWithScope(scope, fn, ...)
  scopeModule.pushScope(scope)
  local args = { ... }
  local numArgs = select("#", ...)

  local ok, res1, res2, res3, res4 = pcall(function()
    return fn(unpack(args, 1, numArgs))
  end)

  scopeModule.popScope()

  if not ok then
    error(res1, 0)
  end
  return res1, res2, res3, res4
end

function scopeModule.onCleanup(fn)
  if currentScope then
    currentScope:defer(fn)
  else
    -- Outside of an active scope, onCleanup is a no-op or warns
  end
end

scopeModule.Scope = Scope

return scopeModule
