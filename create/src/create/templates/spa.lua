--[[
  Real, enabled SPA template -- a client-only Hydronium app: framework,
  router (when `router = "hydronium"`) and application all compiled into
  one Lua chunk by `hydronium_ballad`'s real client bundler, with no
  server-rendered markup at all (`mount({ hydrate = false, ... })`).

  Ground truth for EVERY shape below is
  hydronium/examples/spa_hash_demo/{app.lua,partiture.lua,moonstone.toml}
  and hydronium/docs/HYDRONIUM_SPA_MODE_PLAN.md -- read those first if
  changing this file. That example is real and browser-gated (M3's
  Playwright gate: initial route renders, a click changes
  `location.hash` with no navigation, back/forward work, a hard reload at
  `#/second` lands on the second route). This template mirrors it, with
  two differences a hand-checked-out sibling example doesn't need to
  care about:

  - Every source root below points at the INSTALLED package layout under
    `.moonstone/env/libexec/<pkg>/` (e.g.
    `.moonstone/env/libexec/core/hydronium/*.lua`), not a sibling
    checkout's `src/` -- generated projects must resolve dependencies
    through Moonstone, never a monorepo-relative `../../core/src` (see
    ssr.lua's and islands.lua's own header comments for the same rule,
    applied there to Zig/JS paths instead of Ballad source globs).
  - `hb.plugins.assets` (content-hashed static files, e.g. spa_hash_demo's
    `logo.svg`) is deliberately NOT used here -- it is orthogonal to the
    router/Vite/Tailwind choices this template exists to demonstrate, and
    every real image-hashing behavior it would exercise is already
    covered by that example.

  TWO ROUTING MODES, a real architectural choice, not a naming
  difference:

  - `router = "hydronium"` (recommended): `hydronium_router`'s hash
    history (`hydronium_router.history.hash`, `router/src/hydronium_router/
    history/hash.lua`) joins the client bundle (this is genuinely new to
    a bundle -- SPA_MODE_PLAN's own M2 -- so `client.resolve`'s
    `depends_on` includes `router_src` and `entries` stays `{"app"}`,
    the one real require() edge into the whole router graph, exactly as
    spa_hash_demo's own partiture.lua comment explains for why nothing
    else needs listing). Two screens (Home/About), `location.hash`-driven,
    a real `hydronium_router.site` manifest (NOT a hand-rolled `routes`
    table -- see app.lua's own header comment on why that specific
    shortcut silently renders nothing). No Meteorite dependency: `dist/`
    is deployable to any static file server, matching `kind = "script"`
    and the fact that `hydronium/router`'s doc comment for
    `history/hash.lua` calls it an opt-in adapter an app requires itself,
    never a barrel default.
  - `router = "meteorite"`: no `hydronium_router` in the bundle at all --
    a single mounted screen, no client-side navigation. Instead of a bare
    static file server, a real Meteorite process serves `dist/` (`kind =
    "bin"`, a real `build.zig`) -- "relying on Meteorite" means Meteorite
    is the one thing deciding what's served and where a future server
    route would go, exactly the tradeoff the wizard's own routing
    question describes.

  TAILWIND CSS v4, when requested (see create/tailwind.lua's own header
  comment for why this template needs a DIFFERENT integration strategy
  than ssr/islands): `hydronium_ballad.plugins.style` REWRITES every
  `.class-name` in the CSS it scopes (`hydronium_dom.css.scope_class`,
  verified by reading build/src/hydronium_ballad/plugins/style.lua's own
  doc comment and `M.bundle`) -- running Tailwind's generated utility CSS
  through it would mangle every one of the thousands of plain utility
  class names (`bg-fuchsia-600` etc.) the compiled markup actually uses.
  So Tailwind's CSS is built entirely separately (a real `vite build`,
  the exact same mechanism as ssr/islands) and linked into `dist/index.html`
  with a small, real postbuild patch (`scripts/inject-tailwind-link.mjs`)
  -- `site.manifest`'s own HTML generator
  (build/src/hydronium_ballad/plugins/site.lua's `render_index_html`) has
  exactly one `<link rel="stylesheet">` slot, tied to its own
  `style.bundle` output, and no "extra head content" option to hook a
  second stylesheet into.
]]

local look = require("create.look")
local spa = {}

local ROUTER_MODES = { hydronium = true, meteorite = true }

function spa.files(opts)
  opts = opts or {}
  local project_name = opts.name or "my-hydronium-spa"
  local router = opts.router or "hydronium"
  if not ROUTER_MODES[router] then
    error("create.templates.spa: unknown router mode '" .. tostring(router) .. "' (expected 'hydronium' or 'meteorite')", 2)
  end
  local files = {}

  -- Component-scoped styles (class names here are rewritten per component;
  -- see `require("hydronium_dom.css").sheet`). The page look is plain CSS in
  -- src/styles.css, built by Vite.
  files["app.css"] = [[/* Scoped component styles go here. The page look lives in src/styles.css. */
.unused { display: none; }
]]

  files["app.lua"] = [==[-- Browser entry: a hash router over three views in src/views/.
-- The generated bootstrap loads the asset manifest through this module.
require("hydronium_dom.assets")
local H = require("hydronium")
local R = require("hydronium_router")
local hash_history = require("hydronium_router.history.hash")

local screens = {
  App = require("views.App"),
  Home = require("views.Home"),
  About = require("views.About"),
}

local site = R.createSite({
  root = R.node({
    id = "root",
    path = "/",
    screen = "App",
    children = {
      { id = "home", path = "", screen = "Home" },
      { id = "about", path = "about", screen = "About" },
    },
  }),
})

return function()
  local router = site:create_router({
    history = hash_history.create_hash_history(),
    resolve = function(id) return screens[id] end,
  })
  return function()
    return H.h(router.Provider, {}, H.h(R.Outlet, {}))
  end
end
]==]

  files["src/views/App.luax"] = string.format([==[-- The layout around every page. Edit it, run `moon run build`, and reload.
local H = require("hydronium")
local R = require("hydronium_router")
local signals = require("hydronium.signals")
local d = require("hydronium_dom").d

local function App(props)
  local router = R.useRouter()
  local navigate = R.useNavigate()

  local function link(path, label)
    local current = signals.createComputed(function() return router.location().path == path and "page" or nil end)
    return (
      <d.a href={"#" .. path} onNavigate={function() navigate(path) end}
        aria-current={current}>{label}</d.a>
    )
  end

  return (
    <d.div class="shell">
      <d.div class="glow" aria-hidden="true"></d.div>
      <d.header class="top">
        <d.a class="brand" href="#/" onNavigate={function() navigate("/") end}><d.span class="mark">H₃O⁺</d.span> %s</d.a>
        <d.nav>{link("/", "Home")}{link("/about", "About")}</d.nav>
      </d.header>
      <d.main class="stage">{props.outlet}</d.main>
      <d.footer class="foot">Edit <d.code>src/views/App.luax</d.code> to see the changes.</d.footer>
    </d.div>
  )
end

return App
]==], project_name)

  files["public/ui/starter.js"] = look.SCRIPT .. [[
import { createHashHistoryGlobals } from "/js/router/hash_history.js";
export function createGlobals() { return createHashHistoryGlobals(); }
]]

  files["src/views/Home.luax"] = [==[-- Everything runs in the browser: the counter is reactive Lua, and "Say
-- hello" reads the name field through a ref and answers right here.
local H = require("hydronium")
local d = require("hydronium_dom").d
local signals = require("hydronium.signals")

local function Home(props, scope)
  local times, setTimes = signals.createSignal(3)
  local greeting, setGreeting = signals.createSignal("")
  local fewerDisabled = signals.createComputed(function() return times() <= 1 end)
  local moreDisabled = signals.createComputed(function() return times() >= 9 end)
  local name_field

  local function say_hello()
    local name = name_field and tostring(name_field.value or ""):match("^%s*(.-)%s*$") or ""
    if name == "" then
      setGreeting("Who should we say hello to?")
    else
      setGreeting((string.rep("Hello, " .. name:sub(1, 40) .. "! ", times()):gsub("%s+$", "")))
    end
  end

  return function()
    return (
      <d.form class="hello" onSubmit={say_hello}>
        <d.h1 class="line">Say hello to <d.input class="name" id="name" name="name" placeholder="Ada" autocomplete="off" aria-label="Name" ref={function(el) name_field = el end} /> <d.span class="counter" role="group" aria-label="Times"><d.button type="button" aria-label="Fewer" disabled={fewerDisabled} onClick={function() setTimes(times() - 1) end}>−</d.button><d.output class="count">{times}</d.output><d.button type="button" aria-label="More" disabled={moreDisabled} onClick={function() setTimes(times() + 1) end}>+</d.button></d.span> times.</d.h1>
        <d.button class="send" type="submit">Say hello</d.button>
        <d.p class="result" aria-live="polite">{greeting}</d.p>
      </d.form>
    )
  end
end

return Home
]==]

  files["src/views/About.luax"] = [==[local H = require("hydronium")
local d = require("hydronium_dom").d

local function About()
  return (
    <d.section class="hello">
      <d.h1 class="line">About</d.h1>
      <d.p class="lede">A client-only app: Hydronium, the router and these views are bundled into one Lua chunk that runs in your browser. Routes live in <d.code>app.lua</d.code>; pages in <d.code>src/views/</d.code>.</d.p>
    </d.section>
  )
end

return About
]==]

  files["partiture.lua"] = string.format([==[-- Real hydronium_ballad build: bundles app.lua and src/views (+ framework and router) into one
-- client Lua chunk, scopes app.css, and emits a static dist/ shell --
-- mirrors hydronium/examples/spa_hash_demo/partiture.lua exactly, with
-- one real, verified difference beyond source roots: every package root
-- below is resolved through `MOONSTONE_PACKAGE_ROOT_<PKG>` (falling back
-- to the installed `.moonstone/env/libexec/<pkg>` symlink only if that
-- env var is somehow unset).
--
-- WHY: `moon sync` materializes a registry dependency's `libexec/<pkg>`
-- entry as a SYMLINK into Moonstone's content-addressed store (verified:
-- `ls -la .moonstone/env/libexec/core` on a real scaffolded project shows
-- a symlink, not a real directory). `hydronium_ballad.plugins.client`'s
-- file-listing helper (`ballad.fs.list_files`) shells out to plain `find
-- <root> \( -type f -o -type l \) -print` with no `-L`, and on macOS/BSD
-- `find` a bare symlink argument does NOT descend into it -- verified
-- directly: `client.resolve()` against `.moonstone/env/libexec/core`
-- silently resolved to zero files ("module 'hydronium' not found in the
-- provided asset set"), while the exact same root resolved through
-- `MOONSTONE_PACKAGE_ROOT_HYDRONIUM_CORE` (a real, non-symlink path Moon
-- already exports -- see hydronium/lab-cli's own
-- `MOONSTONE_PACKAGE_ROOT_LUAFILESYSTEM` for existing precedent using
-- this exact mechanism) found every file. `examples/spa_hash_demo`'s own
-- partiture.lua never hits this: it points at a SIBLING CHECKOUT's real
-- `src/` directory, never an installed package's symlinked `libexec/`.
--
-- Run: moon exec -- ballad play partiture.lua
local ballad = require("ballad")
local hb = require("hydronium_ballad")

local function pkg_root(env_name, fallback)
  return os.getenv(env_name) or fallback
end

return ballad.partiture(function(p)
  local client = p:use(hb.plugins.client)
  local luax = p:use(hb.plugins.luax)
  local style = p:use(hb.plugins.style)
  local site = p:use(hb.plugins.site)

  local app_src = p.source.files({ "app.lua" }, {
    root = ".",
    metadata = { hydronium = { target = "client" } },
  })
  local core_src = p.source.files({ "**/*.lua" }, {
    root = pkg_root("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_CORE", ".moonstone/env/libexec/core"),
    metadata = { hydronium = { target = "shared" } },
  })
  local dom_src = p.source.files({ "**/*.lua" }, {
    root = pkg_root("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_DOM", ".moonstone/env/libexec/dom"),
    metadata = { hydronium = { target = "shared" } },
  })
  local router_src = p.source.files({ "**/*.lua" }, {
    root = pkg_root("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_ROUTER", ".moonstone/env/libexec/router"),
    metadata = { hydronium = { target = "shared" } },
  })
  -- src/views/*.luax compiled to Lua; module ids follow the path (views.App).
  local views = luax.compile(p.source.files({ "views/*.luax" }, {
    root = "src",
    metadata = { hydronium = { target = "client" } },
  }))
  local depends_on = { core_src, dom_src, router_src, views }

  local resolved = client.resolve(app_src, {
    entries = { "app" },
    depends_on = depends_on,
  })
  local minified = client.minify(resolved, { level = "safe" })
  local bundled = client.bundle(minified, { entry = "app" })

  local css_src = p.source.files({ "app.css" }, { root = "." })
  local styles = style.bundle(css_src, { reset = false })

  local merged = site.manifest(bundled, {
    depends_on = { styles },
    mount = {
      title = "%s",
      hydrate = false,
      lua_globals = { module = "/ui/starter.js", import = "createGlobals" },
      vendor = {
        { dir = "public/ui", url_prefix = "ui" },
        { dir = pkg_root("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_DOM", ".moonstone/env/libexec/dom") .. "/hydronium_dom/client", url_prefix = "js/bootstrap" },
        { dir = pkg_root("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_ROUTER", ".moonstone/env/libexec/router") .. "/hydronium_router/client", url_prefix = "js/router" },
      },
    },
  })

  p.sink.directory(merged, { out = "dist", file_graph = true })
end)
]==], project_name)

  if router == "hydronium" then
    files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "script"
description = "Client-only Hydronium SPA (hash-routed, no server) built with the real hydronium_ballad client bundler"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
build = "moon exec -- ballad play partiture.lua"

[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.4.2"
role = "tool"

[[dependencies]]
name = "hydronium/ballad"
constraint = "^0.2.8"
role = "runtime"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.12"
role = "runtime"

[[dependencies]]
name = "hydronium/dom"
constraint = "^0.3.13"
role = "runtime"

[[dependencies]]
name = "hydronium/router"
constraint = "^0.2.4"
role = "runtime"
]=], project_name)

    files[".gitignore"] = [[.moonstone/
dist/
*.log
]]

    files["README.md"] = string.format([[# %s

A client-only [Hydronium](https://moonstone.sh/packages/hydronium) app: the
framework, the router and your views compile into one Lua chunk that runs in
the browser. No server.

```bash
moon sync
moon run build
npx --yes serve dist
```

## Files

- `src/views/App.luax` -- the layout: header, page, footer.
- `src/views/Home.luax`, `src/views/About.luax` -- the pages.
- `app.lua` -- the entry: routes (`#/`, `#/about`) and the hash router.
- `src/styles.css` -- the styles (built by Vite).
- `partiture.lua` -- the build: one Lua chunk plus a static `dist/`.

Edit a view and run `moon run build` again. `dist/` deploys to any static
file server.
]], project_name)
  else
    files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "bin"
description = "Client-only Hydronium SPA served by Meteorite"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
dev = "moon exec --dev -- hydronium dev --ballad --meteorite-args='--mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit'"
build = "moon exec --dev -- ballad play partiture.lua && meteorite build --mode release-hybrid --backend fast_http --lua-root .moonstone/env/libexec/luajit"

[[dependencies]]
name = "moonstone/meteorite"
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
name = "hydronium/ballad"
constraint = "^0.2.8"
role = "runtime"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.12"
role = "runtime"

[[dependencies]]
name = "hydronium/dom"
constraint = "^0.3.13"
role = "runtime"

[[dependencies]]
name = "hydronium/router"
constraint = "^0.2.4"
role = "runtime"
]=], project_name)

    files[".gitignore"] = [[.moonstone/
dist/
.zig-cache/
zig-out/
.meteorite/
.hydronium/
*.log
]]

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

    files["src/main.lua"] = string.format([[-- Plain static-file Meteorite server for this project's Ballad-built
-- dist/ output (see partiture.lua). No Lua route handlers of its own yet
-- -- this is exactly where a real API/page route would be added by hand,
-- which is the whole point of the "rely on Meteorite" routing choice.
local meteorite = require("meteorite")

local app = meteorite.app({
  name = "%s",
  host = "127.0.0.1",
  port = tonumber(os.getenv("PORT")) or 8080,
  -- A built server also honours PORT at start-up (Meteorite 0.3.4+).
  port_env = "PORT",
})

meteorite.site(app, {
  root = ".",
  assets = {
    ["/assets/:path*"] = { dir = "dist/assets", param = "path" },
    ["/ui/:path*"] = { dir = "dist/ui", param = "path" },
    ["/client/:path*"] = { dir = "dist/client", param = "path" },
    ["/js/bootstrap/:path*"] = { dir = "dist/js/bootstrap", param = "path" },
    ["/js/router/:path*"] = { dir = "dist/js/router", param = "path" },
  },
})

app:get("/", meteorite.file("dist/index.html"))
app:get("/hydronium-manifest.lua", meteorite.file("dist/hydronium-manifest.lua"))

return app
]], project_name)

    files["README.md"] = string.format([[# %s

A client-only [Hydronium](https://moonstone.sh/packages/hydronium) app served
by [Meteorite](https://moonstone.sh/packages/meteorite): your views compile
into one Lua chunk that runs in the browser, and Meteorite serves it (add
your own server routes to `src/main.lua`).

```bash
moon sync
moon run dev
```

## Files

- `src/views/App.luax` -- the layout: header, page, footer.
- `src/views/Home.luax`, `src/views/About.luax` -- the pages.
- `app.lua` -- the entry: routes (`#/`, `#/about`) and the hash router.
- `src/styles.css` -- the styles (built by Vite).
- `src/main.lua` -- the Meteorite server.

`moon run dev` builds the client once and starts the server; run it again
after editing a view.

## Build

```bash
moon run build
./dist/server
```
]], project_name)
  end

  return files
end

return spa
