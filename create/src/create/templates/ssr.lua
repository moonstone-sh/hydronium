local ssr = {}

--[[
  Full-stack SSR template: real Meteorite + Hydronium API, verified live
  against a freshly scaffolded project (moon exec meteorite graph, zig
  build -Dmode=release-hybrid -Dbackend=std_http, ./dist/server, curl).

  Ground truth for every API shape below is
  hydronium/examples/meteorite_ssr/{src/main.lua, src/views/App.lua,
  moonstone.toml} in the sibling hydronium checkout -- read those first if
  changing this file. Key facts that are NOT obvious from guessing at the
  API:

  - `meteorite.app({name, host, port})`, not `meteorite.create()`.
  - `meteorite.site(app, {root=..., assets={["/path/:p*"] = {dir=..., param="p"}}})`
    for static files -- there is no `meteorite.static` + `app:use(...)`.
  - `app:get(path, function(c) ... end)` -- ONE context arg, not (req, res).
  - Every `require(...)` a route handler needs must happen INSIDE the
    handler body. Meteorite's hybrid build "lifts" each inline Lua handler
    (extracts its own source text, reloads it standalone per request) --
    closing over an outer local fails the build with "inline Lua handler
    captures outer local". This is why views/App.lua exists as its own
    requirable module instead of a `main.lua` upvalue.
  - Rendering goes through `require("hydronium_dom.server.meteorite").render(c,
    AppView, {status=200, props={...}})` -- takes the COMPONENT (not a
    pre-built vnode) plus an options table with `props`; there is no
    `hydronium.render_to_string(...)` + `res:header()`/`res:send()` (that
    response API doesn't exist anywhere in this framework).
  - LUAX has no arrow-function syntax (`() => expr` fails to parse --
    verified directly against hydronium_luax.compile) -- every callback is
    `function() ... end`.
  - The SSR client-boundary guard (dom/src/hydronium_dom/server/init.lua,
    around the `onClick`/callback-prop handling) only recognizes a prop
    name whose 3rd byte is an uppercase ASCII letter (`onClick`, `onInput`,
    ...) -- `onclick` (lowercase) does NOT match, so a Lua function value on
    it is silently dropped by `html.serialize_attributes` (never an error,
    never rendered) instead of doing anything. But the inverse is also
    real and load-bearing: `onClick` (correctly-cased) with a Lua closure
    OUTSIDE a client-execution boundary is a hard render-time error ("Lua
    callback `onClick` requires a Lua client execution boundary"), verified
    directly by rendering both shapes.

  - UPDATED (previously this comment said Hydronium has no real Lua client
    hydration -- that was true for the specific pattern it was describing,
    inline `<d.lua.island>` markers inside an ordinary SSR page, which
    indeed still do not auto-hydrate: dropping one into a page and hoping
    a client runtime picks it up on its own does not work. But a
    DIFFERENT, real mechanism does: `hydronium_dom/client/mount.js` boots
    wasmoon (LuaJIT compiled to WASM) in the browser, fetches the
    project's own compiled Lua modules over HTTP via a manifest, and
    mounts a Lua component as the root of its own container with
    `d.lua.mount` -- verified live against
    hydronium/examples/meteorite_ssr/client_mount_demo (two real browser
    clicks drive two real Lua-closure `onClick` calls through the ordinary
    reconciler, with zero JS interactivity layer). This template now uses
    exactly that mechanism for its counter (views/Counter.luax, mounted
    into the `<div id="app">` in views/App.luax) instead of the
    non-hydrating `<d.lua.island>` pattern -- clicking the button in a
    browser really does call Lua running client-side. The counter also
    uses a BARE `{count}` binding (not `{count()}`) as its text child, so
    each click patches only that text node directly via a fine-grained
    Hydronium DOM binding, without re-running the whole component.

  - This does mean more moving parts than the previous version: `main.lua`
    now serves hydronium's own client runtime source (`/hydronium-src`),
    the compiled client bootstrap (`/js/bootstrap`, from
    hydronium/dom/src/hydronium_dom/client), this project's own client
    component compiled on demand (`/__hydronium/dev/module/views.Counter`),
    and a static module manifest (`/__hydronium/client_manifest.json`) the
    client fetches to know which framework files to load. This is
    dev/example serving (plain `io.open` per request), not a production
    asset pipeline -- see hydronium/docs/BUNDLING.md for what a real
    bundler would still need to add.

  - HMR, not live reload (roadmap M2). `/__hydronium/watch` is built on
    `hydronium_dom.dev.watch` (real, reusable framework code) and now
    reports WHICH watched file moved, not merely that something did. The
    browser side is `hydronium_dom/client/hmr.js`: it re-fetches just that
    module's freshly compiled source, installs it as `package.preload[id]`
    in the SURVIVING wasmoon VM, and calls `family_loader.reload(id)` --
    so the counter keeps its value and its DOM nodes across an edit, with
    no page navigation. `dev_reload.js` (whole-page reload) is what hmr.js
    falls back to whenever a hot swap cannot be proven to have worked, and
    is still the right client for a page with no Lua VM at all.

  - Two files must agree, and nothing enforces it automatically: the watch
    list in `src/main.lua` and the `modules` map in `views/App.luax`. A
    watched file with no entry in that map is not an error -- it just
    triggers the full-reload fallback.

  - `views/App.luax` and `views/Counter.luax` live at the project ROOT,
    not under `src/`. `meteorite dev` watches `src/` and rebuilds and
    restarts the server on any change there, which would destroy the page
    HMR exists to preserve. Both are recompiled per request by
    `hydronium_luax.loader`, so neither needs a rebuild anyway.
]]

function ssr.files(opts)
  local project_name = opts.name or "my-hydronium-app"

  local files = {}

  -- NOTE: this literal must use the `[=[ ... ]=]` long-bracket level, not
  -- plain `[[ ... ]]` -- the content itself contains the substring
  -- "[[dependencies]]" (real TOML array-of-tables syntax), which would
  -- otherwise prematurely close a plain `[[` long string right after
  -- "[[dependencies" the first time it appears.
  files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "bin"
description = "Full-stack SSR application powered by Hydronium and Meteorite"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
dev = "moon exec --dev meteorite dev --mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit"
build = "moon exec --dev meteorite build --mode release-hybrid --backend fast_http"

[[dependencies]]
name = "moonstone/meteorite"
constraint = "path:../meteorite"
role = "tool"

[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.3.0"
role = "tool"

[[dependencies]]
name = "hydronium"
constraint = "path:../hydronium/core"
role = "runtime"

[[dependencies]]
name = "hydronium-luax"
constraint = "path:../hydronium/luax"
role = "runtime"

[[dependencies]]
name = "hydronium-dom"
constraint = "path:../hydronium/dom"
role = "runtime"
]=], project_name)

  files[".gitignore"] = [[.moonstone/
dist/
.zig-cache/
zig-out/
.meteorite/
*.log
]]

  -- Verified live: with `moonstone/meteorite` resolved as a `path:../meteorite`
  -- dependency (not a registry package), `.moonstone/env/libexec/meteorite`
  -- materializes as a plain symlink straight to that sibling checkout's own
  -- root -- so `build_api.zig` really is at
  -- `.moonstone/env/libexec/meteorite/zig/build_api.zig`, exactly matching
  -- hydronium/examples/meteorite_ssr/build.zig (NOT the deeper
  -- `.../meteorite/files/meteorite/zig/build_api.zig` path meteorite's own
  -- `meteorite init` scaffolder generates for a registry-installed
  -- dependency -- that shape assumes a different on-disk layout that a
  -- path dependency doesn't produce).
  files["build.zig"] = [[const std = @import("std");
const meteorite = @import(".moonstone/env/libexec/meteorite/zig/build_api.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = meteorite.addService(b, .{
        .meteorite_root = ".moonstone/env/libexec/meteorite",
        .lua_root = ".moonstone/env/libexec/luajit",
        .target = target,
        .optimize = optimize,
        .mode = b.option([]const u8, "mode", "Meteorite build mode") orelse "release-hybrid",
        .graph_input = b.option([]const u8, "graph-input", "Meteorite graph input") orelse "src/main.lua",
        .graph_output = b.option([]const u8, "graph-output", "Meteorite graph output") orelse ".meteorite/graph/current",
        .backend = b.option([]const u8, "backend", "Meteorite HTTP backend") orelse "std_http",
        .router_dispatch = b.option([]const u8, "router-dispatch", "Router dispatch strategy") orelse "method_buckets",
        .hybrid_profile = b.option([]const u8, "hybrid-profile", "Meteorite hybrid runtime profile") orelse "default",
    });
}
]]

  files["views/App.luax"] = string.format([=[-- Root View Component
--
-- The counter is NOT rendered here as a Hydronium component -- it is a
-- separate module (src/client/counter.lua) mounted entirely client-side
-- via hydronium.client.mount, so its onClick handlers really do run as
-- Lua in the browser (wasmoon), not SSR-rendered markup. This page only
-- renders the `<div id="app">` container and bootstraps that mount --
-- see src/main.lua's routes for what serves the framework/client files
-- the bootstrap script below fetches.

local H = require("hydronium")

local function App(props)
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{props.title or "%s"}</title>
        <link rel="stylesheet" href="/public/style.css" />
      </head>
      <body>
        <main class="container">
          <header class="hero">
            <h1>Welcome to %s</h1>
            <p class="subtitle">Deterministic Reactive UI for Lua</p>
          </header>

          <section class="card">
            <h2>Reactive Signal Counter</h2>
            <p class="mount-note">Mounted client-side -- real Lua, running in your browser.</p>
            <div id="app">Loading...</div>
          </section>

          <footer>
            <p>Powered by <strong>Hydronium</strong> &amp; <strong>Meteorite</strong></p>
          </footer>
        </main>

        <script type="module">{[[
          import { mount } from "/js/bootstrap/mount.js";
          import { installHmr } from "/js/bootstrap/hmr.js";

          // Dev-only: an identity minted once per real page load. A hot
          // swap leaves it alone; a full page reload replaces it. It is
          // the one thing that tells genuine HMR apart from a live
          // reload that merely looks fast, so it is worth the one line.
          window.__bootId = Math.random().toString(36).slice(2);

          const { lua } = await mount({
            hydroniumBaseUrl: "/hydronium-src",
            manifestUrl: "/__hydronium/client_manifest.json",
            appModuleId: "views.Counter",
            appModuleUrl: "/__hydronium/dev/module/views.Counter",
            container: "#app",
            props: { initial: 0 },
            hydrate: false,
            // Discovers this app's components so they can be hot-swapped
            // later. Must be set HERE, not on installHmr: component
            // families are bound at first require, which happens inside
            // mount(). Dev only -- drop it for a production build.
            hmr: true,
          });

          // `modules` maps each watched file (same list as src/main.lua's
          // /__hydronium/watch route -- keep the two in step) to the
          // require() id it is loaded under. Anything changed that is not
          // in this map falls back to a full page reload, by design.
          installHmr({
            lua: lua,
            modules: { "views/Counter.luax": "views.Counter" },
          });
        ]]}</script>
      </body>
    </html>
  )
end

return App
]=], project_name, project_name)

  -- Compiles views/App.luax on demand and returns the component function.
  -- Lives in its own requirable module (not a main.lua upvalue) for
  -- exactly the reason explained in this file's header comment and in
  -- hydronium/examples/meteorite_ssr/src/views/App.lua, which this
  -- mirrors structurally: Meteorite's hybrid build lifts inline route
  -- handlers, so a handler cannot close over a `local App = require(...)`
  -- declared above it.
  files["src/views/App.lua"] = [[-- Compiles views/App.luax on demand via hydronium_luax's serve-time
-- loader, cached by mtime -- editing and saving views/App.luax needs no
-- rebuild. Lives in its own requirable module (not a main.lua upvalue):
-- Meteorite's hybrid build mode lifts each inline route handler
-- (extracts its own source text, reloads it standalone per request), so
-- a handler cannot close over a `local App = require(...)` declared
-- above it -- `require("views.App")` from INSIDE a handler body is fine.
local loader = require("hydronium_luax").loader

return loader.load("views/App.luax")
]]

  files["src/main.lua"] = string.format([[-- Server entrypoint
local meteorite = require("meteorite")

local app = meteorite.app({
  name = "%s",
  host = "127.0.0.1",
  port = 8080,
})

meteorite.site(app, {
  root = ".",
  assets = {
    ["/public/:path*"] = { dir = "public", param = "path" },
    -- The compiled client bootstrap (mount.js, dom_bridge.js,
    -- dev_reload.js) lives in the sibling hydronium checkout, served
    -- directly from its real source -- dev/example serving, same as the
    -- /hydronium-src and /__hydronium/client routes below, not a
    -- production asset pipeline (see hydronium/docs/BUNDLING.md).
    ["/js/bootstrap/:path*"] = { dir = "../hydronium/dom/src/hydronium_dom/client", param = "path" },
  },
})

-- Serves hydronium's own runtime source for hydronium.client.mount to
-- fetch over HTTP, exactly as hydronium/examples/meteorite_ssr does --
-- restricted to `.lua`/`.json` under the two real member source roots,
-- no `..` traversal.
app:get("/hydronium-src/:path*", function(c)
  local rel = c:param("path") or ""
  if rel:find("%%.%%.") or not (rel:match("%%.lua$") or rel:match("%%.json$")) then
    return c:text(400, "invalid path")
  end
  local source_root
  if rel:match("^hydronium/") then
    source_root = "../hydronium/core/src/"
  elseif rel:match("^hydronium_dom/") then
    source_root = "../hydronium/dom/src/"
  else
    return c:text(404, "not found")
  end
  local f = io.open(source_root .. rel, "r")
  if not f then
    return c:text(404, "not found")
  end
  local content = f:read("*a")
  f:close()
  return c:text(200, content)
end)

-- The manifest hydronium.client.mount fetches to know which framework
-- files to load -- a plain JSON file this template ships, not generated
-- per-request (see hydronium/dom/tools/gen_client_manifest.lua for how
-- it was produced; regenerate it the same way if you add new client-side
-- requires that change the transitive module graph).
app:get("/__hydronium/client_manifest.json", function(c)
  local f = assert(io.open("client_manifest.json", "r"))
  local content = f:read("*a")
  f:close()
  return c:text(200, content)
end)

-- Serves ONE of this project's own view modules, by require() id, as
-- compiled Lua source. `views.Counter` -> `views/Counter.luax`, compiled
-- on demand by hydronium_luax's serve-time loader (mtime-cached, no
-- build step) and returned as text -- never executed here, because it is
-- the browser's Lua VM that runs it, not the server's.
--
-- Both the FIRST load and every hot update go through this one route:
-- src/views/App.luax's mount() passes it as `appModuleUrl`, and
-- hydronium_dom/client/hmr.js re-fetches the same URL on each change. One
-- source of truth, so the two can never drift apart.
--
-- SCOPE, deliberately: `views.*` only. This is not the general
-- `/__hydronium/dev/module/:id` route with a `loader.install()` package
-- searcher behind it that the roadmap's M3 describes -- it resolves no
-- framework modules (those still come from the manifest + /hydronium-src)
-- and installs no searcher. Serving arbitrary dotted ids from the project
-- root would also hand out src/main.lua and anything else on disk, which
-- a dev convenience has no business doing.
app:get("/__hydronium/dev/module/:id", function(c)
  local id = c:param("id") or ""
  if not id:match("^views%%.[%%w_]+$") then
    return c:text(400, "invalid module id (expected views.<Name>)")
  end

  local rel = id:gsub("%%.", "/")
  local luax_path = rel .. ".luax"
  local probe = io.open(luax_path, "r")
  if probe then
    probe:close()
    local loader = require("hydronium_luax").loader
    local ok, code = pcall(loader.source, luax_path)
    if not ok then
      -- 500 with the real compiler message in the body: hmr.js treats a
      -- non-200 as "hot swap failed" and falls back to a full reload,
      -- and the message is then readable in the network panel rather
      -- than swallowed. (A real error overlay is roadmap M5.)
      return c:text(500, "-- hydronium dev: compile failed for " .. id .. "\n-- " .. tostring(code))
    end
    return c:text(200, code)
  end

  local f = io.open(rel .. ".lua", "r")
  if not f then
    return c:text(404, "not found")
  end
  local content = f:read("*a")
  f:close()
  return c:text(200, content)
end)

app:get("/", function(c)
  local meteorite_adapter = require("hydronium_dom.server.meteorite")
  local AppView = require("views.App")
  return meteorite_adapter.render(c, AppView, {
    status = 200,
    props = { title = "%s" },
  })
end)

app:get("/api/health", function(c)
  return c:json({ status = "ok", timestamp = os.time() })
end)

-- Dev update endpoint: the browser's hmr.js (served above) connects here
-- and is told, per change, exactly WHICH of these files moved -- so a
-- change to views/Counter.luax is hot-swapped inside the live Lua VM
-- with no page reload, while a change to anything it has no mapping for
-- falls back to reloading the page. See hydronium_dom.dev.watch's own
-- doc comment for why this route must stay written inline here rather
-- than behind a one-line library call (Meteorite's hybrid build can only
-- lift an inline handler it can see the literal source of).
--
-- Keep this list in step with the `modules` map in views/App.luax: this
-- side decides what is watched, that side decides what a watched file
-- means to the running VM.
--
-- These files sit at the PROJECT ROOT, not under src/, and that is
-- load-bearing: `meteorite dev` watches src/ and rebuilds and restarts
-- the server when anything there changes, which would tear down the very
-- page HMR is trying to preserve.
app:get("/__hydronium/watch", function(c)
  local watch = require("hydronium_dom.dev.watch")
  watch.serve_sse(c, { "views/App.luax", "views/Counter.luax" })
end)

return app
]], project_name, project_name)

  -- The real, client-executed component -- compiled on demand by
  -- src/main.lua's /__hydronium/dev/module route, fetched over HTTP by
  -- mount.js, and run live in the browser via wasmoon.
  --
  -- Edit this file while `moon run dev` is up and the running page is
  -- hot-swapped in place: the counter keeps its current value and its
  -- DOM nodes are never remounted. Try changing `+ 1` to `+ 5`.
  --
  -- Note what this file does NOT contain: any HMR annotation. The state
  -- is declared as an ordinary `signals.createSignal(...)`, and
  -- hydronium_luax's compile-time refresh pass rewrites it into the
  -- descriptor form the refresh registry matches on
  -- (`scope.refresh_registry:signal(v, {kind, name, block_path})`) --
  -- which is what earlier versions of this template had to hand-write.
  -- Two conditions make the pass recognize it, both satisfied here and
  -- both easy to break by accident: the setup function takes a parameter
  -- literally named `scope`, and the declaration is a two-name
  -- destructure at the setup function's top level (not inside the
  -- returned render function, an `if`, or a loop).
  --
  -- Uses a BARE `{count}` binding as the display's text child (not
  -- `{count()}`, called), so each click patches only that text node via a
  -- fine-grained Hydronium DOM binding effect instead of re-running this
  -- whole component -- ground truth for this being the default, not
  -- opt-in, behavior is
  -- hydronium/core/src/hydronium/core/reconciler.lua's
  -- Reconciler:_bindReactiveText.
  --
  -- `local H = ...` is deliberate. Compiled LUAX emits `H.h(...)` for
  -- every element, resolved as an ordinary Lua name -- so a file-level
  -- `local H` satisfies it directly, and the browser VM never has to
  -- fetch the whole `hydronium` barrel (which pulls in the test renderer)
  -- just to supply a global one.
  files["views/Counter.luax"] = [[local H = require("hydronium.core.element")
local dom = require("hydronium_dom")
local signals = require("hydronium.signals")
local d = dom.d

local function Counter(props, scope)
  local count, setCount = signals.createSignal(props.initial or 0)

  return function()
    return (
      <d.div class="counter-box">
        <d.span class="count-display">{"Count: "}{count}</d.span>
        <d.div class="button-group">
          <d.button class="btn btn-secondary" onClick={function() setCount(count() - 1) end}>-</d.button>
          <d.button class="btn btn-primary" onClick={function() setCount(count() + 1) end}>+</d.button>
        </d.div>
      </d.div>
    )
  end
end

return Counter
]]

  -- The real module manifest hydronium.client.mount fetches to resolve
  -- every `require(...)` the client component transitively needs --
  -- derived from the ACTUAL require() graph via
  -- hydronium/dom/tools/gen_client_manifest.lua (never hand-maintained;
  -- see that tool's own doc comment), and identical to the one already
  -- proven live against hydronium/examples/meteorite_ssr/client_mount_demo,
  -- since a component using `require("hydronium_dom")` + `dom.d` +
  -- `scope.refresh_registry:signal(...)` transitively requires exactly
  -- this same module set regardless of the app's own business logic.
  files["client_manifest.json"] = [[{
  "hydronium.core.reconciler": "hydronium/core/reconciler.lua",
  "hydronium.core.symbols": "hydronium/core/symbols.lua",
  "hydronium.core.errors": "hydronium/core/errors.lua",
  "hydronium.core.ref": "hydronium/core/ref.lua",
  "hydronium.core.component": "hydronium/core/component.lua",
  "hydronium.core.scope": "hydronium/core/scope.lua",
  "hydronium.core.scheduler": "hydronium/core/scheduler.lua",
  "hydronium.core.context": "hydronium/core/context.lua",
  "hydronium.core.element": "hydronium/core/element.lua",
  "hydronium.core.suspense": "hydronium/core/suspense.lua",
  "hydronium.signals.graph": "hydronium/signals/graph.lua",
  "hydronium.core.family_loader": "hydronium/core/family_loader.lua",
  "hydronium.core.family": "hydronium/core/family.lua",
  "hydronium.core.refresh": "hydronium/core/refresh.lua",
  "hydronium.signals": "hydronium/signals/init.lua",
  "hydronium.signals.signal": "hydronium/signals/signal.lua",
  "hydronium.signals.computed": "hydronium/signals/computed.lua",
  "hydronium.signals.effect": "hydronium/signals/effect.lua",
  "hydronium.signals.batch": "hydronium/signals/batch.lua",
  "hydronium_dom": "hydronium_dom/init.lua",
  "hydronium_dom.dom.init": "hydronium_dom/dom/init.lua",
  "hydronium_dom.host.dom": "hydronium_dom/host/dom.lua"
}
]]

  files["public/style.css"] = [[* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  background: #0f172a;
  color: #f8fafc;
  display: flex;
  justify-content: center;
  align-items: center;
  min-height: 100vh;
}

.container {
  max-width: 640px;
  width: 100%;
  padding: 2rem;
}

.hero {
  text-align: center;
  margin-bottom: 2rem;
}

.hero h1 {
  font-size: 2.5rem;
  font-weight: 700;
  background: linear-gradient(135deg, #38bdf8, #818cf8);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  margin-bottom: 0.5rem;
}

.subtitle {
  color: #94a3b8;
  font-size: 1.1rem;
}

.card {
  background: #1e293b;
  border-radius: 12px;
  padding: 2rem;
  box-shadow: 0 10px 25px rgba(0, 0, 0, 0.3);
  border: 1px solid #334155;
  text-align: center;
  margin-bottom: 2rem;
}

.card h2 {
  font-size: 1.3rem;
  margin-bottom: 1.5rem;
  color: #e2e8f0;
}

.counter-box {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 1.25rem;
}

.count-display {
  font-size: 2rem;
  font-weight: 600;
  color: #38bdf8;
}

.button-group {
  display: flex;
  gap: 1rem;
}

.btn {
  padding: 0.6rem 1.5rem;
  font-size: 1.25rem;
  font-weight: bold;
  border-radius: 8px;
  border: none;
  cursor: pointer;
  transition: transform 0.1s ease, background-color 0.2s ease;
}

.btn:hover {
  transform: translateY(-2px);
}

.btn-primary {
  background: #38bdf8;
  color: #0f172a;
}

.btn-primary:hover {
  background: #7dd3fc;
}

.btn-secondary {
  background: #334155;
  color: #f8fafc;
}

.btn-secondary:hover {
  background: #475569;
}

footer {
  text-align: center;
  color: #64748b;
  font-size: 0.9rem;
}
]]

  files["README.md"] = string.format([[# %s

Full-stack SSR application built with [Hydronium](https://moonstone.sh/packages/hydronium) and [Meteorite](https://moonstone.sh/packages/meteorite).

This template uses Moonstone path dependencies for Hydronium's core, LuaX,
and DOM packages. For local development it assumes your project sits next to
the `hydronium` workspace and a `meteorite` clone, e.g.:

```
some-parent-dir/
  hydronium/
  meteorite/
  %s/   <- this project
```

## The counter, and hot reloading

`views/Counter.luax` is a real Hydronium component that runs **in your
browser**, as Lua: `views/App.luax` renders an empty `<div id="app">` and
boots a wasmoon VM into it, so the button's `onClick` is a genuine Lua
closure, not a JS shim.

With `moon run dev` running, edit `views/Counter.luax` -- change `+ 1` to
`+ 5` -- and save. The page does **not** reload. The counter keeps the
value it was already showing, its DOM nodes are never remounted, and the
next click uses the new logic.

Nothing in `views/Counter.luax` opts into that. Its state is an ordinary
`signals.createSignal(...)`; hydronium's LUAX compiler attaches the
descriptor that makes the value survive a swap. Two things do have to hold
for it to be recognized, and both are easy to break by accident:

- the setup function takes a parameter literally named `scope`;
- the signal is declared as `local x, setX = ...` at the setup function's
  top level -- not inside the returned render function, an `if`, or a loop.

Break either and nothing errors: that signal simply resets to its initial
value on each edit, exactly as it would have before this feature existed.

Changing anything the page has no module mapping for -- `views/App.luax`,
a stylesheet, a route -- falls back to a full page reload, which is the
correct answer for a change that cannot be applied in place.

## Getting Started

1. **Install Dependencies:**
   ```bash
   moon sync
   ```

2. **Start Dev Server:**
   ```bash
   moon run dev
   ```

3. **Build for Production:**
   ```bash
   moon run build
   ./dist/server
   ```
]], project_name, project_name)

  return files
end

return ssr
