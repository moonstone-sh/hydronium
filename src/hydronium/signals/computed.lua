--[[
  Hydronium Computed Primitive
  Memoized derivation with lazy evaluation, fine-grained dependency tracking,
  and protected observer execution.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local graph = require("hydronium.signals.graph")

local unpack = table.unpack or unpack

local computedModule = {}

local function defaultEquals(a, b)
  return a == b
end

local function notifySubscribers(node)
  local subs = {}
  for sub in pairs(node.subscribers) do
    table.insert(subs, sub)
  end

  for i = 1, #subs do
    local sub = subs[i]
    if not sub.isDisposed then
      if sub.notify then
        sub:notify(node)
      elseif sub.markDirty then
        sub:markDirty()
      end
    end
  end
end

function computedModule.createComputed(fn, options)
  local equals = defaultEquals
  if options and options.equals ~= nil then
    if options.equals == false then
      equals = function() return false end
    elseif type(options.equals) == "function" then
      equals = options.equals
    end
  end

  local node = {
    _typeof = symbols.COMPUTED,
    _is_computed = true,
    fn = fn,
    value = nil,
    isDirty = true,
    isDisposed = false,
    sources = {},
    subscribers = {},
    name = options and options.name or "Computed",
  }

  function node:markDirty()
    if not self.isDirty then
      self.isDirty = true
      notifySubscribers(self)
    end
  end

  function node:notify()
    self:markDirty()
  end

  function node:dispose()
    if self.isDisposed then return end
    self.isDisposed = true
    graph.cleanupObserverSources(self)
    self.subscribers = {}
  end

  local function evaluate()
    if node.isDirty then
      -- Re-evaluate with transactional protected observer tracking (Amendment 5)
      local ok, res = pcall(function()
        return graph.runObserver(node, node.fn)
      end)

      if not ok then
        node:dispose()
        local wrapped = errors.wrapPhaseError("render", res)
        error(tostring(wrapped), 0)
      end

      node.value = res
      node.isDirty = false
    end
    return node.value
  end

  local function getter()
    -- If being observed, link node into active observer's sources
    graph.trackSource(node)
    return evaluate()
  end

  local accessor = {
    get = getter,
    dispose = function() node:dispose() end,
    _node = node,
    _is_computed = true,
  }

  setmetatable(accessor, {
    __call = function()
      return getter()
    end,
    __tostring = function()
      return string.format("Computed(%s)", tostring(node.value))
    end,
  })

  return accessor
end

computedModule.computed = computedModule.createComputed

return computedModule
