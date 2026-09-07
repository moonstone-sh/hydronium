--[[
  Meteorite + Hydronium SSR Main Entrypoint

  This is a REAL, compiled Meteorite service: `require("meteorite")` and
  `require("hydronium")` resolve via Meteorite's own CLI package-path setup
  (`src/?.lua;src/?/init.lua`, relative to this project's root) plus the
  `src/hydronium` symlink checked in alongside this file, pointing at the
  real Hydronium source tree (../../../src/hydronium). No sibling-repo
  package.path hacking is needed -- see moonstone.toml for the
  `moonstone/meteorite` path dependency that makes `meteorite` and its Zig
  build tooling (`zig/build_api.zig`) available under `.moonstone/env/`.

  IMPORTANT: every route handler below is a self-contained function that
  does its own `require(...)` and defines its own helpers -- none of them
  close over a local from this file's top level. Meteorite's hybrid build
  mode "lifts" each inline Lua handler (extracts its own source text and
  reloads it standalone per request), so a handler that captured an outer
  upvalue (e.g. a `local AppView = require(...)` sitting above `app:get`)
  fails the build with "inline Lua handler captures outer local `...`".
  `require(...)` inside the handler body is fine (module-cache-backed);
  a captured reference to something `require`d outside the handler is not.
  `views/App.lua` exists for exactly this reason -- see its own comment.

  Build + run for real, over a real socket:
    moon sync
    moon exec -- zig build -Dmode=release-hybrid -Dbackend=std_http
    ./dist/server
--]]

local meteorite = require("meteorite")

local app = meteorite.app({
  name = "meteorite-hydronium-app",
  host = "127.0.0.1",
  port = 8080,
})

-- Serves the real hydronium.client.bootstrap.js and the real js_island
-- example module as static assets (Meteorite's built-in `m.site` --
-- these are plain static-file routes, not inline Lua, so they work in
-- either release-static or release-hybrid mode), pointed directly at
-- their real, canonical directories (Meteorite's static codegen rejects
-- symlinks outright, so a symlinked local copy wasn't an option -- this
-- avoids one anyway, no drift between what's served and what's real).
-- `/mixed` below is the first real proof either is actually fetchable
-- over a real socket, not just readable from disk.
meteorite.site(app, {
  root = ".",
  assets = {
    ["/js/island/:path*"] = { dir = "../js_island", param = "path" },
    ["/js/bootstrap/:path*"] = { dir = "../../src/hydronium/client", param = "path" },
    ["/__hydronium/hmr-demo/:path*"] = { dir = "hmr_demo", param = "path" },
  },
})

-- 1. Root SSR Route rendering AppView (.luax component), fully buffered.
app:get("/", function(c)
  local meteorite_adapter = require("hydronium.server.meteorite")
  local AppView = require("views.App")
  return meteorite_adapter.render(c, AppView, {
    status = 200,
    props = { title = "Home | Hydronium .luax SSR", path = "/" },
  })
end)

-- 2. Package View Route with dynamic params and query
app:get("/packages/:name", function(c)
  local hydronium = require("hydronium")
  local h = hydronium.createElement
  local meteorite_adapter = require("hydronium.server.meteorite")
  local AppView = require("views.App")

  local name = c.params and c.params.name or "unknown"
  local version = (type(c.query) == "function" and c:query("v")) or (type(c.query) == "table" and c.query.v) or "latest"

  local function PackageDetails()
    return h("div", { class = "card" }, {
      h("h2", nil, "Package: " .. name),
      h("p", nil, {
        h("span", { class = "badge" }, "Version: " .. version),
      }),
      h("pre", nil, {
        h("code", nil, "moon add " .. name .. "@" .. version),
      }),
    })
  end

  return meteorite_adapter.render(c, h(AppView, {
    title = "Package: " .. name .. " | Meteorite SSR",
    path = "/packages/" .. name,
  }, {
    h(PackageDetails),
  }))
end)

-- 3. ErrorBoundary Test Route
app:get("/error-test", function(c)
  local hydronium = require("hydronium")
  local h = hydronium.createElement
  local meteorite_adapter = require("hydronium.server.meteorite")
  local AppView = require("views.App")

  local function ThrowingComponent()
    error("Simulated database failure during SSR!")
  end

  local function Fallback(err)
    return h("div", { class = "card" }, {
      h("h2", { style = { color = "#ef4444" } }, "Caught by Hydronium ErrorBoundary"),
      h("p", nil, "Hydronium safely caught a server component error without crashing Meteorite:"),
      h("pre", nil, {
        h("code", nil, tostring(err.message or err)),
      }),
    })
  end

  local function Page()
    return h(AppView, {
      title = "ErrorBoundary Test | Meteorite SSR",
      path = "/error-test",
    }, {
      h(hydronium.ErrorBoundary, { fallback = Fallback }, {
        h(ThrowingComponent),
      }),
    })
  end

  return meteorite_adapter.render(c, h(Page), { status = 500 })
end)

-- 4. Pure JSON Health Route (demonstrating coexistence of JSON and HTML routes)
app:get("/api/health", function(c)
  return c:json({
    status = "ok",
    framework = "meteorite",
    renderer = "hydronium.server",
    timestamp = os.time(),
  })
end)

-- 5. Streaming SSR route: renders the same AppView shell, then a "Live
--    Package Feed" list whose rows arrive one at a time over a real
--    HTTP/1.1 chunked-transfer response (Meteorite's
--    stream_begin/stream_write/stream_end, driven here through
--    hydronium.server.meteorite.render_stream + make_stream_sink). Each
--    row's `os.execute("sleep 0.4")` simulates a slow per-item lookup
--    (e.g. a registry API call); it is NOT how fast Hydronium itself
--    renders -- it exists so the incremental delivery is observable on
--    the wire instead of happening too fast to see. Byte-for-byte this is
--    the same `server.render` tree-walk as the buffered routes above;
--    only the sink differs.
app:get("/stream", function(c)
  local hydronium = require("hydronium")
  local h = hydronium.createElement
  local meteorite_adapter = require("hydronium.server.meteorite")
  local AppView = require("views.App")

  local FEED_ITEMS = { "moonstone/meteorite", "moonstone/clingy", "moonstone/ballad", "hydronium", "moonstone/valua" }

  local function SlowPackageRow(props)
    os.execute("sleep 0.4")
    return h("li", { class = "card" }, {
      h("strong", nil, props.name),
      h("span", nil, " -- resolved"),
    })
  end

  local function LivePackageFeed()
    local rows = {}
    for i, name in ipairs(FEED_ITEMS) do
      rows[i] = h(SlowPackageRow, { name = name })
    end
    return h("section", nil, {
      h("h2", nil, "Live Package Feed (streamed)"),
      h("p", nil, "Each row below is written to the live socket as soon as it resolves -- open this route with a raw HTTP client to see them arrive one at a time, not all at once."),
      h("ul", nil, rows),
    })
  end

  local sink = meteorite_adapter.make_stream_sink(200, "text/html; charset=utf-8")
  local ok, err = meteorite_adapter.render_stream(c, h(AppView, {
    title = "Streaming SSR | Meteorite + Hydronium",
    path = "/stream",
  }, {
    h(LivePackageFeed),
  }), sink)
  if not ok then
    error(err, 0)
  end
end)

-- 6. Islands + Suspense proof (SSR only -- no client hydration exists yet;
--    see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md). Demonstrates, over this
--    real compiled binary:
--      - d.lua.island: SSR output wrapped in stable-ID HTML comment
--        markers, plus a __HYDRONIUM_CLIENT_PLAN__ script tag describing it.
--      - h.Suspense + h.resource with a loader: resolves synchronously,
--        no fallback ever appears (the "sequential" SSR mode).
--      - h.Suspense with a resource left deliberately pending: proves the
--        fallback path itself renders correctly, independent of whether
--        anything ever resolves it.
app:get("/islands", function(c)
  local hydronium = require("hydronium")
  local h = hydronium.createElement
  local d = require("hydronium.dom").d
  local resource = require("hydronium.core.resource")
  local meteorite_adapter = require("hydronium.server.meteorite")
  local AppView = require("views.App")

  local function Counter(props)
    return h("div", { class = "card" }, {
      h("h3", nil, "Lua island (SSR only)"),
      h("p", nil, "Count: " .. tostring(props.initial)),
      h("p", nil, "No client JS runs this yet -- see the HTML comment markers and the client-plan script tag in the page source."),
    })
  end

  local function SlowProfile()
    local res = resource.new(function() return "resolved without ever suspending" end)
    return h("div", { class = "card" }, {
      h("h3", nil, "Resource with a loader"),
      h("p", nil, res:get()),
    })
  end

  local function StuckProfile()
    local res = resource.new() -- no loader: never resolves in this request
    return h("div", { class = "card" }, {
      h("h3", nil, "This should never render"),
      h("p", nil, res:get()),
    })
  end

  return meteorite_adapter.render(c, h(AppView, {
    title = "Islands + Suspense | Meteorite + Hydronium",
    path = "/islands",
  }, {
    h(d.lua.island, { hydrate = "visible" }, h(Counter, { initial = 10 })),
    h(hydronium.Suspense, { fallback = h("div", { class = "card" }, "Resolves synchronously, so you should never see this.") },
      h(SlowProfile)),
    h(hydronium.Suspense, { fallback = h("div", { class = "card" }, h("h3", nil, "Suspense fallback (intentional)"), h("p", nil, "This resource is deliberately left pending to prove the fallback path itself renders correctly.")) },
      h(StuckProfile)),
  }))
end)

-- 7. The mission's own "mixed" flagship stress case: one Suspense
--    boundary, one Lua island, and one JS island on the same real,
--    compiled, HTTP-served page. The JS island's module
--    (/js/island/counter.js) and the client bootstrap (/js/bootstrap/bootstrap.js)
--    are served by Meteorite's own static-file routes (meteorite.site,
--    registered above) -- this is the first time either has been fetched
--    over a real socket rather than read from disk in a Node/jsdom test.
--    A real browser opening this page runs the bootstrap script at the
--    bottom, which hydrates the JS island for real; the Lua island's
--    markers exist (see the client plan in the page source) but nothing
--    on this page hydrates it, since that requires the WASM Lua runtime
--    this bootstrap deliberately never loads (see bootstrap.js's own doc
--    comment) -- proving, on a page that visibly needs it, that a JS-only
--    client load path really doesn't reach for Lua.
app:get("/mixed", function(c)
  local hydronium = require("hydronium")
  local h = hydronium.createElement
  local d = require("hydronium.dom").d
  local resource = require("hydronium.core.resource")
  local meteorite_adapter = require("hydronium.server.meteorite")
  local AppView = require("views.App")

  local function Feed()
    local res = resource.new(function() return "Feed resolved synchronously during SSR." end)
    return h("div", { class = "card" }, {
      h("h3", nil, "Suspense-wrapped feed"),
      h("p", nil, res:get()),
    })
  end

  local function LuaCounter(props)
    return h("div", { class = "card" }, {
      h("h3", nil, "Lua island"),
      h("button", nil, "Count: " .. tostring(props.initial)),
      h("p", nil, "Hydrated by hydronium.interpreter.lua -- not on this page (see /stream's sibling proof, the published \"Hydronium in WASM\" artifact); this page proves the JS island half."),
    })
  end

  local function JsCounter(props)
    return h("div", { class = "card" }, {
      h("h3", nil, "JS island"),
      h("button", nil, "Count: " .. tostring(props.initial)),
      h("p", nil, "Hydrated below by a real dynamic import() of /js/island/counter.js -- open devtools and click it."),
    })
  end

  return meteorite_adapter.render(c, h(AppView, {
    title = "Mixed: Suspense + Lua island + JS island | Meteorite + Hydronium",
    path = "/mixed",
  }, {
    h(hydronium.Suspense, { fallback = h("div", { class = "card" }, "Loading feed...") }, h(Feed)),
    h(d.lua.island, { hydrate = "visible" }, h(LuaCounter, { initial = 3 })),
    h(d.js.island, { module = "/js/island/counter.js", hydrate = "visible", props = { initial = 7 } },
      h(JsCounter, { initial = 7 })),
    h("script", { type = "module" },
      "import { activate } from \"/js/bootstrap/bootstrap.js\"; activate().then((r) => console.log(\"hydronium bootstrap:\", r));"),
  }))
end)

-- 8. HMR dev-transport trigger: a real file-change -> push-notification
--    proof, not the client-side half (no EventSource consumer, no
--    RefreshRegistry wiring -- see docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md's
--    "Left open" list; this closes exactly one item on it).
--
--    Shape is a BOUNDED long-poll over Meteorite's real
--    stream_begin/stream_write/stream_end SSE primitive (proven live in
--    route 5 above), not an indefinite stream -- this example is built
--    with the `std_http` backend, which is strictly single-connection-serial
--    (see zig/meteorite.zig's accept loop: no threading, no pooling; a
--    handler that never returns freezes the whole server, not just this
--    request). A short, client-bounded budget makes the route self-healing
--    even if a client vanishes mid-stream, since client-disconnect
--    handling is otherwise unverified here (see
--    docs/METEORITE_STREAMING_FOUNDATION.md's open items).
--
--    Detection is a `stat`-snapshot poll, the same technique Ballad's own
--    file watcher already uses in this stack
--    (.moonstone/env/libexec/ballad/src/ballad/plugins/watcher.lua) --
--    no new dependency (no luafilesystem) needed. `%Fm` (BSD stat, this
--    machine) / `%.9Y` (GNU stat) give sub-second mtime precision; plain
--    `%m`/`%Y` are whole-seconds and can miss an edit landing in the same
--    second as a poll.
--
--    Protocol: GET /__hydronium/watch?since=<fingerprint>&budget=<seconds>
--    (also accepts a Last-Event-ID request header as an alternative to
--    the `since` query param, for a client that wants to lean on plain
--    SSE semantics). Real client code should NOT rely on EventSource's
--    native Last-Event-ID auto-resend for this, though: every frame
--    carries a matching `id:`, which looks like it should make the
--    browser's own "resume where I left off" mechanism just work on
--    reconnect -- but verified live via Playwright against a real
--    Chromium that it does NOT reliably resend Last-Event-ID across an
--    automatic reconnect for named (non-default) SSE event types like
--    `hello`/`reload`/`bye`. See src/hydronium/client/dev_transport.js,
--    the real client, for the actual fix: it tracks the fingerprint
--    itself and passes it as an explicit `since` query param on a
--    connection it closes and reopens itself, never relying on the
--    browser to resend anything. The `since` param here predates that
--    finding and was originally meant only as a curl/manual-testing
--    convenience; it's now load-bearing for the real client instead.
--    `retry: 200` is sent regardless -- harmless, and still relevant for
--    any consumer that DOES lean on native auto-reconnect for the
--    no-op-until-bye case.
--      - Last-Event-ID header or `since` query param supplied and stale
--        -> immediate `event: reload`, stream ends.
--      - Otherwise: `event: hello` with the current fingerprint, then a
--        poll loop (0.5s interval, matching Ballad's own default) until
--        either a change is detected (`event: reload`, stream ends) or
--        the budget expires (`event: bye` with the current fingerprint,
--        stream ends) -- `event: ping` fires periodically in between so
--        the stream is observably alive while waiting.
--
--    Watched set is a literal list, not a directory walk -- `find` over
--    the whole project would traverse `.moonstone/env/`'s thousands of
--    files every poll. Exactly the two files a `/` request already
--    reflects live, with no rebuild, on every request (views/App.luax is
--    compiled fresh by src/views/App.lua's load_luax on every require,
--    and Meteorite's hybrid runtime creates a fresh Lua state per
--    request): the push notification is genuinely the only missing piece
--    of a live-reload loop, not a proxy for one.
app:get("/__hydronium/watch", function(c)
  local WATCHED = { "views/App.luax", "src/views/App.lua", "hmr_demo/click_increment.lua", "hmr_demo/family_counter.lua", "hmr_demo/arbitrary_tree_counter.lua" }
  local POLL_INTERVAL = 0.5
  local HEARTBEAT_EVERY = 2

  local function get_query(key)
    if type(c.query) == "function" then
      return c:query(key)
    elseif type(c.query) == "table" then
      return c.query[key]
    end
    return nil
  end

  -- Snapshot every watched file's mtime/size/name into one sorted string;
  -- any create/delete/modify changes it. `sleep_first` folds the poll
  -- delay into the same `io.popen` call as the stat commands, so each
  -- tick costs one subprocess, not two.
  local function fingerprint(sleep_first)
    local parts = {}
    if sleep_first then
      parts[#parts + 1] = "sleep " .. tostring(POLL_INTERVAL) .. ";"
    end
    for _, f in ipairs(WATCHED) do
      parts[#parts + 1] = "stat -f '%Fm %z %N' '" .. f .. "' 2>/dev/null || stat -c '%.9Y %s %n' '" .. f .. "';"
    end
    parts[#parts + 1] = "true"
    local p = io.popen(table.concat(parts, " "), "r")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    -- Sort lines so the fingerprint doesn't depend on filesystem stat
    -- ordering, only on content -- matches Ballad's own watcher, which
    -- pipes its snapshot through `sort` for the same reason. Joined with
    -- "|", not "\n": a raw newline round-tripped through a query string
    -- (percent-encoded as %0A in `since=...`) is rejected by Meteorite's
    -- router as a CRLF-injection guard -- found live, not assumed -- and
    -- a literal embedded newline in an SSE `data:` line is malformed per
    -- the SSE spec too (a multi-line payload needs one `data:` prefix per
    -- line). "|" sidesteps both without needing any encoding at all,
    -- since it never appears in a `stat` line's own content.
    local lines = {}
    for line in out:gmatch("[^\n]+") do
      lines[#lines + 1] = line
    end
    table.sort(lines)
    return table.concat(lines, "|")
  end

  -- `id:` is the fingerprint itself (no embedded newlines, per the "|"
  -- delimiter above, so it's already a valid single-line field value) --
  -- this is what the browser echoes back as Last-Event-ID.
  local function emit(event, data)
    stream_write("id: " .. tostring(data) .. "\nevent: " .. event .. "\ndata: " .. tostring(data) .. "\n\n")
  end

  local since = c:header("Last-Event-ID") or get_query("since")
  local budget = tonumber(get_query("budget")) or 5

  stream_begin(200, "text/event-stream")
  stream_write("retry: 200\n\n")

  local current = fingerprint(false)

  if since and since ~= "" and since ~= current then
    emit("reload", current)
    stream_end()
    return
  end

  emit("hello", current)

  local elapsed = 0
  local since_heartbeat = 0
  while elapsed < budget do
    local next_fp = fingerprint(true)
    elapsed = elapsed + POLL_INTERVAL
    since_heartbeat = since_heartbeat + POLL_INTERVAL
    if next_fp ~= current then
      emit("reload", next_fp)
      stream_end()
      return
    end
    if since_heartbeat >= HEARTBEAT_EVERY then
      emit("ping", elapsed)
      since_heartbeat = 0
    end
  end

  emit("bye", current)
  stream_end()
end)

-- 9. Serves hmr_demo/click_increment.lua's CURRENT content, fresh on
--    every request -- NOT via meteorite.site's static-asset serving
--    (used for hmr_demo/index.html above), which was found live to bake
--    file CONTENT at graph/build time, not just the file list: editing
--    a static asset on disk after a build does not change what that
--    route returns until a rebuild, which would defeat the entire point
--    of this file (the HMR demo page fetches it fresh after each
--    /__hydronium/watch reload event, expecting the just-edited value).
--    An inline Lua handler's own io.open, by contrast, already reads
--    live filesystem state per request -- the same property that makes
--    editing views/App.luax work with no rebuild at all (see route 1's
--    own comment and src/views/App.lua's load_luax).
--
--    Deliberately NOT nested under /__hydronium/hmr-demo/ (where the
--    file actually lives on disk): that whole prefix is already claimed
--    by the meteorite.site wildcard above, and this exact route was
--    found live to lose to it silently (no build-time conflict error,
--    since this route is declared with app:get after meteorite.site
--    ran its own conflict check against only the routes that existed at
--    that point) -- a live fetch kept returning the stale, baked
--    content. Living outside that prefix entirely sidesteps the
--    ambiguity rather than depending on undocumented router precedence.
app:get("/__hydronium/hmr-demo-increment", function(c)
  local f = assert(io.open("hmr_demo/click_increment.lua", "r"))
  local content = f:read("*a")
  f:close()
  return c:text(200, content)
end)

-- 10. Same live-content-per-request reasoning as route 9, for the HMR
--     generalization proof's real component-module source
--     (hmr_demo/family_counter.lua) -- edit its `+ 1` to `+ 2` on disk
--     while examples/meteorite_ssr/hmr_demo/family_proof.html is open to
--     prove the generalized (non-hand-wired) refresh path.
app:get("/__hydronium/hmr-demo-family-counter", function(c)
  local f = assert(io.open("hmr_demo/family_counter.lua", "r"))
  local content = f:read("*a")
  f:close()
  return c:text(200, content)
end)

-- 11. Same live-content-per-request reasoning as routes 9-10, for the
--     DOM-Host/arbitrary-tree counter-audit proof's real component
--     source (hmr_demo/arbitrary_tree_counter.lua, docs/HMR_DOM_HOST.md)
--     -- edit its `+ 1` to `+ 2` on disk while
--     examples/meteorite_ssr/hmr_demo/dom_host_proof.html is open.
app:get("/__hydronium/hmr-demo-arbitrary-tree-counter", function(c)
  local f = assert(io.open("hmr_demo/arbitrary_tree_counter.lua", "r"))
  local content = f:read("*a")
  f:close()
  return c:text(200, content)
end)

return app
