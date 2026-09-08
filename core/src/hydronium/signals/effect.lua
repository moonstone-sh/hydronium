--[[
  Hydronium Effect Primitive
  Side-effect runner bound to reactive scope, resilient cleanup execution,
  and scheduler queue integration.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local scopeModule = require("hydronium.core.scope")
local scheduler = require("hydronium.core.scheduler")
local graph = require("hydronium.signals.graph")

local unpack = table.unpack or unpack

local effectModule = {}

local Effect = {}
Effect.__index = Effect

function Effect.new(fn)
  local self = setmetatable({}, Effect)
  self._typeof = symbols.EFFECT
  self._is_effect = true
  self.fn = fn
  self.cleanupFn = nil
  self.sources = {}
  self.isDisposed = false
  self.disposed = false
  self.isRunning = false

  -- Bind to current scope if available
  local activeScope = scopeModule.getScope()
  if activeScope then
    activeScope:defer(function()
      self:dispose()
    end)
  end

  -- If SSR mode is active, suppress effect execution to prevent leaks and timers
  if scheduler.isSSR and scheduler.isSSR() then
    self.isDisposed = true
    self.disposed = true
    return self
  end

  -- Initial execution runs immediately with effect protection
  scheduler.setFlushingEffects(true)
  self:execute()
  scheduler.setFlushingEffects(false)
  scheduler.flush()

  return self
end

function Effect:notify()
  if not self.isDisposed then
    scheduler.queueEffect(self)
  end
end

--- Execute the effect callback.
--- Complies with Amendment 2 (resilient cleanup in pcall) and Amendment 5 (protected observer).
function Effect:execute()
  if self.isDisposed or self.isRunning then
    return
  end
  self.isRunning = true

  -- 1. Execute previous cleanup callback in pcall
  if self.cleanupFn then
    local cFn = self.cleanupFn
    self.cleanupFn = nil
    local cOk, cErr = pcall(cFn)
    if not cOk then
      -- Report cleanup error without aborting effect execution
      local wrapped = errors.wrapPhaseError("cleanup", cErr)
    end
  end

  -- 2. Run effect body with transactional tracking (Amendment 5)
  local ok, res = pcall(function()
    return graph.runObserver(self, self.fn)
  end)

  self.isRunning = false

  if not ok then
    self:dispose()
    error(tostring(res), 0)
  end

  if type(res) == "function" then
    self.cleanupFn = res
  end
end

function Effect:run()
  self:execute()
end

function Effect:dispose()
  if self.isDisposed then
    return
  end
  self.isDisposed = true
  self.disposed = true

  graph.cleanupObserverSources(self)

  if self.cleanupFn then
    local cFn = self.cleanupFn
    self.cleanupFn = nil
    pcall(cFn)
  end
end

function effectModule.createEffect(fn)
  return Effect.new(fn)
end

effectModule.effect = effectModule.createEffect
effectModule.Effect = Effect

return effectModule
