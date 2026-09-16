--[[
  hydronium-cli dev_log -- the CLI's own durable dev log,
  `.hydronium/dev.log`.

  WHY A SECOND FILE AT ALL. `.meteorite/dev/events.log` is meteorite's
  transport: its path, lifetime and rotation belong to meteorite, and
  `hydronium dev` only reads it. `.hydronium/dev.log` belongs to
  hydronium, and is the FULL, UNCOLLAPSED stream -- every event tailed out
  of meteorite's file, plus the events this CLI itself originates
  (`"source": "cli"`). The collapsing that the events pane does is display
  only and never reaches this file; a line the pane folded into `x7`, or
  evicted off the top of a 3-row ring, is still here in full. That is
  deliberately the file a later fullscreen request-debug mode should read,
  so it must not be lossy now.

  Same JSON-line schema as the input, so one `cat` over both files is
  meaningful:

    { "v": 1, "ts": <unix ms>, "source": "...", "kind": "...", ... }

  APPEND-ONLY, LINE-AT-A-TIME, FLUSHED. Opened in "a" mode and flushed
  after every line: a dev CLI is routinely killed with Ctrl-C or SIGTERM,
  and C stdio's default full buffering would silently lose whatever was
  still in the buffer (the exact failure examples/ink_demo/run.lua's own
  `setvbuf("no")` comment documents hitting for real).

  Encoding reuses `hydronium_router.history.state` -- see
  src/event_model.lua's note on why that module, and not a second
  hand-written codec, is the JSON layer here. It sorts object keys, so the
  field order in this file is alphabetical rather than matching
  meteorite's own emitter byte-for-byte; the schema is the contract, not
  the byte order.
--]]

local json = require("hydronium_router.history.state")

local M = {}

M.DEFAULT_PATH = ".hydronium/dev.log"

--- Real wall-clock unix milliseconds, via hydronium_ink.clock
--- (`gettimeofday`) when it is available -- deliberately NOT
--- `os.clock()`, which measures CPU time and is near-zero in a process
--- that spends its life blocked in a poll loop (see that module's own doc
--- comment). Falls back to `os.time()` (whole seconds) where the FFI
--- clock cannot load, e.g. a non-LuaJIT or Windows host: coarser, but a
--- timestamp is still a timestamp.
--- @return number
local resolved_clock = nil -- nil = not looked up yet, false = unavailable
function M.now_ms()
  -- Looked up once: this runs on every event-loop turn.
  if resolved_clock == nil then
    local loaded, module = pcall(require, "hydronium_ink.clock")
    resolved_clock = (loaded and type(module) == "table" and module.nowMs and module) or false
  end
  if resolved_clock then
    local timed, value = pcall(resolved_clock.nowMs)
    if timed then
      -- gettimeofday's microseconds/1000 leave a fraction; the wire
      -- format is whole unix milliseconds, same as meteorite's own `ts`.
      return math.floor(value)
    end
  end
  return os.time() * 1000
end

--- Builds an event originated by this CLI (as opposed to one tailed out
--- of meteorite's file, which is already a complete event).
--- @param kind string
--- @param fields? table
--- @return table
function M.cli_event(kind, fields)
  local event = { v = 1, ts = M.now_ms(), source = "cli", kind = kind }
  for key, value in pairs(fields or {}) do
    if key ~= "v" and key ~= "ts" and key ~= "source" and key ~= "kind" then
      event[key] = value
    end
  end
  return event
end

--- Reads an existing durable log back into events, newest-last.
---
--- This is the read side of the "durable superset" contract at the top of
--- this file: the fullscreen request-debug view (see src/inspector.lua and
--- src/ui/inspector_view.lua) is specified to show every request event in
--- `.hydronium/dev.log`, not just the ones the collapsed display buffer
--- happens to still be holding. The file is append-only across runs, so
--- this also brings back a PREVIOUS session's requests -- which is the
--- point of a durable log, but is why `limit` exists: only the last
--- `limit` matching events are kept, oldest dropped first, so a log that
--- has been accumulating for weeks cannot turn into unbounded memory at
--- startup.
---
--- Never raises and never reports a missing file as an error: no log yet
--- is the ordinary first-run state.
--- @param path? string
--- @param opts? { filter?: fun(event: table): boolean, limit?: integer, open?: fun(path: string, mode: string): file*|nil }
--- @return table[] events, integer skipped Lines that were not usable events.
function M.read_events(path, opts)
  opts = opts or {}
  path = path or M.DEFAULT_PATH
  local open = opts.open or io.open
  local limit = opts.limit
  local filter = opts.filter

  local file = open(path, "rb")
  if not file then
    return {}, 0
  end

  local event_model = require("event_model")
  local events, skipped = {}, 0
  for line in file:lines() do
    local event = event_model.parse_line(line)
    if event then
      if not filter or filter(event) then
        events[#events + 1] = event
        if limit and #events > limit then
          table.remove(events, 1)
        end
      end
    elseif line:gsub("%s+", "") ~= "" then
      skipped = skipped + 1
    end
  end
  file:close()

  return events, skipped
end

local Log = {}
Log.__index = Log
M.Log = Log

--- @class hydronium_cli.DevLogOptions
--- @field open? fun(path: string, mode: string): file*|nil Injectable; defaults to io.open.
--- @field exec? function Injectable; defaults to os.execute (used only for `mkdir -p`).

--- Opens (creating the directory if missing) `.hydronium/dev.log`.
--- @param path? string
--- @param opts? hydronium_cli.DevLogOptions
--- @return table|nil log, string|nil err
function M.open(path, opts)
  opts = opts or {}
  path = path or M.DEFAULT_PATH
  local open = opts.open or io.open
  local exec = opts.exec or os.execute

  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" then
    local supervisor = require("dev_supervisor")
    supervisor.ensure_dir(dir, exec)
  end

  local file, err = open(path, "a")
  if not file then
    return nil, tostring(err or ("could not open " .. path))
  end

  return setmetatable({ path = path, file = file, written = 0 }, Log)
end

--- Appends one event as a single JSON line. Returns false plus a reason
--- rather than raising if the value is not JSON-shaped -- a malformed
--- event from a future meteorite must not take the dev UI down with it.
--- @param event table
--- @return boolean ok, string|nil err
function Log:append(event)
  if type(event) ~= "table" then
    return false, "event must be a table"
  end
  local ok, encoded = pcall(json.encode, event)
  if not ok then
    return false, tostring(encoded)
  end
  self.file:write(encoded, "\n")
  self.file:flush()
  self.written = self.written + 1
  return true
end

--- Appends several events in order; returns how many landed.
--- @param events table[]
--- @return integer
function Log:append_all(events)
  local count = 0
  for _, event in ipairs(events or {}) do
    if self:append(event) then
      count = count + 1
    end
  end
  return count
end

function Log:close()
  if self.file then
    self.file:close()
    self.file = nil
  end
end

return M
