local ssr = {}

--[[
  Full-stack SSR template: real Meteorite + Hydronium API, verified live
  against a freshly scaffolded project (moon exec meteorite graph, zig
  build -Dmode=release-hybrid -Dbackend=std_http, ./dist/server, curl).

  Ground truth for every API shape below is
  hydronium/examples/quickstart/{src/main.lua, src/views/Document.lua,
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
    captures outer local". This is why views/Document.lua exists as its own
    requirable module instead of a `main.lua` upvalue.
  - Rendering goes through `require("hydronium_dom.server.meteorite").render(c,
    Document, {status=200, props={...}})` -- takes the COMPONENT (not a
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
    exactly that mechanism for its client application (views/App.luax,
    mounted into the `<div id="app">` in views/Document.luax) instead of the
    non-hydrating `<d.lua.island>` pattern -- clicking the button in a
    browser really does call Lua running client-side. The counter also
    uses a BARE `{count}` binding (not `{count()}`) as its text child, so
    each click patches only that text node directly via a fine-grained
    Hydronium DOM binding, without re-running the whole component.

  - Framework plumbing is not generated into the app. `main.lua` calls
    `require("hydronium_dom.server.meteorite").mount(app)`, which declares
    the browser runtime (`/js/bootstrap`, `/js/router`), framework source
    (`/hydronium-src`), the framework module manifest (derived from the
    project's real require graph -- no pasted client_manifest.json to drift),
    the dev module server (`/__hydronium/dev/module/:id`) and the HMR stream
    (`/__hydronium/watch`). Its Lua routes are `m.lua` file handlers shipped
    inside hydronium/dom, so Meteorite's hybrid lifting never sees a closure.
    This is dev/unbundled serving, not a production asset pipeline -- see
    hydronium/docs/BUNDLING.md.

  - HMR, not live reload (roadmap M2). `/__hydronium/watch` is built on
    `hydronium_dom.dev.watch` (real, reusable framework code) and now
    reports WHICH watched file moved, not merely that something did. The
    browser side is `hydronium_dom/client/hmr.js`: it re-fetches just that
    module's freshly compiled source, installs it as `package.preload[id]`
    in the SURVIVING wasmoon VM, and calls `family_loader.reload(id)` --
    so the counter keeps its value and its DOM nodes across an edit, with
    no page navigation. A full page reload is the explicit safety fallback
    when a requested hot swap cannot be proven to have worked.
    `dev_reload.js` remains the simpler client for a page with no Lua VM.

  - `hydronium.sources.lua` is the single watch declaration: the HMR stream
    and `hydronium.dev_watch()` both derive from it. Its `updates` policies
    reach the browser through `/__hydronium/dev/manifest.json`; application
    modules use `hot`, the document uses `reload`.

  - THE `dev` SCRIPT RUNS `hydronium dev`, NOT `meteorite dev` DIRECTLY.
    `hydronium dev` (hydronium/cli, declared as a `tool`
    dependency above alongside meteorite itself) spawns exactly the same
    `meteorite dev` invocation this template used to run inline, tails the
    structured dev-event stream meteorite writes to
    `.meteorite/dev/events.log`, mirrors it into a durable
    `.hydronium/dev.log`, and renders a live status view (plus a
    fullscreen request-debug view on `f`). `moon run dev` is unchanged for
    the user.

    The meteorite flags travel in ONE `--meteorite-args` value rather than as
    trailing arguments: `moon exec` forwards everything after its own `--`
    verbatim, including any further `--` the child wants for itself (verified:
    `moon exec -- printf '[%s]' -- -- x` prints `[--][--][x]`), so `--`
    passthrough would reach `hydronium dev` intact -- the actual risk is
    upstream, since `moon run` hands the script body to the host shell before
    Moonstone ever parses it. A `hydronium dev -- --mode ...` line would depend
    on shell quoting to keep those flags together across edits; a single named,
    single-quoted `--meteorite-args='...'` value arrives as ONE argument
    regardless. The environment variable
    `HYDRONIUM_METEORITE_ARGS` still overrides it for a one-off run
    without editing this file (its words are appended after the flag's,
    and meteorite takes the last occurrence of a flag).

  - Transformed UI source lives under `src/views/`. The scaffold classifies
    client leaf modules as Meteorite `passive`/`exclude` inputs, while the
    document and shared route definitions remain graph inputs. HMR therefore
    preserves client state without making server-visible source edits stale.
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
dev = "moon exec --dev -- hydronium dev --watch-sources --meteorite-args='--mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit'"
build = "moon exec -- ballad play build.partiture.lua && moon exec --dev -- meteorite build --mode release-hybrid --backend fast_http --lua-root .moonstone/env/libexec/luajit"

[[dependencies]]
name = "moonstone/meteorite"
# 0.3 adds `meteorite client typescript|luacats` (typed DTOs from the route
# graph) on top of 0.2.9's dev-event request headers/bodies, which `hydronium
# dev`'s filter bar queries (mime:, origin:, header:, body:).
constraint = "^0.3.1"
role = "tool"

[[dependencies]]
name = "hydronium/cli"
constraint = "^0.4.2"
role = "tool"

[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.4.0"
role = "tool"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.3"
role = "runtime"

[[dependencies]]
name = "hydronium/luax"
constraint = "^0.2.3"
role = "runtime"

[[dependencies]]
name = "hydronium/dom"
constraint = "^0.3.2"
role = "runtime"

# Ballad plugins: partiture.lua discovers this project's Lua sources.
[[dependencies]]
name = "hydronium/ballad"
constraint = "^0.2.2"
role = "runtime"

[[dependencies]]
name = "hydronium/router"
constraint = "^0.2.2"
role = "runtime"
]=], project_name)

  -- `.hydronium/` holds `hydronium dev`'s own durable dev log and the
  -- spawned server's captured output -- local run artifacts, like
  -- `.meteorite/`.
  files[".gitignore"] = [[.moonstone/
dist/
.zig-cache/
zig-out/
.meteorite/
.hydronium/
*.log
]]

  -- Lua source discovery is a Ballad node. `hydronium dev --watch-sources`
  -- re-runs it when a file under a declared root appears or disappears;
  -- `moon run build` runs it before compiling the server.
  files["partiture.lua"] = [[-- Ballad discovers every .lua/.luax file under the roots declared in
-- hydronium.sources.lua and writes .hydronium/ballad/source-inventory.lua, the
-- module authority the Meteorite dev host (hydronium.mount) serves from.
local ballad = require("ballad")
local hb = require("hydronium_ballad")

return ballad.partiture(function(p)
  hb.source_inventory(p)
end)
]]

  -- Release build: discovery plus the production browser bundle. The server
  -- (hydronium.mount, release mode) serves the hashed chunk and pages boot
  -- from it instead of fetching modules one by one.
  files["build.partiture.lua"] = [[-- `moon run build` runs this before compiling the server: the source
-- inventory, then one content-hashed browser chunk with every client/shared
-- module declared in hydronium.sources.lua plus only the framework modules
-- they reach (.hydronium/client/).
local ballad = require("ballad")
local hb = require("hydronium_ballad")

return ballad.partiture(function(p)
  hb.source_inventory(p)
  hb.client_bundle(p)
end)
]]

  files["hydronium.sources.lua"] = [[-- Project-owned browser/source topology: which directories hold modules and
-- how edits to them apply. Ballad (partiture.lua) turns it into the explicit
-- inventory the dev host serves from, so no request ever scans the disk.
return {
  entry = "views.App",
  roots = {
    { path = "src/components", namespace = "components", target = "client", update = "hot", effects = "safe" },
    { path = "src/views", namespace = "views", target = "client", update = "hot", effects = "safe",
      transforms = { lua = "lua", luax = "luax" } },
  },
  entries = {
    { id = "views.App", path = "src/views/App.luax" },
    { id = "views.Document", path = "src/views/Document.luax", target = "server", update = "reload", effects = "restart" },
    { id = "views.Site", path = "src/views/Site.lua", target = "shared", update = "reload", effects = "restart" },
    { id = "views.Actions", path = "src/views/Actions.lua", target = "shared", update = "reload", effects = "restart" },
  },
}
]]

  -- Registry packages mount at `.moonstone/env/libexec/<namespace>/<package>`
  -- (Moonstone 0.5.9+; the flat `libexec/meteorite` alias is absent whenever
  -- another package, such as Lab's hydronium/meteorite, shares the name).
  -- Meteorite's collected Zig sources live one level below that root.
  files["build.zig"] = [[const std = @import("std");
const meteorite = @import(".moonstone/env/libexec/moonstone/meteorite/meteorite/zig/build_api.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = meteorite.addService(b, .{
        .meteorite_root = ".moonstone/env/libexec/moonstone/meteorite/meteorite",
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

  files["src/views/Document.luax"] = string.format([=[-- Stable server document boundary, analogous to Vite's index.html.
-- Application UI belongs in views/App.luax and refreshes inside the
-- surviving browser Lua VM. Editing this file intentionally reloads the page.

local H = require("hydronium")

local function Document(props)
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{props.title or "%s"}</title>
        <link rel="stylesheet" href="/public/style.css" />
      </head>
      <body>
        <div id="app">{props.app}</div>

        <script type="module">{[[
          import { mount } from "/js/bootstrap/mount.js";
          import { installHmr } from "/js/bootstrap/hmr.js";
          import { createHistoryGlobals } from "/js/router/history.js";
          import { createHttpGlobals } from "/js/router/http.js";
          import { createFormGlobals } from "/js/bootstrap/forms.js";

          window.__bootId = Math.random().toString(36).slice(2);
          const pageStateText = document.getElementById("__HYDRONIUM_STATE__")?.textContent;
          const routerState = pageStateText
            ? JSON.stringify(JSON.parse(pageStateText).hydronium_router)
            : undefined;
          const sourceResponse = await fetch("/__hydronium/dev/manifest.json", { cache: "no-store" });
          if (!sourceResponse.ok) throw new Error("Hydronium source manifest unavailable");
          const sourceManifest = await sourceResponse.json();
          const appModule = sourceManifest.modules[sourceManifest.entry];
          if (!appModule) throw new Error("Hydronium source manifest has no browser entry");
          const moduleUrls = Object.fromEntries(
            Object.entries(sourceManifest.modules).map(([id, record]) => [id, record.url]),
          );
          const moduleEffects = Object.fromEntries(
            Object.entries(sourceManifest.modules).map(([id, record]) => [id, record.effects]),
          );

          // Release builds with a Ballad bundle boot from its hashed chunk;
          // development (and unbundled builds) load modules one by one.
          const bundled = Array.isArray(sourceManifest.chunks) && sourceManifest.chunks.length > 0;
          const { lua, remount } = await mount({
            ...(bundled
              ? { chunkUrls: sourceManifest.chunks }
              : {
                  hydroniumBaseUrl: "/hydronium-src",
                  manifestUrl: "/__hydronium/client_manifest.json",
                  appModuleUrl: appModule.url,
                  moduleUrls,
                  moduleEffects,
                }),
            appModuleId: sourceManifest.entry,
            container: "#app",
            props: { title: "%s", initial: 0 },
            hydrate: true,
            hmr: true,
            luaGlobals: {
              ...createHistoryGlobals(),
              ...createHttpGlobals(),
              ...createFormGlobals(),
              __hydronium_router_state: routerState || undefined,
            },
          });

          // Release builds serve no HMR stream and say so in the manifest.
          if (sourceManifest.hmr !== false) installHmr({
            lua,
            remount,
            updates: {
              ...sourceManifest.updates,
              "hydronium.sources.lua": { action: "reload" },
            },
          });
        ]]}</script>
      </body>
    </html>
  )
end

return Document
]=], project_name, project_name)

  -- Compiles views/Document.luax on demand and returns the component function.
  -- Lives in its own requirable module (not a main.lua upvalue) for
  -- exactly the reason explained in this file's header comment and in
  -- hydronium/examples/quickstart/src/views/Document.lua, which this
  -- mirrors structurally: Meteorite's hybrid build lifts inline route
  -- handlers, so a handler cannot close over a `local App = require(...)`
  -- declared above it.


  files["src/app/page_handler.lua"] = string.format([[-- Hybrid request VMs have their own package loaders; install once at this entry.
require("hydronium_luax").loader.install()
local adapter = require("hydronium_router.meteorite")
local dom = require("hydronium_dom.server.meteorite")
local site = require("views.Site")

return adapter.handler(site, {
  resolve = require,
  resolve_loader = require,
  render = function(c, page, opts)
    local Document = require("views.Document")
    local d = require("hydronium_dom").d
    return dom.render(c, Document, {
      status = opts.status,
      state = opts.state,
      props = { title = "%s", app = d.lua.mount(page, { module = "views.App" }) },
    })
  end,
})
]], project_name)

  files["src/app/contact_action.lua"] = [[local H = require("hydronium.core")
local action = require("views.Actions").contact

return function(ctx)
  local valid, errors, output = action:check(ctx.values)
  if not valid then
    return H.action_fail({ values = ctx.values, errors = errors })
  end
  return H.action_ok({
    status = 201,
    data = { greeting = "Hello, " .. output.name },
  })
end
]]

  files["src/app/action_handler.lua"] = [[local adapter = require("hydronium_router.meteorite")
local site = require("views.Site")

return adapter.action_handler(site, {
  resolve_action = require,
})
]]

  files["src/views/Site.lua"] = [[local r = require("hydronium_router")

return r.createSite({
  root = r.node({
    id = "root",
    path = "/",
    children = {
      r.node({
        id = "home",
        path = "",
        screen = "views.Home",
        actions = { contact = { id = "contact.submit", ref = "app.contact_action", path = "/actions/contact" } },
      }),
      r.node({ id = "about", path = "about", screen = "views.About" }),
    },
  }),
})
]]

  -- Meteorite owns HTTP; everything here is an ordinary Meteorite route.
  -- `hydronium.mount(app)` declares the framework's own routes (browser
  -- runtime, framework source, module manifest, dev module server, HMR
  -- stream) as file handlers shipped inside hydronium/dom, so none of that
  -- plumbing is copied into the application.
  files["src/main.lua"] = string.format([[-- Server entrypoint.
--
-- Meteorite owns HTTP: every route below is an ordinary Meteorite
-- declaration. Hydronium contributes three things to it:
--
--   1. `hydronium.mount(app)` -- the framework's own routes (browser runtime,
--      framework source, dev module server, HMR stream). Nothing to copy.
--   2. `router.mount(app, site, ...)` -- one GET per addressable page in
--      views/Site.lua, rendered by app/page_handler.lua, plus its form actions.
--   3. Plain route handlers -- any Meteorite route can render a Hydronium
--      component (see /hello/:name and app/hello.lua).
--
-- Handlers live in their own modules (`meteorite.lua("app.x")`) because
-- Meteorite's hybrid build loads each handler standalone per request; an
-- inline `function(c) ... end` must not capture locals from this file.
local meteorite = require("meteorite")
local hydronium = require("hydronium_dom.server.meteorite")
local router = require("hydronium_router.meteorite")
require("hydronium_luax").loader.install()

local app = meteorite.app({
  name = "%s",
  host = "127.0.0.1",
  port = tonumber(os.getenv("PORT")) or 8080,
  -- Hot UI modules declared in hydronium.sources.lua are passive: the browser
  -- swaps them in place, so editing one must not restart the server.
  dev_watch = hydronium.dev_watch(),
})

-- Before meteorite.site: Meteorite matches routes in declaration order, and in
-- development mount may serve watched stylesheets from disk at their own URL.
hydronium.mount(app)

meteorite.site(app, {
  root = ".",
  assets = {
    ["/public/:path*"] = { dir = "public", param = "path" },
  },
})

local site = require("views.Site")
router.mount(app, site, {
  handler = meteorite.lua("app.page_handler", { arg_mode = "lazy_context" }),
  action_handler = meteorite.lua("app.action_handler", { arg_mode = "lazy_context" }),
})

-- A plain Meteorite route rendering a Hydronium component: no router, no
-- browser VM. The component lives in src/features/, not src/views/.
app:get("/hello/:name", {
  summary = "Server-rendered greeting",
}, meteorite.lua("app.hello", { arg_mode = "lazy_context" }))

app:get("/api/health", { summary = "Health check" }, function(c)
  return c:json({ status = "ok", timestamp = os.time() })
end)

router.validate_final(app, site)

return app
]], project_name)

  files["src/app/hello.lua"] = [[-- A Meteorite route handler that renders a Hydronium component on the server.
-- Each hybrid request VM has its own package loaders, so install the LUAX
-- searcher at this entry before requiring a .luax module.
require("hydronium_luax").loader.install()
local dom = require("hydronium_dom.server.meteorite")
local Greeting = require("features.greeting.Greeting")

return function(c)
  return dom.render(c, Greeting, {
    props = { name = c:param("name") },
  })
end
]]

  files["src/features/greeting/Greeting.luax"] = [[-- Rendered by a plain Meteorite route (src/app/hello.lua). Components are
-- ordinary modules: they can live anywhere on the Lua path, not only views/.
local H = require("hydronium")
local d = require("hydronium_dom").d

local function Greeting(props)
  return (
    <d.html lang="en">
      <d.head>
        <d.meta charset="utf-8" />
        <d.title>Hello, {props.name}</d.title>
        <d.link rel="stylesheet" href="/public/style.css" />
      </d.head>
      <d.body>
        <d.main class="container">
          <d.h1>Hello, {props.name}!</d.h1>
          <d.p>
            This page is a plain Meteorite route whose handler renders a
            Hydronium component. <d.a href="/">Back to the app</d.a>
          </d.p>
        </d.main>
      </d.body>
    </d.html>
  )
end

return Greeting
]]

  -- The client application root. Keeping it separate from Document.luax
  -- makes normal layout edits hot-swappable instead of page reloads.
  files["src/views/App.luax"] = [[local H = require("hydronium.core.element")
local r = require("hydronium_router")
local site = require("views.Site")
local d = require("hydronium_dom").d

local function App()
  local router = site:createRouter({
    history = r.createBrowserHistory(),
    resolve = require,
    resolve_loader = require,
  })

  return function()
    return d.lua.mount(H.h(router.Provider, nil, H.h(r.Outlet)), { module = "views.App" })
  end
end

return App
]]

  files["src/views/Home.luax"] = string.format([[local H = require("hydronium.core.element")
local dom = require("hydronium_dom")
local Counter = require("views.Counter")
local actions = require("views.Actions")
local d = dom.d

local function Home()
  local navigate = require("hydronium_router").useNavigate()
  local form = require("hydronium.core.form").useForm(actions.contact, { enhance = true })

  local go_about = nil
  if _G.__dom_set_listener then
    go_about = function()
      navigate("/about")
    end
  end

  return function()
    return (
      <d.main class="container">
        <d.header class="hero">
          <d.h1>Welcome to %s</d.h1>
          <d.p class="subtitle">One route manifest, used by Hydronium and Meteorite.</d.p>
          <d.a href="/about" onNavigate={go_about}>About this app</d.a>
        </d.header>

        <d.section class="card">
          <d.h2>Reactive Signal Counter</d.h2>
          <Counter initial={0} />
        </d.section>

        <d.section class="card">
          <d.h2>Progressive action</d.h2>
          <d.form method={form.props.method} action={form.props.action} onSubmit={form.props.onSubmit}>
            <d.label for="name">Name</d.label>
            <d.input id="name" name="name" />
            <d.button type="submit" disabled={form:pending()}>Send</d.button>
            <d.p class="form-error">{function() return form:error("name") or form:error("_form") or "" end}</d.p>
            <d.p class="form-result">{function()
              local result = form:data()
              return result and result.greeting or ""
            end}</d.p>
          </d.form>
        </d.section>
      </d.main>
    )
  end
end

return Home
]], project_name)

  files["src/views/About.luax"] = [[local H = require("hydronium.core.element")
local d = require("hydronium_dom").d

local function About()
  local navigate = require("hydronium_router").useNavigate()
  local go_home = nil
  if _G.__dom_set_listener then
    go_home = function()
      navigate("/")
    end
  end
  return (
    <d.main class="container">
      <d.header class="hero">
        <d.h1>About</d.h1>
        <d.p class="subtitle">This page is selected by the shared site declaration.</d.p>
        <d.a href="/" onNavigate={go_home}>Back home</d.a>
      </d.header>
    </d.main>
  )
end

return About
]]

  files["src/views/Actions.lua"] = [[local H = require("hydronium.core")

local name_schema = {
  ["~standard"] = {
    validate = function(values)
      if type(values.name) ~= "string" or values.name:match("^%s*$") then
        return { issues = { { path = { { key = "name" } }, message = "Enter your name" } } }
      end
      return { value = values }
    end,
  },
}

return {
  contact = H.action({
    id = "contact.submit",
    path = "/actions/contact",
    method = "POST",
    schema = name_schema,
  }),
}
]]

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
  files["src/views/Counter.luax"] = [[local H = require("hydronium.core.element")
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

The generated manifest uses registry packages. No sibling source checkout is
required. If you are testing unreleased packages, add a local Moonstone
registry before running `moon sync`.

## Routes and actions

Meteorite owns HTTP. `src/main.lua` is an ordinary Meteorite app with three
kinds of routes:

- **Framework routes** -- `hydronium.mount(app)` declares the browser runtime,
  framework source and the dev/HMR endpoints. You never edit these.
- **Pages** -- `src/views/Site.lua` is the page manifest. The browser creates a
  reactive router from it; `hydronium_router.meteorite` lowers the same route
  leaves to explicit Meteorite GET routes rendered by `src/app/page_handler.lua`.
- **Your routes** -- anything else is a normal Meteorite route. A handler can
  return JSON (`/api/health`) or render any Hydronium component on the server:
  `/hello/:name` is handled by `src/app/hello.lua`, which renders
  `src/features/greeting/Greeting.luax`. Components can live anywhere on the
  Lua path.

`src/views/Actions.lua` defines the shared `contact.submit` action. The form in
`src/views/Home.luax` works as a normal HTML POST before hydration. Once the browser
Lua VM is ready, the same form validates through its Standard Schema contract,
submits in the background, consumes a JSON action result without navigation,
and exposes pending,
field-error, and result state through `useForm`.

## The counter, and hot reloading

`src/views/App.luax` is the hot application root and `src/views/Counter.luax` is
its child. Both run **in your browser**, as Lua. `src/views/Document.luax` is
the stable server-rendered shell that boots the VM, analogous to Vite's
`index.html`.

With `moon run dev` running, edit `src/views/Counter.luax` -- change `+ 1` to
`+ 5` -- and save. The page does **not** reload. The counter keeps the
value it was already showing, its DOM nodes are never remounted, and the
next click uses the new logic.

Nothing in `src/views/Counter.luax` opts into that. Its state is an ordinary
`signals.createSignal(...)`; hydronium's LUAX compiler attaches the
descriptor that makes the value survive a swap. Two things do have to hold
for it to be recognized, and both are easy to break by accident:

- the setup function takes a parameter literally named `scope`;
- the signal is declared as `local x, setX = ...` at the setup function's
  top level -- not inside the returned render function, an `if`, or a loop.

Break either and nothing errors: that signal simply resets to its initial
value on each edit, exactly as it would have before this feature existed.

Edit `src/views/App.luax` and the counter state survives while the application
layout refreshes. Editing `public/style.css` replaces the stylesheet in
place. Only `src/views/Document.luax` is an explicit page-reload boundary.

## Getting Started

1. **Install Dependencies:**
   ```bash
   moon sync
   ```

2. **Start Dev Server:**
   ```bash
   moon run dev
   ```

   This runs `hydronium dev`, which starts the Meteorite dev server with
   this project's own `--mode`/`--backend`/`--lua-root` flags (they live in
   the `dev` script in `moonstone.toml`) and renders its dev-event stream
   live. Keys: `f` opens a fullscreen request inspector (every request,
   with status, duration and remote address), `esc` leaves it, `q` quits.
   Every event is also appended to `.hydronium/dev.log`.

3. **Build for Production:**
   ```bash
   moon run build
   ./dist/server
   ```
]], project_name)

  return files
end

return ssr
