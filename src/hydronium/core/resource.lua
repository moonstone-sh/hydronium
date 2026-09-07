--[[
  Hydronium Async Resource Model (v1 -- synchronous/buffered SSR only)

  Three states: "pending", "ready", "failed" -- never conflated. A failed
  resource is an ErrorBoundary concern, not a Suspense one (see
  hydronium/server/init.lua's Suspense handling, which re-raises anything
  that is not a suspension signal so it reaches the nearest ErrorBoundary
  unchanged).

  Two ways a resource can be pending:

  1. `Resource.new(loader)` -- has a loader. `:get()` on first call runs
     `loader()` synchronously (blocking) and resolves to ready/failed
     immediately. This is the "sequential" SSR mode explicitly described
     in the Hydronium/Meteorite streaming architecture note: no visible
     Suspense fallback is ever produced for this shape, because nothing
     observes "pending" between calls -- exactly like an ordinary blocking
     Lua HTTP call would behave. It exists so the *same* Resource/Suspense
     API keeps working once a real deferred/streaming loader model is
     added later, without call sites changing.

  2. `Resource.new()` -- no loader. `:get()` while still pending always
     suspends (see `isSuspension` below); something outside the render
     (test code, a plugin, a future streaming scheduler) must call
     `:resolve(value)` / `:reject(err)`. This is the shape that actually
     exercises a Suspense boundary's `fallback` today.

  Suspension is signalled by `error()`ing a plain table tagged
  `__hydronium_suspension = true`, not a string -- so it can be
  distinguished from a real render error without string-matching.
--]]

local Resource = {}
Resource.__index = Resource

local function new(loader)
  return setmetatable({
    _status = "pending",
    _value = nil,
    _error = nil,
    _loader = loader,
  }, Resource)
end

--- @return "pending"|"ready"|"failed"
function Resource:status()
  return self._status
end

function Resource:get()
  if self._status == "ready" then
    return self._value
  end
  if self._status == "failed" then
    error(self._error, 0)
  end

  -- pending
  if self._loader then
    local loader = self._loader
    self._loader = nil -- run at most once, even if the loader itself errors
    local ok, result = pcall(loader)
    if ok then
      self._status = "ready"
      self._value = result
      return result
    else
      self._status = "failed"
      self._error = result
      error(result, 0)
    end
  end

  error({ __hydronium_suspension = true, resource = self }, 0)
end

function Resource:resolve(value)
  if self._status ~= "pending" then
    error("Hydronium: Resource:resolve() called on a resource that is already " .. self._status, 2)
  end
  self._status = "ready"
  self._value = value
end

function Resource:reject(err)
  if self._status ~= "pending" then
    error("Hydronium: Resource:reject() called on a resource that is already " .. self._status, 2)
  end
  self._status = "failed"
  self._error = err
end

local M = {}

M.new = new

--- @param err any A value caught from pcall
--- @return boolean
function M.isSuspension(err)
  return type(err) == "table" and err.__hydronium_suspension == true
end

return M
