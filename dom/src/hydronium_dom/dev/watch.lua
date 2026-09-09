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
local DEFAULT_HEARTBEAT_EVERY = 2
local DEFAULT_BUDGET = 5

--- Snapshots every file in `files` (mtime/size/name) into one sorted,
--- "|"-joined string; any create/delete/modify changes it. `sleep_first`
--- folds the poll delay into the same `io.popen` call as the stat
--- commands, so each tick costs one subprocess, not two.
---
--- Sorted (not filesystem-stat-order-dependent) so the fingerprint
--- depends only on content, matching Ballad's own watcher, which pipes
--- its snapshot through `sort` for the same reason. "|"-joined, not
--- newline-joined: a raw newline round-tripped through a query string
--- (percent-encoded as %0A in `since=...`) is rejected by Meteorite's
--- router as a CRLF-injection guard, and a literal embedded newline in
--- an SSE `data:` line is malformed per the SSE spec too (one `data:`
--- prefix per line). "|" sidesteps both, since it never appears in a
--- `stat` line's own content.
function M.fingerprint(files, poll_interval, sleep_first)
  local parts = {}
  if sleep_first then
    parts[#parts + 1] = "sleep " .. tostring(poll_interval) .. ";"
  end
  for _, f in ipairs(files) do
    parts[#parts + 1] = "stat -f '%Fm %z %N' '" .. f .. "' 2>/dev/null || stat -c '%.9Y %s %n' '" .. f .. "';"
  end
  parts[#parts + 1] = "true"
  local p = io.popen(table.concat(parts, " "), "r")
  if not p then
    return ""
  end
  local out = p:read("*a") or ""
  p:close()
  local lines = {}
  for line in out:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  table.sort(lines)
  return table.concat(lines, "|")
end

--- Drives one live-reload SSE request to completion.
---
---   app:get("/__hydronium/watch", function(c)
---     require("hydronium_dom.dev.watch").serve_sse(c, {
---       "views/App.luax",
---     })
---   end)
---
--- @param c table Meteorite request context (header/query methods)
--- @param files string[] real file paths to watch (a literal list, not a
---   directory walk -- walking a whole project tree would traverse
---   .moonstone/env/'s thousands of files every poll)
--- @param opts table|nil { poll_interval, heartbeat_every, budget }
function M.serve_sse(c, files, opts)
  opts = opts or {}
  local poll_interval = opts.poll_interval or DEFAULT_POLL_INTERVAL
  local heartbeat_every = opts.heartbeat_every or DEFAULT_HEARTBEAT_EVERY
  local default_budget = opts.budget or DEFAULT_BUDGET

  local function get_query(key)
    if type(c.query) == "function" then
      return c:query(key)
    elseif type(c.query) == "table" then
      return c.query[key]
    end
    return nil
  end

  -- `id:` is the fingerprint itself (no embedded newlines, per the "|"
  -- delimiter above, so it's already a valid single-line field value) --
  -- this is what the browser echoes back as Last-Event-ID.
  local function emit(event, data)
    stream_write("id: " .. tostring(data) .. "\nevent: " .. event .. "\ndata: " .. tostring(data) .. "\n\n")
  end

  local since = c:header("Last-Event-ID") or get_query("since")
  local budget = tonumber(get_query("budget")) or default_budget

  stream_begin(200, "text/event-stream")
  stream_write("retry: 200\n\n")

  local current = M.fingerprint(files, poll_interval, false)

  if since and since ~= "" and since ~= current then
    emit("reload", current)
    stream_end()
    return
  end

  emit("hello", current)

  local elapsed = 0
  local since_heartbeat = 0
  while elapsed < budget do
    local next_fp = M.fingerprint(files, poll_interval, true)
    elapsed = elapsed + poll_interval
    since_heartbeat = since_heartbeat + poll_interval
    if next_fp ~= current then
      emit("reload", next_fp)
      stream_end()
      return
    end
    if since_heartbeat >= heartbeat_every then
      emit("ping", elapsed)
      since_heartbeat = 0
    end
  end

  emit("bye", current)
  stream_end()
end

return M
