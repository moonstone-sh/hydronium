--[[
  Hydronium Dev Watch -- generalized /__hydronium/watch SSE endpoint.

  Promotes the hand-rolled watch route that used to live entirely inside
  examples/meteorite_ssr/src/main.lua (hardcoded to a literal 5-file
  list) into reusable framework code: the fingerprinting and SSE-protocol
  logic below is verbatim what that example proved out, just generalized
  to take its file list as a parameter.

  IMPORTANT -- this does NOT register the route for you. Meteorite's
  hybrid build mode lifts each inline `app:get(path, function(c) ... end)`
  handler by extracting ITS OWN source text and reloading it standalone
  per request; it cannot see a route registered indirectly through a
  library call like `watch.mount(app, ...)` would need to be, only a
  literal inline handler written in the file Meteorite is compiling. A
  `require(...)` call made FROM INSIDE that inline handler's own body is
  fine (module-cache-backed, not a captured upvalue) -- only a captured
  outer local fails the build. So: write the inline `app:get(...)` route
  yourself, and call `watch.serve_sse(c, files, opts)` from inside it --
  see this module's own `serve_sse` doc comment for the one-line example.

  `stream_begin`/`stream_write`/`stream_end` are referenced as bare
  globals, not `c` methods -- matching the exact convention the original
  example route used (Meteorite binds them per-request, not per-handler-
  closure, so a plain library function running in that same request's Lua
  state can call them exactly like the inline handler could).
--]]

local M = {}

local DEFAULT_POLL_INTERVAL = 0.5
local DEFAULT_BUDGET = 5

--- Snapshots every file in `files` (two content hashes/size/name) into one
--- sorted, "|"-joined string; any create/delete/content change changes it.
---
--- This deliberately uses ordinary file reads rather than `io.popen("stat")`.
--- Meteorite serves requests on multiple threads; forking a shell from that
--- process can strand a request when a page refresh abandons its EventSource.
--- Reading the files in-process also detects same-size writes made within a
--- filesystem timestamp tick, which the old mtime/size fingerprint missed.
---
--- Sorted so caller order cannot affect the fingerprint. "|"-joined, not
--- newline-joined: a raw newline round-tripped through a query string
--- (percent-encoded as %0A in `since=...`) is rejected by Meteorite's
--- router as a CRLF-injection guard, and a literal embedded newline in
--- an SSE `data:` line is malformed per the SSE spec too (one `data:`
--- prefix per line). "|" sidesteps both, since it never appears in a
--- `stat` line's own content.
function M.fingerprint(files)
  local modulo = 4294967296
  local lines = {}
  for _, f in ipairs(files) do
    local file = io.open(f, "rb")
    if file then
      local content = file:read("*a") or ""
      file:close()
      local a, b = 5381, 0
      for index = 1, #content do
        local byte = content:byte(index)
        a = (a * 33 + byte) % modulo
        b = (b * 65599 + byte) % modulo
      end
      lines[#lines + 1] = string.format("%.0f:%.0f %d %s", a, b, #content, f)
    end
  end
  table.sort(lines)
  return table.concat(lines, "|")
end

--- Splits a fingerprint back into { [path] = "<hashes> <size>" }.
---
--- The fingerprint is not an opaque digest -- it is the concatenation of
--- one `stat` line per watched file, so the identity of WHICH file moved
--- is already carried in it and only needs to be read back out. That is
--- what makes per-module change identity (M2) a pure addition here
--- rather than a protocol redesign: no second stat pass, no per-file
--- bookkeeping across requests, and the existing whole-set digest keeps
--- its exact meaning and its exact role as the `since` token.
---
--- A path may legitimately contain spaces, so the name is everything
--- after the second field, not the third whitespace-delimited token.
--- @param fp string
--- @return { [string]: string }
function M.parse_fingerprint(fp)
  local entries = {}
  if type(fp) ~= "string" or fp == "" then
    return entries
  end
  for line in fp:gmatch("[^|]+") do
    local mtime, size, name = line:match("^(%S+)%s+(%S+)%s+(.+)$")
    if name then
      entries[name] = mtime .. " " .. size
    end
  end
  return entries
end

--- Names which watched files actually differ between two fingerprints.
--- Covers all three real cases: modified (content entry changed), created
--- (absent from `prev`, `stat` having failed and printed nothing), and
--- deleted (absent from `next`, same reason).
---
--- Returns a sorted array so the result is deterministic and does not
--- depend on `pairs` iteration order -- the same reason `fingerprint`
--- itself sorts.
--- @param prev string|nil
--- @param next_fp string|nil
--- @return string[] changed paths, sorted
function M.changed_files(prev, next_fp)
  local a = M.parse_fingerprint(prev)
  local b = M.parse_fingerprint(next_fp)
  local seen, changed = {}, {}
  for name, stamp in pairs(b) do
    if a[name] ~= stamp then
      seen[name] = true
      changed[#changed + 1] = name
    end
  end
  for name in pairs(a) do
    if b[name] == nil and not seen[name] then
      changed[#changed + 1] = name
    end
  end
  table.sort(changed)
  return changed
end

--- Read one source value against a stable watched-set revision.
---
--- The caller supplies the actual source read/compile operation.  We verify
--- the whole watched set both immediately before and immediately after it,
--- and reject the value unless it still names `expected_revision` (when one
--- was supplied by the browser).  That turns a normal per-module route into
--- a revision-addressed snapshot endpoint without keeping mutable snapshots
--- in a request-local Lua VM.
---
--- A `nil` expected revision is the initial-load case: the value is accepted
--- if the watched set stayed stable while it was read and the observed
--- revision is returned to the caller for its response header.
---
--- @param files string[]
--- @param expected_revision string|nil
--- @param read fun(): any
--- @return any|nil value
--- @return string|nil revision
--- @return string|nil reason "stale" | "read_failed"
--- @return any|nil error
function M.read_snapshot(files, expected_revision, read)
  if expected_revision ~= nil and type(expected_revision) ~= "string" then
    error("hydronium_dom.dev.watch: expected_revision must be a string or nil", 2)
  end
  if type(read) ~= "function" then
    error("hydronium_dom.dev.watch: read_snapshot requires a read function", 2)
  end

  local before = M.fingerprint(files)
  if expected_revision ~= nil and expected_revision ~= before then
    return nil, before, "stale"
  end

  local ok, value = pcall(read)
  if not ok then return nil, before, "read_failed", value end

  local after = M.fingerprint(files)
  if after ~= before or (expected_revision ~= nil and expected_revision ~= after) then
    return nil, after, "stale"
  end
  return value, after
end

--- Drives one live-reload SSE request to completion.
---
---   app:get("/__hydronium/watch", function(c)
---     require("hydronium_dom.dev.watch").serve_sse(c, {
---       "views/App.luax",
---     })
---   end)
---
--- PROTOCOL. Unchanged for existing consumers: `hello`/`reload`/`ping`/
--- `bye` still carry exactly what they always did, and `reload`'s data is
--- still the whole-set fingerprint that doubles as the `since` token. M2
--- adds ONE new frame, `changed`, emitted immediately before each
--- `reload`, whose data is the "|"-joined list of the watched paths that
--- actually moved. An EventSource never dispatches an event type nobody
--- registered a listener for, so a consumer that only knows about
--- `reload` (dev_reload.js through dev_transport.js) is unaffected.
---
--- `changed` deliberately carries NO `id:` field, unlike every other
--- frame here. The browser's native EventSource records the last `id:`
--- it saw and echoes it as `Last-Event-ID` on its own reconnects, and
--- this route reads that header ahead of `?since=`. An `id:` holding a
--- path list rather than a fingerprint would therefore come back as a
--- bogus `since` value that can never equal the current fingerprint --
--- an immediate, permanent reload loop.
---
--- @param c table Meteorite request context (header/query methods)
--- @param files string[] real file paths to watch (a literal list, not a
---   directory walk -- walking a whole project tree would traverse
---   .moonstone/env/'s thousands of files every poll)
--- @param opts table|nil { poll_interval, heartbeat_every, budget }
function M.serve_sse(c, files, opts)
  opts = opts or {}
  local poll_interval = opts.poll_interval or DEFAULT_POLL_INTERVAL
  -- A refresh closes its EventSource without another request-side callback.
  -- Probe once per poll by default so an abandoned handler does not linger
  -- for seconds while the replacement page is trying to render.
  local heartbeat_every = opts.heartbeat_every or poll_interval
  local default_budget = opts.budget or DEFAULT_BUDGET

  local disconnected = false
  local function write(chunk)
    local ok = pcall(stream_write, chunk)
    if not ok then disconnected = true end
    return ok
  end

  local function finish()
    if not disconnected then pcall(stream_end) end
  end

  local function get_query(key)
    if type(c.query) == "function" then
      return c:query(key)
    elseif type(c.query) == "table" then
      local declared = c.query[key]
      if declared ~= nil then return declared end
      -- Meteorite exposes undeclared/raw values through the query table's
      -- __call metamethod. The watch protocol deliberately keeps `since` and
      -- `budget` out of the route schema, so both must use this fallback.
      local mt = getmetatable(c.query)
      if mt and type(mt.__call) == "function" then
        return c.query(key)
      end
    end
    return nil
  end

  -- `id:` is the fingerprint itself (no embedded newlines, per the "|"
  -- delimiter above, so it's already a valid single-line field value) --
  -- this is what the browser echoes back as Last-Event-ID.
  local function emit(event, data)
    return write("id: " .. tostring(data) .. "\nevent: " .. event .. "\ndata: " .. tostring(data) .. "\n\n")
  end

  -- No `id:` -- see the PROTOCOL note in this function's doc comment.
  local function emit_changed(prev, next_fp)
    local paths = M.changed_files(prev, next_fp)
    return write("event: changed\ndata: " .. table.concat(paths, "|") .. "\n\n")
  end

  local since = c:header("Last-Event-ID") or get_query("since")
  local budget_value = get_query("budget")
  local budget = tonumber(budget_value) or default_budget
  local sleep = opts.sleep or _G.meteorite_sleep

  if budget > 0 and type(sleep) ~= "function" then
    error("hydronium_dom.dev.watch: positive budgets require Meteorite's meteorite_sleep helper")
  end

  if not pcall(stream_begin, 200, "text/event-stream") then return end
  if not write("retry: 200\n\n") then return end

  local current = M.fingerprint(files, poll_interval, false)

  if since and since ~= "" and since ~= current then
    if not emit_changed(since, current) then return end
    if not emit("reload", current) then return end
    finish()
    return
  end

  if not emit("hello", current) then return end

  local elapsed = 0
  local since_heartbeat = 0
  while elapsed < budget do
    sleep(poll_interval)
    local next_fp = M.fingerprint(files)
    elapsed = elapsed + poll_interval
    since_heartbeat = since_heartbeat + poll_interval
    if next_fp ~= current then
      if not emit_changed(current, next_fp) then return end
      if not emit("reload", next_fp) then return end
      finish()
      return
    end
    if since_heartbeat >= heartbeat_every then
      if not emit("ping", elapsed) then return end
      since_heartbeat = 0
    end
  end

  if not emit("bye", current) then return end
  finish()
end

return M
