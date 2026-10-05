--[[
  Hydronium Dev Watch -- generalized /__hydronium/watch SSE endpoint.

  Promotes the hand-rolled watch route that used to live entirely inside
  examples/meteorite_ssr/src/main.lua (hardcoded to a literal 5-file
  list) into reusable framework code: the fingerprinting and SSE-protocol
  logic below is verbatim what that example proved out, just generalized
  to take its file list as a parameter.

  Applications do not declare this route themselves:
  `hydronium_dom.server.meteorite.mount(app)` registers /__hydronium/watch
  as a Meteorite `m.lua` file handler
  (hydronium_dom/server/meteorite_routes/watch.lua) that calls
  `serve_sse` with the source registry's watch list. Meteorite's hybrid
  build rejects inline handlers that capture outer locals, but a file
  handler is loaded standalone by path, so a library can own it. Call
  `serve_sse(c, files, opts)` directly only for a custom watch endpoint.

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

--- Collects per-file content stamps and a compact revision without storing
--- the full fingerprint in a temp file. The legacy `fingerprint` and
--- `revision` functions remain available for callers using the older protocol.
function M.snapshot(files)
  local fp = M.fingerprint(files)
  local entries = M.parse_fingerprint(fp)
  local modulo = 4294967296
  local a, b, c = 5381, 0, 2166136261
  for index = 1, #fp do
    local byte = fp:byte(index)
    a = (a * 33 + byte) % modulo
    b = (b * 65599 + byte) % modulo
    c = ((c + byte) * 16777619) % modulo
  end
  return { revision = string.format("r%08x%08x%08x", a, b, c), entries = entries }
end

-- Fingerprints are ~50 bytes per watched file, so they never leave the
-- server: the wire carries `revision(fp)`, a fixed-size digest (Meteorite
-- rejects response header values over 1024 bytes and URLs over 8192; a
-- 20-file app already exceeded the header). A reconnecting browser's `since`
-- must still resolve to its file list, and Meteorite's default hybrid mode
-- gives every request a fresh Lua state, so digests are also recorded as
-- small content-addressed files in the temp directory (plain io, no fork:
-- see `fingerprint` on why request threads must not spawn processes).
local REMEMBERED_REVISIONS = 64
local remembered, remembered_order = {}, {}

local function revision_file(digest)
  local dir = os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"
  return (dir:gsub("/+$", "")) .. "/hydronium-dev-revision-" .. digest
end

--- Fixed-size, wire-safe digest of a fingerprint ("r" + 24 hex digits).
--- Remembers the fingerprint it came from for `fingerprint_for`.
--- @param fp string
--- @return string
function M.revision(fp)
  fp = fp or ""
  local modulo = 4294967296
  local a, b, c = 5381, 0, 2166136261
  for index = 1, #fp do
    local byte = fp:byte(index)
    a = (a * 33 + byte) % modulo
    b = (b * 65599 + byte) % modulo
    c = ((c + byte) * 16777619) % modulo
  end
  local digest = string.format("r%08x%08x%08x", a, b, c)
  if remembered[digest] == nil then
    remembered_order[#remembered_order + 1] = digest
    if #remembered_order > REMEMBERED_REVISIONS then
      remembered[table.remove(remembered_order, 1)] = nil
    end
  end
  remembered[digest] = fp
  local path = revision_file(digest)
  local existing = io.open(path, "rb")
  if existing then
    existing:close()
  else
    local file = io.open(path, "wb")
    if file then file:write(fp); file:close() end
  end
  return digest
end

--- The fingerprint a `revision()` digest came from (this Lua state's memory,
--- else the temp-directory record), or nil when none was ever produced.
--- @param digest string|nil
--- @return string|nil
function M.fingerprint_for(digest)
  if type(digest) ~= "string" or not digest:match("^r%x+$") then return nil end
  if remembered[digest] then return remembered[digest] end
  local file = io.open(revision_file(digest), "rb")
  if not file then return nil end
  local fp = file:read("*a")
  file:close()
  if fp and M.revision(fp) == digest then return fp end
  return nil
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

--- Names which watched files actually differ between fingerprints or entry maps.
--- Covers all three real cases: modified (content entry changed), created
--- (absent from `prev`, `stat` having failed and printed nothing), and
--- deleted (absent from `next`, same reason).
---
--- Returns a sorted array so the result is deterministic and does not
--- depend on `pairs` iteration order -- the same reason `fingerprint`
--- itself sorts.
--- @param prev string|table|nil
--- @param next_fp string|table|nil
--- @return string[] changed paths, sorted
function M.changed_files(prev, next_fp)
  local a = type(prev) == "table" and prev or M.parse_fingerprint(prev)
  local b = type(next_fp) == "table" and next_fp or M.parse_fingerprint(next_fp)
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

  local before = M.snapshot(files).revision
  if expected_revision ~= nil and expected_revision ~= before then
    return nil, before, "stale"
  end

  local ok, value = pcall(read)
  if not ok then return nil, before, "read_failed", value end

  local after = M.snapshot(files).revision
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
--- PROTOCOL. `hello`/`reload`/`bye` carry the fixed-size revision used as
--- the `since` token. A `snapshot` frame precedes `hello` or `reload` and
--- carries per-file stamps as JSON. The browser diffs consecutive snapshots
--- to retain exact changed paths across its client-paced SSE requests.
--- Within one long-lived request we also emit the legacy `changed` frame
--- before `reload` so older clients can still hot-swap one module.
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

  -- `id:` is the revision digest (single-line, fixed-size) -- this is
  -- what the browser echoes back as Last-Event-ID.
  local function emit(event, data)
    return write("id: " .. tostring(data) .. "\nevent: " .. event .. "\ndata: " .. tostring(data) .. "\n\n")
  end

  -- No `id:` -- see the PROTOCOL note in this function's doc comment.
  local function emit_changed(prev, next_snapshot)
    local paths = M.changed_files(prev.entries, next_snapshot.entries)
    return write("event: changed\ndata: " .. table.concat(paths, "|") .. "\n\n")
  end

  local function emit_snapshot(snapshot)
    local json = require("hydronium_dom.server.json")
    return write("event: snapshot\ndata: " .. json.encode(snapshot.entries) .. "\n\n")
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

  local current_snapshot = M.snapshot(files)
  local current = current_snapshot.revision

  if since and since ~= "" and since ~= current then
    -- The browser keeps the previous per-file map across client-paced polls.
    -- Sending a fresh snapshot lets it identify exactly what changed without
    -- requiring this request's Lua state to recover the previous revision.
    if not emit_snapshot(current_snapshot) then return end
    if not emit("reload", current) then return end
    finish()
    return
  end

  if not emit_snapshot(current_snapshot) then return end
  if not emit("hello", current) then return end

  local elapsed = 0
  local since_heartbeat = 0
  while elapsed < budget do
    sleep(poll_interval)
    local next_snapshot = M.snapshot(files)
    local next_fp = next_snapshot.revision
    elapsed = elapsed + poll_interval
    since_heartbeat = since_heartbeat + poll_interval
    if next_fp ~= current then
      if not emit_changed(current_snapshot, next_snapshot) then return end
      if not emit_snapshot(next_snapshot) then return end
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
