local ssr = {}
local look = require("create.look")

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
constraint = "^0.3.5"
role = "tool"

[[dependencies]]
name = "hydronium/cli"
constraint = "^0.4.2"
role = "tool"

[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.4.2"
role = "tool"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.5"
role = "runtime"

[[dependencies]]
name = "hydronium/luax"
constraint = "^0.2.5"
role = "runtime"

[[dependencies]]
name = "hydronium/dom"
constraint = "^0.3.5"
role = "runtime"

# Ballad plugins: partiture.lua discovers this project's Lua sources.
[[dependencies]]
name = "hydronium/ballad"
constraint = "^0.2.4"
role = "runtime"

[[dependencies]]
name = "hydronium/router"
constraint = "^0.2.3"
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
  entry = "views.Client",
  roots = {
    { path = "src/views", namespace = "views", target = "client", update = "hot", effects = "safe",
      transforms = { lua = "lua", luax = "luax" } },
  },
  entries = {
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

  files["src/views/Document.luax"] = string.format([=[-- The HTML shell, analogous to Vite's index.html. It boots the browser Lua
-- VM; everything visible is src/views/App.luax and the pages, which update in
-- place. Editing this file reloads the page.

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
        <div class="glow" aria-hidden="true"></div>
        <script type="module" src="/public/ui/starter.js"></script>
        <div id="app">{props.app}</div>

        <script type="module">{[[
          import { mount } from "/js/bootstrap/mount.js";
          import { installHmr } from "/js/bootstrap/hmr.js";
          import { createHistoryGlobals } from "/js/router/history.js";
          import { createHttpGlobals } from "/js/router/http.js";
          import { createFormGlobals } from "/js/bootstrap/forms.js";

          window.__bootId = Math.random().toString(36).slice(2);
          const pageStateText = document.getElementById("__HYDRONIUM_STATE__")?.textContent;
          const pageState = pageStateText ? JSON.parse(pageStateText) : {};
          const routerState = pageState.hydronium_router
            ? JSON.stringify(pageState.hydronium_router) : undefined;
          // A native POST returns the home UI. Restore its canonical route
          // before hydration, while retaining the submitted form state.
          if (pageState.hydronium_greeting) history.replaceState(null, "", "/");
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

          // Release builds boot from one hashed Ballad chunk; development
          // loads modules one by one so each can be swapped in place.
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
            props: { title: "%s" },
            hydrate: true,
            hmr: true,
            luaGlobals: {
              ...createHistoryGlobals(),
              ...createHttpGlobals(),
              ...createFormGlobals(),
              __hydronium_router_state: routerState || undefined,
              __hydronium_greeting_outcome: pageState.hydronium_greeting
                ? JSON.stringify(pageState.hydronium_greeting) : undefined,
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

  -- Meteorite's hybrid build loads each handler standalone per request, so
  -- handlers are their own modules and require what they need inside.
  files["src/app/page_handler.lua"] = string.format([[-- Renders every page in src/views/Site.lua on the server. The page tree is
-- marked as a browser Lua mount, so the same views keep running client-side.
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
      props = { title = "%s", app = d.lua.mount(page, { module = "views.Client" }) },
    })
  end,
})
]], project_name)

  files["src/app/hello_action.lua"] = [[-- Server side of the `hello` action (src/views/Actions.lua). It answers a
-- plain HTML form post and the browser's enhanced submit alike.
local H = require("hydronium.core")
local action = require("views.Actions").hello

return function(ctx)
  local valid, errors, output = action:check(ctx.values)
  if not valid then
    return H.action_fail({ values = ctx.values, errors = errors })
  end
  local greeting = (string.rep("Hello, " .. output.name .. "! ", output.times):gsub("%s+$", ""))
  return H.action_ok({ status = 201, data = { greeting = greeting, values = { name = output.name, times = output.times } } })
end
]]

  files["src/app/action_handler.lua"] = [[require("hydronium_luax").loader.install()
local adapter = require("hydronium_router.meteorite")
local site = require("views.Site")

return adapter.action_handler(site, {
  resolve_action = require,
  -- A normal HTML POST returns the same home form, including its values,
  -- errors and greeting. Its serialized initial state survives hydration.
  progressive = function(c, outcome)
    local H = require("hydronium.core.element")
    local r = require("hydronium_router")
    local memory = require("hydronium_router.history.memory")
    local dom = require("hydronium_dom.server.meteorite")
    local d = require("hydronium_dom").d
    local Greeting = require("views.Greeting")
    local initial = {
      values = outcome.values or (outcome.data and outcome.data.values) or {},
      errors = outcome.errors or {}, status = outcome.status, data = outcome.data,
    }
    local router = site:createRouter({
      history = memory.create_memory_history({ initial = "/" }), resolve = require,
    })
    local page = H.h(Greeting.Provider, { value = initial },
      H.h(router.Provider, nil, H.h(r.Outlet)))
    return dom.render(c, require("views.Document"), {
      status = outcome.status or (outcome.ok and 200 or 422),
      state = {
        hydronium_greeting = initial,
        hydronium_router = {
          version = 1, canonical_url = "/", location = router.location(),
          route_id = "home", route_chain = { "root", "home" }, params = {}, resources = {},
        },
      },
      props = { app = d.lua.mount(page, { module = "views.Client" }) },
    })
  end,
})
]]

  files["src/views/Greeting.lua"] = [[-- A request-local seed shared by the native POST page and its browser mount.
return require("hydronium.core.context").createContext(nil)
]]

  files["src/views/Site.lua"] = [[-- The page manifest, shared by the browser router and the server routes.
-- App.luax is the layout around every page.
local r = require("hydronium_router")

return r.createSite({
  root = r.node({
    id = "root",
    path = "/",
    screen = "views.App",
    children = {
      r.node({
        id = "home",
        path = "",
        screen = "views.Home",
        actions = { hello = { id = "hello.submit", ref = "app.hello_action", path = "/actions/hello" } },
      }),
      r.node({ id = "about", path = "about", screen = "views.About" }),
    },
  }),
})
]]

  files["src/views/Actions.lua"] = [[-- The `hello` form action: one schema, checked in the browser before an
-- enhanced submit and again on the server (src/app/hello_action.lua).
local H = require("hydronium.core")

local hello = {
  ["~standard"] = {
    validate = function(values)
      local name = type(values.name) == "string" and values.name:match("^%s*(.-)%s*$") or ""
      if name == "" then
        return { issues = { { path = { { key = "name" } }, message = "Who should we say hello to?" } } }
      end
      local times = math.floor(tonumber(values.times) or 1)
      return { value = { name = name:sub(1, 40), times = math.max(1, math.min(9, times)) } }
    end,
  },
}

return {
  hello = H.action({ id = "hello.submit", path = "/actions/hello", method = "POST", schema = hello }),
}
]]

  files["src/views/Client.lua"] = [[-- Browser entry: builds the router from the shared site and mounts the
-- matched page tree. The visible app starts at src/views/App.luax.
local H = require("hydronium.core.element")
local r = require("hydronium_router")
local signals = require("hydronium.signals")
local d = require("hydronium_dom").d
local site = require("views.Site")
local Greeting = require("views.Greeting")
local codec = require("hydronium_router.history.state")

return function()
  local initial = type(_G.__hydronium_greeting_outcome) == "string"
    and codec.decode(_G.__hydronium_greeting_outcome) or nil
  local router = site:createRouter({
    history = r.createBrowserHistory(),
    resolve = require,
    resolve_loader = require,
  })
  return function()
    return d.lua.mount(H.h(Greeting.Provider, { value = initial },
      H.h(router.Provider, nil, H.h(r.Outlet))), { module = "views.Client" })
  end
end
]]

  files["src/main.lua"] = string.format([[-- Server entrypoint: an ordinary Meteorite app.
--
--   hydronium.mount(app)        framework routes (browser runtime, dev server, HMR)
--   router.mount(app, site)     one GET per page in src/views/Site.lua, plus its form actions
--
-- Handlers live in their own modules (`meteorite.lua("app.x")`): Meteorite's
-- hybrid build loads each one standalone, so they must not capture locals here.
local meteorite = require("meteorite")
local hydronium = require("hydronium_dom.server.meteorite")
local router = require("hydronium_router.meteorite")
require("hydronium_luax").loader.install()

local app = meteorite.app({
  name = "%s",
  host = "127.0.0.1",
  port = tonumber(os.getenv("PORT")) or 8080,
  -- A built server also honours PORT at start-up (Meteorite 0.3.4+).
  port_env = "PORT",
  -- Views are swapped in the browser, so editing one does not restart the server.
  dev_watch = hydronium.dev_watch(),
})

-- Before meteorite.site: routes match in declaration order.
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

app:get("/api/health", { summary = "Health check" }, function(c)
  return c:json({ status = "ok", timestamp = os.time() })
end)

router.validate_final(app, site)

return app
]], project_name)

  files["src/views/App.luax"] = string.format([[-- The layout around every page: header, the current page, footer. Edit it
-- with `moon run dev` running and the page updates in place.
local H = require("hydronium.core.element")
local r = require("hydronium_router")
local signals = require("hydronium.signals")
local d = require("hydronium_dom").d

local function App(props)
  local router = r.useRouter()
  local navigate = r.useNavigate()

  local function link(href, label)
    local current = signals.createComputed(function() return router.location().path == href and "page" or nil end)
    return (
      <d.a href={href} onNavigate={function() navigate(href) end}
        aria-current={current}>{label}</d.a>
    )
  end

  return (
    <d.div class="shell">
      <d.header class="top">
        <d.a class="brand" href="/" onNavigate={function() navigate("/") end}><d.span class="mark">H₃O⁺</d.span> %s</d.a>
        <d.nav>{link("/", "Home")}{link("/about", "About")}</d.nav>
      </d.header>
      <d.main class="stage">{props.outlet}</d.main>
      <d.footer class="foot">Edit <d.code>src/views/App.luax</d.code> to see the changes.</d.footer>
    </d.div>
  )
end

return App
]], project_name)

  -- `times` is an ordinary signal declared at the top of a setup function
  -- that takes `scope`, so the LUAX compiler keeps its value across hot edits.
  files["src/views/Home.luax"] = [[-- A progressive form: it posts like plain HTML before the page hydrates,
-- then validates and submits in the background from the browser Lua VM.
local H = require("hydronium.core.element")
local d = require("hydronium_dom").d
local signals = require("hydronium.signals")
local useForm = require("hydronium.core.form").useForm
local actions = require("views.Actions")

local function Home(props, scope)
  local initial = require("hydronium.core.context").useContext(require("views.Greeting")) or {}
  local values = initial.values or {}
  local times, setTimes = signals.createSignal(tonumber(values.times) or 3)
  local hello = useForm(actions.hello, { enhance = true, initial = initial })
  local fewerDisabled = signals.createComputed(function() return times() <= 1 end)
  local moreDisabled = signals.createComputed(function() return times() >= 9 end)
  local timesValue = signals.createComputed(function() return tostring(times()) end)
  local pending = signals.createComputed(function() return hello:pending() end)
  local resultClass = signals.createComputed(function() return hello:error("name") and "result error" or "result" end)

  return function()
    return (
      <d.form class="hello" method={hello.props.method} action={hello.props.action} onSubmit={hello.props.onSubmit}>
        <d.h1 class="line">Say hello to <d.input class="name" id="name" name="name" placeholder="Ada" autocomplete="off" aria-label="Name" value={values.name or ""} /> <d.span class="counter" role="group" aria-label="Times"><d.button type="button" aria-label="Fewer" disabled={fewerDisabled} onClick={function() setTimes(times() - 1) end}>−</d.button><d.output class="count">{times}</d.output><d.button type="button" aria-label="More" disabled={moreDisabled} onClick={function() setTimes(times() + 1) end}>+</d.button></d.span> times.</d.h1>
        <d.input type="hidden" name="times" value={timesValue} />
        <d.button class="send" type="submit" disabled={pending}>Say hello</d.button>
        <d.p class={resultClass} aria-live="polite">{function()
          local result = hello:data()
          return hello:error("name") or (result and result.greeting) or ""
        end}</d.p>
      </d.form>
    )
  end
end

return Home
]]

  files["src/views/About.luax"] = [[local H = require("hydronium.core.element")
local d = require("hydronium_dom").d

local function About()
  return (
    <d.section class="hello">
      <d.h1 class="line">About</d.h1>
      <d.p class="lede">Meteorite renders each page on the server; Hydronium keeps it running in your browser as Lua. Pages are declared in <d.code>src/views/Site.lua</d.code>, and the greeting is a form action in <d.code>src/views/Actions.lua</d.code>.</d.p>
    </d.section>
  )
end

return About
]]

  files["public/style.css"] = look.CSS
  files["public/ui/starter.js"] = look.SCRIPT

  files["README.md"] = string.format([[# %s

A [Hydronium](https://moonstone.sh/packages/hydronium) app served by
[Meteorite](https://moonstone.sh/packages/meteorite): pages render on the
server, then keep running in the browser as Lua.

```bash
moon sync
moon run dev
```

Open the printed URL and edit `src/views/App.luax`: the page updates in place
and the counter keeps its value.

`moon run dev` runs `hydronium dev`: a live log of requests and rebuilds (also
written to `.hydronium/dev.log`). Press `f` for the fullscreen request
inspector, `esc` to leave it, `q` to quit.

## Files

- `src/views/App.luax` -- the layout: header, page, footer.
- `src/views/Home.luax`, `src/views/About.luax` -- the pages.
- `src/views/Site.lua` -- the page manifest, used by the browser router and the
  server routes alike.
- `src/views/Actions.lua` + `src/app/hello_action.lua` -- the `hello` form
  action. The form posts as plain HTML before the page hydrates; afterwards it
  validates and submits in the background.
- `src/views/Document.luax` -- the HTML shell. Editing it reloads the page.
- `src/main.lua` -- the Meteorite server.
- `public/style.css` -- the styles.

A component's state survives an edit when it is an ordinary
`signals.createSignal(...)` declared at the top of a setup function that takes
`scope` (see `Home.luax`).

## Build

```bash
moon run build
./dist/server
```

`PORT=9000 ./dist/server` listens on another port.
]], project_name)

  return files
end

return ssr
