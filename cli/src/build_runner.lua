--[[
  hydronium-cli build_runner -- the headless engine behind `hydronium
  build` (see main.lua's `M.build`). Everything here is pure Lua/ballad,
  with no hydronium_ink dependency, so M1 ("must be fully provable
  headless") does not need the Ink renderer at all; ui/build_view.lua (M2)
  is a thin presentation layer over the same Runner this module exposes.

  ARCHITECTURE, in order:

  1. `M.load(filepath, jobs, invocation_args)` -- loads the project's
     declared partiture.lua via `ballad.partiture.load` and returns the
     Pipeline. Decision #1 ("build runs only what is declared"): no
     partiture.lua, or one that fails to load/evaluate, is a clear error
     here, never a guess about what the project probably wanted.

  2. `M.new_runner(p)` -- wraps `p:execute()` in a coroutine. Ballad's own
     execute loop (ballad/src/ballad/pipeline.lua) now calls
     `coroutine.yield()` once per graph node IF it is running inside a
     yieldable coroutine (a no-op, additive checkpoint for every existing
     ballad consumer that calls `p:execute()` directly, off the main
     coroutine). Wrapping it here turns that into real cooperative
     single-step execution: `Runner:step()` advances the pipeline by
     exactly one node and returns whatever new NDJSON events (M0,
     `.ballad/runs/<run_id>/events.ndjson`) that node wrote. This is what
     lets `--plain`/`--ndjson` (and M2's Ink view) show progress as it
     actually happens, in one Lua process, in-process (per the "verified
     starting facts": require("ballad") in-process, never a subprocess
     scraping stdout) -- with NO changes to ballad's public execute()
     signature or a new callback API.

  3. `Runner:step()` returns one of:
       "yielded", nil,    {new events}   -- one node done, more to go
       "done",    results, {new events}  -- execute() returned normally
       "error",   err,     {new events}  -- a node raised (or the
                                             partiture's own execute()
                                             threw for some other reason)
     `results` on "done" is execute()'s own return value (the sink
     results list `ballad.cli`'s `play` command also gets).
--]]

local partiture = require("ballad.partiture")
local json = require("hydronium_router.history.state")

local M = {}

--- @alias BuildExitCode integer
M.EXIT_OK = 0
M.EXIT_USAGE = 1
M.EXIT_PARTITURE_ERROR = 2
M.EXIT_PIPELINE_FAILED = 3
M.EXIT_VERIFY_FAILED = 4
M.EXIT_VITE_FAILED = 5

M.DEFAULT_PARTITURE = "partiture.lua"

--- Decision #1: no partiture.lua (or one that fails to load/build) is a
--- clear, immediate error -- never inferred from template name, directory
--- layout, or which dependencies happen to be installed.
--- @param filepath string
--- @param jobs? integer
--- @param invocation_args? string[]
--- @return Pipeline|nil pipeline
--- @return string|nil err
function M.load(filepath, jobs, invocation_args)
  local probe = io.open(filepath, "r")
  if not probe then
    return nil, "no " .. filepath .. " in this project -- `hydronium build` runs only what a partiture "
      .. "declares (see `moon exec -- ballad init --template <name>` to scaffold one, or "
      .. "`hydronium create` for a full project template)"
  end
  probe:close()

  local ok, result = pcall(partiture.load, filepath, jobs, invocation_args)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

local Runner = {}
Runner.__index = Runner

--- @param p Pipeline From M.load.
--- @return table runner
function M.new_runner(p)
  local run_id = p._context._run_id
  local self = setmetatable({
    plan = p:plan(),
    run_id = run_id,
    events_path = ".ballad/runs/" .. run_id .. "/events.ndjson",
    _co = coroutine.create(function() return p:execute() end),
    _offset = 0,
  }, Runner)
  return self
end

--- Every event line appended to this run's events.ndjson since the last
--- call, in file order. Reopens the file each call rather than holding a
--- handle open across yields -- the file may not exist yet before the
--- first node writes it, and it is only ever appended to, never rewritten,
--- so re-seeking to a saved byte offset is safe.
--- @return table[] events
function Runner:_drain_new_events()
  local events = {}
  local f = io.open(self.events_path, "r")
  if not f then
    return events
  end
  f:seek("set", self._offset)
  local chunk = f:read("*a") or ""
  self._offset = f:seek()
  f:close()
  for line in chunk:gmatch("[^\r\n]+") do
    local ok, decoded = pcall(json.decode, line)
    if ok and type(decoded) == "table" then
      events[#events + 1] = decoded
    end
    -- A line that fails to decode is a genuine oddity (e.g. read mid-write
    -- by a native task's own writer -- see ballad's write_event, which
    -- always writes one whole line per call, so this should not happen in
    -- practice for THIS file, unlike a tailed log written by another
    -- process). Skipped rather than raised: one bad line must not sink an
    -- otherwise-successful build's progress reporting.
  end
  return events
end

--- Advance the pipeline by exactly one node (or run it to completion if it
--- never yields, e.g. a partiture with zero nodes).
--- Ballad's own `Pipeline:execute()` makes a handful of bare `print()`
--- calls of its own (a cache hit, "Graph debug written to ..." once at the
--- end) -- fine for `ballad play`'s own human-readable CLI, but a stray
--- line on this process's stdout would corrupt --ndjson's "one JSON object
--- per line" contract and the Ink view's terminal control both. Redirected
--- to stderr for the duration of one step rather than silenced outright:
--- these lines are still real information (e.g. which node cache-hit),
--- just not on the channel that has a format contract.
--- @param fn fun(): any
--- @return any ...
local function with_stdout_prints_redirected(fn)
  local original_print = print
  _G.print = function(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
      parts[i] = tostring((select(i, ...)))
    end
    io.stderr:write(table.concat(parts, "\t") .. "\n")
  end
  local ok, a, b = pcall(fn)
  _G.print = original_print
  if not ok then
    error(a, 0)
  end
  return a, b
end

--- @return "yielded"|"done"|"error" status
--- @return any results_or_err execute()'s return value on "done", the
---   raised error on "error", nil on "yielded"
--- @return table[] new_events
function Runner:step()
  local ok, result = with_stdout_prints_redirected(function()
    return coroutine.resume(self._co)
  end)
  local new_events = self:_drain_new_events()
  if not ok then
    return "error", result, new_events
  end
  if coroutine.status(self._co) == "dead" then
    return "done", result, new_events
  end
  return "yielded", nil, new_events
end

--- Drive a Runner to completion, calling `on_events(events)` (if given)
--- after every step with that step's newly-drained events (possibly an
--- empty table). Used by both headless output modes (--plain/--ndjson);
--- the Ink view (M2) drives its own Runner directly instead, since it also
--- needs to redraw between steps rather than only react to events.
--- @param runner table From M.new_runner.
--- @param on_events? fun(events: table[])
--- @return "done"|"error" status
--- @return any results_or_err
function M.drain(runner, on_events)
  while true do
    local status, result, events = runner:step()
    if on_events and #events > 0 then
      on_events(events)
    end
    if status ~= "yielded" then
      return status, result
    end
  end
end

M.Runner = Runner

return M
