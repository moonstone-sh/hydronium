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

  Suspension is signalled two ways depending on the caller's context:

  1. Inside a coroutine a Suspense boundary is actively DRIVING (v2 -- see
     the SUSPENSE branch of hydronium_dom/server/init.lua's render_node):
     `coroutine.yield()`s a plain table tagged
     `__hydronium_suspension = true`. A yield freezes the Lua call stack
     in place instead of unwinding it, so the driver can resume exactly
     where `:get()` left off, with every local/upvalue on that stack
     still intact -- unlike `error()`, which destroys the continuation
     entirely.

  2. Everywhere else -- NOT merely "not in a coroutine": also any
     coroutine nobody registered as a Suspense drive target, and any Lua
     without `coroutine.isyieldable` (PUC 5.1) -- `error()`s the same
     tagged table, exactly as v1 always did.

  Why (2) is deliberately narrower than plain `coroutine.isyieldable()`:
  that predicate is true inside ANY coroutine, including ones this
  framework knows nothing about (a per-request-coroutine server, a
  generator in user code, a test harness). Yielding there would send the
  suspension table straight past the caller's own `pcall` -- a yield
  crosses a resumable pcall rather than being caught by it -- to a driver
  that has no idea what a suspension is, leaving that coroutine suspended
  forever with no diagnostic. v1 raised a catchable error in exactly that
  situation, and callers relied on catching it. So a suspension is only
  ever yielded to a driver that explicitly asked for it, via
  `M.markDriven(co)`; everyone else keeps the v1 error contract.

  Either way `M.isSuspension(err)` recognizes the tagged table, so it can
  be distinguished from a real render error without string-matching,
  regardless of whether it arrived via `error()` or `coroutine.yield()`.
--]]

local Resource = {}
Resource.__index = Resource

-- PUC 5.1 has no coroutine.isyieldable (added in 5.2) -- feature-detect
-- rather than version-sniff, so this keeps working unmodified if a future
-- Lua adds it under a different version number too.
local isyieldable = coroutine.isyieldable or function() return false end

--- Coroutines a Suspense boundary is currently driving, i.e. that have a
--- driver which understands a yielded suspension table and will resume
--- them. Weak-keyed so an abandoned coroutine (a boundary that fell back
--- and was never resumed -- the normal case) is collectable and needs no
--- explicit unmark to avoid leaking.
local drivenCoroutines = setmetatable({}, { __mode = "k" })

--- True only when the *currently running* coroutine is one a Suspense
--- driver registered. `coroutine.running()` returns nil on the main
--- thread in 5.1/LuaJIT and the (never-marked) main coroutine in 5.2+,
--- so both spellings of "not in a coroutine" fall through to false.
local function isDrivenHere()
  if not isyieldable() then
    return false
  end
  local co = coroutine.running()
  return co ~= nil and drivenCoroutines[co] == true
end

--[[
  Suspense diagnostic channel.

  Some suspense outcomes are neither a render error (nothing to raise
  toward an ErrorBoundary -- the boundary in question has already
  committed its output and returned) nor success (real content was
  produced and then had nowhere to go). Silently discarding those is the
  one thing this codebase's error policy rules out: every other
  swallow-point here either re-raises (Suspense re-raises non-suspensions
  toward the nearest ErrorBoundary) or reports (Scope:dispose collects
  and surfaces cleanup failures). So they are reported here instead.

  Lives in this module rather than the SSR renderer because both sides
  produce them -- `settle` above (core) and the SSR Suspense boundary
  (hydronium_dom/server/init.lua) -- and this is the module that already
  defines the suspension protocol both of them speak.

  Default handler writes one line to stderr. Replace it with
  `M.setSuspenseDiagnosticHandler(fn)` (pass nil to restore the default,
  `false` to silence) to route diagnostics into a real logger, or to
  assert on them in tests.
--]]
local suspenseDiagnosticHandler = nil

local function defaultSuspenseDiagnosticHandler(diag)
  local line = "[Hydronium Suspense Diagnostic] (" .. tostring(diag.code) .. ") " .. tostring(diag.message)
  if diag.err ~= nil then
    line = line .. "\n  Caused by: " .. tostring(diag.err)
  end
  if io and io.stderr then
    io.stderr:write(line .. "\n")
  end
end

-- Defined above its use in `settle` so both `settle` and the public
-- M.reportSuspenseDiagnostic below share one implementation.
local function reportDiagnostic(diag)
  local handler = suspenseDiagnosticHandler
  if handler == false then
    return
  end
  handler = handler or defaultSuspenseDiagnosticHandler
  -- A broken diagnostic handler must never become a second failure on
  -- top of the one it was reporting.
  pcall(handler, diag)
end

local function new(loader)
  return setmetatable({
    _status = "pending",
    _value = nil,
    _error = nil,
    _loader = loader,
    _waiters = nil, -- lazily created list of coroutines to resume on settle
  }, Resource)
end

--- @return "pending"|"ready"|"failed"
function Resource:status()
  return self._status
end

function Resource:get()
  while true do
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

    if isDrivenHere() then
      -- Freezes this exact call stack (including buffered SSR writes
      -- still on it) and hands control back to the Suspense boundary
      -- driving this coroutine. Looping back to the top on resume
      -- re-checks status, since a driver may resume us speculatively.
      coroutine.yield({ __hydronium_suspension = true, resource = self })
    else
      -- No Suspense driver on this stack (main thread, or a coroutine
      -- owned by someone else): raise, exactly as v1 did, so an
      -- enclosing pcall/ErrorBoundary/render_to_string can see it
      -- instead of the caller hanging on a yield nobody handles.
      error({ __hydronium_suspension = true, resource = self }, 0)
    end
  end
end

--- Register `fn` (a zero-argument function, not a bare coroutine) to run
--- the moment this resource settles. Called by a Suspense boundary right
--- after it catches a yielded suspension for this resource -- see
--- hydronium_dom/server/init.lua. `fn` is the *driver's* resume-and-handle
--- closure, not `coroutine.resume` itself: resuming a coroutine can
--- finish it, make it yield again (on a different resource), or error,
--- and deciding what each of those means (flush buffered output? wait on
--- a new resource? propagate the error?) is the Suspense boundary's
--- buffering discipline to own, not this generic resource's.
function Resource:_addWaiter(fn)
  self._waiters = self._waiters or {}
  table.insert(self._waiters, fn)
end

--- Runs every registered waiter, each in its own `pcall`.
---
--- Two things this deliberately guarantees, both of which the unprotected
--- version got wrong:
---
--- 1. A waiter that throws does NOT abort `settle`. `_waiters` is cleared
---    before iterating (so a waiter re-registering itself can't loop
---    forever), which means an escaping error would have permanently
---    stranded every *later* waiter on this resource -- they had already
---    been detached from the list and would never be reachable again.
---
--- 2. A waiter that throws does NOT escape `Resource:resolve()`/`:reject()`.
---    Those are plain data setters called from arbitrary application code
---    (a cache callback, a socket read, a test); a render error surfacing
---    there would be attributed to a call site that has nothing to do
---    with the component that raised it, and would abort whatever
---    unrelated work was in progress. Waiter failures are reported
---    through the suspense diagnostic channel instead (see
---    M.setSuspenseDiagnosticHandler).
local function settle(self)
  local waiters = self._waiters
  if not waiters then
    return
  end
  self._waiters = nil
  for i = 1, #waiters do
    local ok, err = pcall(waiters[i])
    if not ok then
      reportDiagnostic({
        code = "suspense.waiter_error",
        message = "Hydronium: a Suspense waiter raised while settling a Resource; "
          .. "the error was contained so sibling waiters could still run, and is "
          .. "NOT propagated out of Resource:resolve()/:reject().",
        resource = self,
        err = err,
      })
    end
  end
end

function Resource:resolve(value)
  if self._status ~= "pending" then
    error("Hydronium: Resource:resolve() called on a resource that is already " .. self._status, 2)
  end
  self._status = "ready"
  self._value = value
  settle(self)
end

function Resource:reject(err)
  if self._status ~= "pending" then
    error("Hydronium: Resource:reject() called on a resource that is already " .. self._status, 2)
  end
  self._status = "failed"
  self._error = err
  settle(self)
end

local M = {}

M.new = new

--- @param err any A value caught from pcall
--- @return boolean
function M.isSuspension(err)
  return type(err) == "table" and err.__hydronium_suspension == true
end

--- Declare that `co` is being driven by something that understands a
--- yielded suspension table and will resume it. Only inside such a
--- coroutine does `Resource:get()` suspend by yielding; everywhere else
--- it raises, preserving the v1 contract for coroutines this framework
--- does not own (see the module header).
--- @param co thread
function M.markDriven(co)
  if type(co) == "thread" then
    drivenCoroutines[co] = true
  end
end

--- Undo M.markDriven. Optional -- the registry is weak-keyed, so an
--- abandoned coroutine drops out on its own -- but a driver that is
--- definitively finished with `co` should call this so a *later*
--- accidental resume of the same coroutine gets the v1 error contract
--- rather than yielding into a driver that is no longer listening.
--- @param co thread
function M.unmarkDriven(co)
  if type(co) == "thread" then
    drivenCoroutines[co] = nil
  end
end

--- Test/inspection helper: is `co` currently registered as driven?
--- @param co thread
--- @return boolean
function M.isDriven(co)
  return type(co) == "thread" and drivenCoroutines[co] == true
end

--- Install a suspense diagnostic handler. `fn` receives a table with at
--- least `code` (a stable string id) and `message`, plus optional
--- `resource` / `err` / `after_render` fields. Pass `nil` to restore the
--- default stderr handler, or `false` to silence diagnostics entirely.
--- @param fn fun(diag: table)|nil|false
--- @return fun(diag: table)|nil|false previous handler
function M.setSuspenseDiagnosticHandler(fn)
  local previous = suspenseDiagnosticHandler
  suspenseDiagnosticHandler = fn
  return previous
end

--- Emit a suspense diagnostic through the installed handler. Used by the
--- SSR Suspense boundary as well as by this module's own `settle`.
--- @param diag table
function M.reportSuspenseDiagnostic(diag)
  reportDiagnostic(diag)
end

return M
