--[[
  Hydronium Scheduler & Reentrancy Defenses
  Phased execution pipeline (Mutation -> Render -> Commit -> Effect),
  batching, cycle detection, and render-phase mutation defenses.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local errors = require("hydronium.core.errors")

local unpack = table.unpack or unpack

local scheduler = {}

local currentRenderingComponent = nil
local isRenderingFlag = false
local isCommittingFlag = false
local isFlushingEffectsFlag = false
local isFlushingFlag = false
local isSSRFlag = false
local batchDepth = 0

local renderQueue = {}
local renderSet = {}

local effectQueue = {}
local effectSet = {}

local effectSignalQueue = {}

local componentStack = {}

local MAX_FLUSH_ITERATIONS = 100

function scheduler.isRendering()
  return isRenderingFlag
end

function scheduler.getCurrentRenderingComponent()
  return currentRenderingComponent
end

function scheduler.setCurrentRenderingComponent(comp)
  currentRenderingComponent = comp
  isRenderingFlag = comp ~= nil
end

function scheduler.isCommitting()
  return isCommittingFlag
end

function scheduler.setCommitting(val)
  isCommittingFlag = val == true
end

function scheduler.isFlushingEffects()
  return isFlushingEffectsFlag
end

function scheduler.setFlushingEffects(val)
  isFlushingEffectsFlag = val == true
end

function scheduler.isSSR()
  return isSSRFlag
end

function scheduler.setSSR(val)
  isSSRFlag = val == true
end

function scheduler.setSSRMode(val)
  isSSRFlag = val == true
end

function scheduler.isBatching()
  return batchDepth > 0
end

function scheduler.startBatch()
  batchDepth = batchDepth + 1
end

function scheduler.endBatch()
  if batchDepth > 0 then
    batchDepth = batchDepth - 1
    if batchDepth == 0 then
      scheduler.flush()
    end
  end
end

function scheduler.cancelBatch()
  if batchDepth > 0 then
    batchDepth = batchDepth - 1
    -- Discard any pending updates created during failed batch
    effectSignalQueue = {}
  end
end

function scheduler.pushComponentStack(name)
  table.insert(componentStack, name or "Anonymous")
end

function scheduler.popComponentStack()
  if #componentStack > 0 then
    table.remove(componentStack)
  end
end

function scheduler.getComponentStack()
  local copy = {}
  for i = 1, #componentStack do
    table.insert(copy, componentStack[i])
  end
  return copy
end

function scheduler.scheduleRender(component)
  if isSSRFlag then
    return
  end
  if not component or component.isMounted == false then
    return
  end
  if not renderSet[component] then
    renderSet[component] = true
    table.insert(renderQueue, component)
  end

  if not scheduler.isBatching() and not scheduler.isRendering() and not isFlushingEffectsFlag and not isFlushingFlag then
    scheduler.flush()
  end
end

function scheduler.queueEffect(effect)
  if isSSRFlag then
    return
  end
  if not effect or effect.isDisposed then
    return
  end
  if not effectSet[effect] then
    effectSet[effect] = true
    table.insert(effectQueue, effect)
  end

  if not scheduler.isBatching() and not scheduler.isRendering() and not isFlushingEffectsFlag and not isFlushingFlag then
    scheduler.flush()
  end
end

--- Queue signal updates originating from within effects.
--- Complies with Amendment 3: ensures Effect phase finishes before next Render phase begins.
function scheduler.queueEffectSignal(fn)
  table.insert(effectSignalQueue, fn)
end

local function sortRenderQueue()
  table.sort(renderQueue, function(a, b)
    local da = a.depth or 0
    local db = b.depth or 0
    return da < db
  end)
end

--- Flush all pending updates through the phased pipeline:
--- 1. Render phase (re-render dirty components)
--- 2. Commit phase (apply tree mutations)
--- 3. Effect phase (run scheduled effects)
--- 4. Deferred signal updates from effects -> loop if needed
function scheduler.flush()
  if isFlushingFlag then
    return
  end
  isFlushingFlag = true

  local ok, flushErr = pcall(function()
    local iterations = 0

    while (#renderQueue > 0 or #effectQueue > 0 or #effectSignalQueue > 0) do
      iterations = iterations + 1
      if iterations > MAX_FLUSH_ITERATIONS then
        renderQueue = {}
        renderSet = {}
        effectQueue = {}
        effectSet = {}
        effectSignalQueue = {}
        error("Cycle detected: maximum reactive update depth exceeded", 0)
      end

      -- Phase 1 & 2: Render & Commit Phase
      while #renderQueue > 0 do
        sortRenderQueue()
        local currentQueue = renderQueue
        local currentSet = renderSet
        renderQueue = {}
        renderSet = {}

        for i = 1, #currentQueue do
          local comp = currentQueue[i]
          if comp.isMounted and comp.isDirty then
            comp:update()
          end
        end
      end

      -- Phase 3: Effect Phase
      if #effectQueue > 0 then
        local currentEffects = effectQueue
        effectQueue = {}
        effectSet = {}

        scheduler.setFlushingEffects(true)
        for i = 1, #currentEffects do
          local eff = currentEffects[i]
          if not eff.isDisposed then
            eff:execute()
          end
        end
        scheduler.setFlushingEffects(false)
      end

      -- Phase 4: Apply queued signal updates from effects
      if #effectSignalQueue > 0 then
        local currentSignalUpdates = effectSignalQueue
        effectSignalQueue = {}
        for i = 1, #currentSignalUpdates do
          local updateFn = currentSignalUpdates[i]
          local uOk, uErr = pcall(updateFn)
          if not uOk then
            error(errors.wrapPhaseError("effect", uErr), 0)
          end
        end
      end
    end
  end)

  isFlushingFlag = false

  if not ok then
    error(flushErr, 0)
  end
end

scheduler.flushSync = scheduler.flush

return scheduler
