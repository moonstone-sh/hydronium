--[[
  Hydronium Reactive Dependency Graph
  Fine-grained Publisher-Subscriber graph with dynamic dependency tracking,
  transactional updates, and protected observer evaluation.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local unpack = table.unpack or unpack

local graph = {}

local trackingStack = {}
local currentObserver = nil

function graph.getCurrentObserver()
  return currentObserver
end

function graph.isTracking()
  return currentObserver ~= nil
end

function graph.pushObserver(obs)
  table.insert(trackingStack, obs)
  currentObserver = obs
end

function graph.popObserver()
  if #trackingStack > 0 then
    table.remove(trackingStack)
    currentObserver = trackingStack[#trackingStack]
  else
    currentObserver = nil
  end
end

--- Execute a function without reactive tracking.
function graph.untrack(fn, ...)
  local prevStack = trackingStack
  local prevObserver = currentObserver
  trackingStack = {}
  currentObserver = nil

  local args = { ... }
  local n = select("#", ...)
  local ok, res1, res2, res3 = pcall(function()
    return fn(unpack(args, 1, n))
  end)

  trackingStack = prevStack
  currentObserver = prevObserver

  if not ok then
    error(res1, 0)
  end
  return res1, res2, res3
end

--- Connect a source (Signal or Computed) to the currently active observer.
function graph.trackSource(source)
  if currentObserver and not currentObserver.isDisposed then
    source.subscribers[currentObserver] = true
    currentObserver.sources[source] = true
  end
end

--- Clear all existing source dependencies from an observer before re-evaluation.
function graph.cleanupObserverSources(obs)
  if obs.sources then
    for source in pairs(obs.sources) do
      if source.subscribers then
        source.subscribers[obs] = nil
      end
    end
    obs.sources = {}
  end
end

--- Protected observer evaluation with strict stack restoration.
--- Complies with Amendment 5: ensures tracking stack is ALWAYS restored on error!
function graph.runObserver(obs, fn, ...)
  graph.cleanupObserverSources(obs)
  graph.pushObserver(obs)

  local args = { ... }
  local n = select("#", ...)
  local ok, res1, res2, res3 = pcall(function()
    return fn(unpack(args, 1, n))
  end)

  graph.popObserver()

  if not ok then
    error(res1, 0)
  end
  return res1, res2, res3
end

return graph
