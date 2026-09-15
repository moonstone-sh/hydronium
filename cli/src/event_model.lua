--[[
  hydronium-cli event_model -- the pure, host-agnostic half of `hydronium
  dev`: parsing Meteorite's dev-event JSON lines, turning each event into
  one display label, and collapsing consecutive repeats into a small
  fixed-capacity ring buffer.

  PURE BY CONTRACT: this module opens no files, spawns no processes, and
  reads no clock. Every timestamp it uses comes out of the event itself
  (`ts`), which is what makes the collapse window unit-testable with a
  canned array of lines and no real meteorite process anywhere (see
  cli/tests/event_model_spec.lua).

  WIRE FORMAT (written by meteorite into `.meteorite/dev/events.log`,
  newline-delimited, one JSON object per line):

    { "v": 1, "ts": <unix ms>, "source": "server"|"supervisor"|"cli",
      "kind": "<kind>", ...fields }

    startup     (supervisor) routes, mode, backend, ready_ms
    request     (server)     method, path, status, duration_ms, remote_addr?
    rebuild     (supervisor) reason, action, partitions
    reload      (supervisor) ok
    build_error (supervisor) stage, detail
    server_exit (supervisor) pid, reason

  ENVELOPE-ONLY VALIDATION, deliberately. `parse_line` rejects a line only
  when the *envelope* is wrong (not valid JSON, not an object, wrong `v`,
  missing/mistyped `ts`/`source`/`kind`) -- it does NOT reject an
  unrecognized `kind`. A newer meteorite emitting a kind this CLI has
  never heard of still reaches `.hydronium/dev.log` verbatim (that file is
  meant to be the durable superset, see src/dev_log.lua) and still renders
  as a line, just with a generic label. What gets skipped is genuine
  garbage -- including a line read mid-write by the tailer, which is the
  normal, expected case here since another process appends to that file
  concurrently.

  JSON: reuses `hydronium_router.history.state`, this repo's only real
  JSON *decoder* (hydronium_dom.server.json is encode-only). Its name is
  about where it is used, not what it is -- its own doc comment describes
  it as a "JSON-shaped ... codec" over "nil, booleans, finite numbers,
  strings, and acyclic arrays or objects", it requires nothing itself, and
  it is strict (it raises on trailing data, bad escapes, unterminated
  strings), which is exactly the behaviour a half-written line needs.
  Duplicating a second ~200-line strict parser into this package to avoid
  one path-dependency on a zero-dependency leaf module would be worse.
--]]

local json = require("hydronium_router.history.state")

local M = {}

--- The only `v` this CLI understands. A line carrying any other version is
--- skipped rather than guessed at -- forward compatibility here means "do
--- not misread a future schema", not "try anyway".
M.SCHEMA_VERSION = 1

--- Visible rows in the collapsed events pane by default. `--verbose`
--- raises this (display density only -- see main.lua); it never changes
--- what is captured.
M.DEFAULT_CAPACITY = 3

--- Rows under `--verbose`.
M.VERBOSE_CAPACITY = 12

--- An event collapses into the current tail line only if it arrives
--- within this many ms of that line's `last_ts`.
M.COLLAPSE_WINDOW_MS = 2000

--- Known dev-transport endpoints, seeded from the paths hydronium's own
--- dom/router dev machinery actually serves (grepped out of the real
--- sources rather than invented):
---   dom/src/hydronium_dom/dev/watch.lua  -> /__hydronium/watch (SSE live-reload)
---   the HMR/module/client routes the dev templates register
---     -> /__hydronium/hmr, /__hydronium/dev/module/..., /__hydronium/client,
---        /__hydronium/client_manifest
---
--- Purpose is PRESENTATION ONLY. The target mock's "hmr reconnect" line
--- is not a distinct event kind and there is no push transport to
--- reconnect to (meteorite's `app:websocket()` errors as unsupported) --
--- it is simply how a repeated `request` against one of these paths is
--- displayed. Anyone going looking for an `hmr_reconnect` event will not
--- find one, by design.
---
--- Ordered, first match wins, matched as a plain substring of the request
--- path -- so the more specific `/__hydronium/client_manifest` must come
--- before `/__hydronium/client`.
M.DEV_ENDPOINT_ALIASES = {
  { match = "/__hydronium/watch", label = "hmr watch" },
  { match = "/__hydronium/hmr", label = "hmr reconnect" },
  { match = "/__hydronium/dev/module", label = "module fetch" },
  { match = "/__hydronium/client_manifest", label = "client manifest" },
  { match = "/__hydronium/client", label = "client bundle" },
}

--- @param path string|nil
--- @param aliases table|nil Defaults to M.DEV_ENDPOINT_ALIASES.
--- @return string|nil label, string|nil matched substring
function M.alias_for(path, aliases)
  if type(path) ~= "string" then
    return nil
  end
  for _, alias in ipairs(aliases or M.DEV_ENDPOINT_ALIASES) do
    if path:find(alias.match, 1, true) then
      return alias.label, alias.match
    end
  end
  return nil
end

--- Parses one raw line into an event table, or returns nil plus a reason
--- when the line is not a usable event. Never raises: a decode failure on
--- a partially-written line is an ordinary, expected outcome.
--- @param line any
--- @return table|nil event, string|nil reason
function M.parse_line(line)
  if type(line) ~= "string" then
    return nil, "not a string"
  end
  -- A tailer hands over exactly what was between two newlines; a CRLF
  -- writer would leave the \r attached.
  local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return nil, "blank"
  end

  local ok, decoded = pcall(json.decode, trimmed)
  if not ok then
    return nil, "invalid json"
  end
  if type(decoded) ~= "table" then
    return nil, "not an object"
  end
  if decoded.v ~= M.SCHEMA_VERSION then
    return nil, "unsupported schema version"
  end
  if type(decoded.ts) ~= "number" then
    return nil, "missing ts"
  end
  if type(decoded.source) ~= "string" or decoded.source == "" then
    return nil, "missing source"
  end
  if type(decoded.kind) ~= "string" or decoded.kind == "" then
    return nil, "missing kind"
  end
  return decoded
end

--- Parses an array of raw lines, dropping the ones that are not usable
--- events. Order-preserving.
--- @param lines string[]
--- @return table[] events, table[] rejected `{ line, reason }` entries
function M.parse_lines(lines)
  local events, rejected = {}, {}
  for _, line in ipairs(lines or {}) do
    local event, reason = M.parse_line(line)
    if event then
      events[#events + 1] = event
    else
      rejected[#rejected + 1] = { line = line, reason = reason }
    end
  end
  return events, rejected
end

--- The collapse key.
---
--- CHOICE, stated: for `request` events it is `method .. " " .. path` --
--- so a burst of polls against one endpoint folds into one line, while
--- the same path under a different method, or a different path, does not.
--- Status and duration are deliberately NOT part of it: two consecutive
--- 200s that took 51ms and 48ms are the same line in the mock, and a
--- duration in the key would defeat collapsing entirely. For every other
--- kind the signature is just the kind, which is the right granularity
--- for `reload`/`rebuild`/`server_exit` bursts.
--- @param event table
--- @return string
function M.signature(event)
  if event.kind == "request" then
    return tostring(event.method or "?") .. " " .. tostring(event.path or "?")
  end
  return tostring(event.kind)
end

local function format_ms(value)
  if type(value) ~= "number" then
    return nil
  end
  return string.format("%dms", math.floor(value + 0.5))
end

local function partition_count(partitions)
  if type(partitions) == "number" then
    return partitions
  end
  if type(partitions) == "table" then
    return #partitions
  end
  return nil
end

local function one_line(text, limit)
  local s = tostring(text):gsub("[\r\n]+", " ")
  if #s > limit then
    s = s:sub(1, limit - 3) .. "..."
  end
  return s
end

--- @class hydronium_cli.LabelOptions
--- @field show_ips? boolean Append `remote_addr` to `request` labels. Off by default -- IP capture is opt-in (`--show-ips`) and independent of `--verbose`.
--- @field aliases? table Defaults to M.DEV_ENDPOINT_ALIASES.

--- One display line for one event, with no count suffix (that is
--- `M.format_entry`'s job, since the count lives on the ring entry, not
--- on any single event).
--- @param event table
--- @param opts? hydronium_cli.LabelOptions
--- @return string
function M.label(event, opts)
  opts = opts or {}
  local kind = event.kind

  if kind == "request" then
    local alias = M.alias_for(event.path, opts.aliases)
    local parts = { alias or (tostring(event.method or "?") .. " " .. tostring(event.path or "?")) }
    -- Status is shown only when it is not a success/redirect. The target
    -- mock's line is `GET /home · 51ms` -- a `200` on every row is noise;
    -- a 404/500 is the one thing you actually need to see at a glance.
    local status = tonumber(event.status)
    if status and (status < 200 or status >= 400) then
      parts[#parts + 1] = tostring(math.floor(status))
    end
    local ms = format_ms(event.duration_ms)
    if ms then
      parts[#parts + 1] = ms
    end
    if opts.show_ips and type(event.remote_addr) == "string" and event.remote_addr ~= "" then
      parts[#parts + 1] = event.remote_addr
    end
    return table.concat(parts, " \194\183 ")
  end

  if kind == "startup" then
    local parts = { "server ready" }
    if event.mode or event.backend then
      parts[#parts + 1] = tostring(event.mode or "?") .. "/" .. tostring(event.backend or "?")
    end
    local ms = format_ms(event.ready_ms)
    if ms then
      parts[#parts + 1] = ms
    end
    return table.concat(parts, " \194\183 ")
  end

  if kind == "rebuild" then
    local head = "rebuild"
    if event.reason then
      head = head .. " \194\183 " .. one_line(event.reason, 48)
    end
    if event.action then
      head = head .. " \226\134\146 " .. tostring(event.action)
    end
    local n = partition_count(event.partitions)
    if n and n > 0 then
      head = head .. " (" .. n .. (n == 1 and " partition)" or " partitions)")
    end
    return head
  end

  if kind == "reload" then
    return event.ok and "reload ok" or "reload failed"
  end

  if kind == "build_error" then
    local head = "build error"
    if event.stage then
      head = head .. " \194\183 " .. tostring(event.stage)
    end
    if event.detail then
      head = head .. ": " .. one_line(event.detail, 64)
    end
    return head
  end

  if kind == "server_exit" then
    local head = "server exited"
    if event.reason then
      head = head .. " \194\183 " .. one_line(event.reason, 40)
    end
    if event.pid then
      head = head .. " (pid " .. tostring(math.floor(tonumber(event.pid) or 0)) .. ")"
    end
    return head
  end

  -- Unrecognized kind from a newer emitter: still shown, still logged.
  return tostring(kind)
end

--- @param entry table A ring-buffer entry.
--- @return string
function M.format_entry(entry)
  if entry.count and entry.count > 1 then
    return entry.label .. " x" .. tostring(entry.count)
  end
  return entry.label
end

-- ---------------------------------------------------------------------
-- Collapse/dedup ring buffer
-- ---------------------------------------------------------------------

local Buffer = {}
Buffer.__index = Buffer
M.Buffer = Buffer

--- @class hydronium_cli.BufferOptions
--- @field capacity? integer Visible rows. Default M.DEFAULT_CAPACITY (3).
--- @field window_ms? number Collapse window. Default M.COLLAPSE_WINDOW_MS (2000).
--- @field show_ips? boolean
--- @field aliases? table

--- @param opts? hydronium_cli.BufferOptions
--- @return table
function M.new_buffer(opts)
  opts = opts or {}
  local capacity = opts.capacity or M.DEFAULT_CAPACITY
  if type(capacity) ~= "number" or capacity < 1 then
    error("event_model.new_buffer: capacity must be a positive number, got " .. tostring(opts.capacity), 2)
  end
  return setmetatable({
    capacity = math.floor(capacity),
    window_ms = opts.window_ms or M.COLLAPSE_WINDOW_MS,
    show_ips = opts.show_ips and true or false,
    aliases = opts.aliases or M.DEV_ENDPOINT_ALIASES,
    entries = {},
  }, Buffer)
end

--- Pushes one already-parsed event.
---
--- RULE: an event collapses into the CURRENT TAIL entry only -- matching
--- its signature against any older entry would let an interleaved
--- A/B/A/B pattern silently rewrite history two rows up, which is not
--- what "collapse consecutive repeats" means. A tail match also has to
--- land inside `window_ms` of that entry's `last_ts`; an identical
--- request five minutes later is genuinely a new line.
---
--- The window is measured on |delta| rather than a forward delta on
--- purpose: `ts` comes from another process's wall clock, so a couple of
--- ms of backwards jitter inside one burst should still collapse.
--- @param event table
--- @return table entry, boolean is_new
function Buffer:push(event)
  local signature = M.signature(event)
  local label = M.label(event, { show_ips = self.show_ips, aliases = self.aliases })
  local tail = self.entries[#self.entries]

  if tail and tail.signature == signature
    and math.abs((event.ts or 0) - tail.last_ts) <= self.window_ms then
    tail.count = tail.count + 1
    tail.last_ts = event.ts
    -- Latest wins: the collapsed line shows the most recent duration/
    -- status for that endpoint, not the first one seen.
    tail.label = label
    return tail, false
  end

  local entry = {
    signature = signature,
    label = label,
    count = 1,
    last_ts = event.ts,
  }
  self.entries[#self.entries + 1] = entry
  while #self.entries > self.capacity do
    table.remove(self.entries, 1)
  end
  return entry, true
end

--- Parses then pushes. Returns nil (and the rejection reason) for a line
--- that is not a usable event -- the buffer is left untouched.
--- @param line string
--- @return table|nil entry, table|nil event, string|nil reason
function Buffer:push_line(line)
  local event, reason = M.parse_line(line)
  if not event then
    return nil, nil, reason
  end
  local entry = self:push(event)
  return entry, event, nil
end

--- Changes the visible row count in place, evicting oldest-first if the
--- new capacity is smaller.
--- @param capacity integer
function Buffer:set_capacity(capacity)
  if type(capacity) ~= "number" or capacity < 1 then
    error("event_model Buffer:set_capacity: capacity must be a positive number", 2)
  end
  self.capacity = math.floor(capacity)
  while #self.entries > self.capacity do
    table.remove(self.entries, 1)
  end
end

--- Current entries, oldest first (so a renderer painting top-to-bottom
--- naturally puts the most recent line last).
--- @return table[]
function Buffer:snapshot()
  local out = {}
  for i, entry in ipairs(self.entries) do
    out[i] = {
      signature = entry.signature,
      label = entry.label,
      count = entry.count,
      last_ts = entry.last_ts,
    }
  end
  return out
end

--- The same thing, already formatted (`label` plus `xN` when N > 1).
--- @return string[]
function Buffer:lines()
  local out = {}
  for i, entry in ipairs(self.entries) do
    out[i] = M.format_entry(entry)
  end
  return out
end

function Buffer:clear()
  self.entries = {}
end

return M
