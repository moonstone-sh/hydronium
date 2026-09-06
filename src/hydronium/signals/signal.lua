--[[
  Hydronium Signal Primitive
  Fine-grained reactive state container with render-phase mutation guard,
  effect-deferred subscriber scheduling, and dual-style API accessors.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local scheduler = require("hydronium.core.scheduler")
local graph = require("hydronium.signals.graph")

local unpack = table.unpack or unpack

local signalModule = {}

local function defaultEquals(a, b)
  return a == b
end

local function notifySubscribers(source)
  local subs = {}
  for sub in pairs(source.subscribers) do
    table.insert(subs, sub)
  end

  for i = 1, #subs do
    local sub = subs[i]
    if not sub.isDisposed then
      if sub.notify then
        sub:notify(source)
      elseif sub.markDirty then
        sub:markDirty()
      end
    end
  end
end

function signalModule.createSignal(initialValue, options)
  local equals = defaultEquals
  if options and options.equals ~= nil then
    if options.equals == false then
      equals = function() return false end
    elseif type(options.equals) == "function" then
      equals = options.equals
    end
  end

  local signal = {
    _typeof = symbols.SIGNAL,
    value = initialValue,
    subscribers = {},
    name = options and options.name or "Signal",
    equals = equals,
  }

  local accessor = {}

  local function getter()
    graph.trackSource(signal)
    return signal.value
  end

  local function setter(...)
    local n = select("#", ...)
    local newVal
    if n >= 2 and select(1, ...) == accessor then
      newVal = select(2, ...)
    else
      newVal = select(1, ...)
    end

    local resolvedVal = newVal
    if type(newVal) == "function" then
      resolvedVal = newVal(signal.value)
    end

    if equals(signal.value, resolvedVal) then
      return signal.value
    end

    -- Amendment 3: Render-phase mutation guard
    if scheduler.isRendering() then
      local comp = scheduler.getCurrentRenderingComponent()
      local compName = comp and (comp.name or "Component") or "Component"
      local err = errors.wrapPhaseError(
        "render",
        string.format(
          "ERR_RENDER_MUTATION: Cannot update signal '%s' during render phase of component '%s'. Render functions must be pure.",
          signal.name,
          compName
        ),
        compName,
        scheduler.getComponentStack()
      )
      error(tostring(err), 0)
    end

    -- Amendment 3: Queue signal updates from effects safely
    if scheduler.isFlushingEffects() then
      signal.value = resolvedVal
      scheduler.queueEffectSignal(function()
        notifySubscribers(signal)
      end)
      return signal.value
    end

    signal.value = resolvedVal

    if scheduler.isBatching() then
      notifySubscribers(signal)
    else
      notifySubscribers(signal)
      scheduler.flush()
    end

    return signal.value
  end

  local function methodGetter(...)
    return getter()
  end

  local function methodSetter(self_or_val, maybeVal)
    if self_or_val == accessor then
      return setter(maybeVal)
    else
      return setter(self_or_val)
    end
  end

  accessor.get = methodGetter
  accessor.set = methodSetter
  accessor.tuple = function() return getter, setter end
  accessor._signal = signal
  accessor._is_signal = true

  setmetatable(accessor, {
    __index = function(t, k)
      if k == 1 then
        return getter
      elseif k == 2 then
        return setter
      end
      return rawget(t, k)
    end,
    __call = function(t, ...)
      local n = select("#", ...)
      if n == 0 then
        return getter()
      else
        return setter(...)
      end
    end,
    __tostring = function()
      return string.format("Signal(%s)", tostring(signal.value))
    end,
  })

  return accessor, setter
end

signalModule.signal = signalModule.createSignal

return signalModule
