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

  files["app.css"] = [[.card {
  max-width: 420px;
  margin: 3rem auto;
  padding: 2rem;
  border-radius: 12px;
  background: #1e293b;
  color: #f8fafc;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  text-align: center;
  box-shadow: 0 10px 25px rgba(0, 0, 0, 0.3);
}

.card h1 {
  color: #38bdf8;
}

.card button {
  margin-top: 1rem;
  padding: 0.6rem 1.5rem;
  font-size: 1rem;
  font-weight: bold;
  border-radius: 8px;
  border: none;
  cursor: pointer;
  background: #38bdf8;
  color: #0f172a;
}
]]

  if router == "hydronium" then
    files["app.lua"] = string.format([==[-- Real two-route hash-routed static SPA entry -- mirrors
-- hydronium/examples/spa_hash_demo/app.lua exactly (see this template's
-- own header comment for what differs and why: installed package paths,
-- no hb.plugins.assets).
--
-- Routes go through `hydronium_router.site` (R.node/R.createSite), NOT a
-- hand-assembled `routes = {...}` table -- see this file's own repo
-- ground truth (examples/spa_hash_demo/app.lua) for the exact failure
-- mode a hand-rolled table hits: the router matches correctly but
-- `Outlet` silently renders nothing, because a bare match result's
-- `.component` lives one level down (`.meta.component`) from where
-- `site:routes(resolve)`'s real chain entries put it.
local H = require("hydronium")
local dom = require("hydronium_dom")
local d = dom.d
local R = require("hydronium_router")
local hash_history = require("hydronium_router.history.hash")
local styles = require("hydronium_dom.css").sheet("app.css")

-- A plain <button>, not <a href> -- dom_bridge.js's set_listener documents
-- that wasmoon cannot safely marshal a browser Event as a Lua callback
-- argument, so onClick fires with none; a real <a href="#/..."> would need
-- to preventDefault() its own default navigation to avoid racing the
-- router's own history.push, which a plain button sidesteps entirely.
local function nav_button(id, label, navigate, to)
  return d.button({ id = id, onClick = function() navigate(to) end }, label)
end

local function RootLayout(props)
  return function(current_props)
    current_props = current_props or props
    return current_props.outlet
  end
end

local function HomeScreen()
  local navigate = R.use_navigate()
  return function()
    return d.div({ id = "home-screen", class = styles.card },
      d.h1({}, "%s"),
      d.p({ id = "home-marker" }, "This is the home route -- rendered entirely client-side, no server."),
      nav_button("go-about", "Go to About", navigate, "/about")
    )
  end
end

local function AboutScreen()
  local navigate = R.use_navigate()
  return function()
    return d.div({ id = "about-screen", class = styles.card },
      d.h1({}, "About"),
      d.p({ id = "about-marker" }, "This is the about route."),
      nav_button("go-home", "Go Home", navigate, "/")
    )
  end
end

local components = { Root = RootLayout, Home = HomeScreen, About = AboutScreen }

local site = R.createSite({
  root = R.node({
    id = "root",
    path = "/",
    screen = "Root",
    children = {
      { id = "home", path = "", screen = "Home" },
      { id = "about", path = "about", screen = "About" },
    },
  }),
})

return function(props)
  local router = site:create_router({
    history = hash_history.create_hash_history(),
    resolve = function(id) return components[id] end,
  })

  return function()
    return H.h(router.Provider, {}, H.h(R.Outlet, {}))
  end
end
]==], project_name)

  else -- router == "meteorite"
    files["app.lua"] = string.format([==[-- Single-screen client mount -- no hydronium_router in the bundle at
-- all, and no client-side navigation. Meteorite (src/main.lua) serves
-- this bundle's dist/ output and is where a future second page/route
-- would be added, by hand, server-side.
local H = require("hydronium")
local dom = require("hydronium_dom")
local d = dom.d
local styles = require("hydronium_dom.css").sheet("app.css")

local function Home()
  return function()
    return d.div({ id = "home-screen", class = styles.card },
      d.h1({}, "%s"),
      d.p({ id = "home-marker" }, "Rendered entirely client-side, served by Meteorite.")
    )
  end
end

return function(props)
  return function()
    return H.h(Home)
  end
end
]==], project_name)
  end

  files["partiture.lua"] = string.format([==[-- Real hydronium_ballad build: bundles app.lua (+ framework%s) into one
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
  local depends_on = { core_src, dom_src }
%s
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
%s      vendor = {
        { dir = pkg_root("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_DOM", ".moonstone/env/libexec/dom") .. "/hydronium_dom/client", url_prefix = "js/bootstrap" },
%s      },
    },
  })

  p.sink.directory(merged, { out = "dist", file_graph = true })
end)
]==],
    router == "hydronium" and " + the router" or "",
    router == "hydronium" and [[
  local router_src = p.source.files({ "**/*.lua" }, {
    root = pkg_root("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_ROUTER", ".moonstone/env/libexec/router"),
    metadata = { hydronium = { target = "shared" } },
  })
  depends_on[#depends_on + 1] = router_src
]] or "",
    project_name,
    router == "hydronium" and [[      lua_globals = { module = "/js/router/hash_history.js", import = "createHashHistoryGlobals" },
]] or "",
    router == "hydronium" and [[        { dir = pkg_root("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_ROUTER", ".moonstone/env/libexec/router") .. "/hydronium_router/client", url_prefix = "js/router" },
]] or "")

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
constraint = "^0.4.0"
role = "tool"

[[dependencies]]
name = "hydronium/ballad"
constraint = "^0.2.0"
role = "runtime"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.0"
role = "runtime"

[[dependencies]]
name = "hydronium/dom"
constraint = "^0.2.0"
role = "runtime"

[[dependencies]]
name = "hydronium/router"
constraint = "^0.2.0"
role = "runtime"
]=], project_name)

    files[".gitignore"] = [[.moonstone/
dist/
*.log
]]

    files["README.md"] = string.format([[# %s

Client-only Hydronium SPA: framework, router, and application compiled
into one Lua chunk by [hydronium/ballad](https://moonstone.sh/packages/hydronium)'s
real client bundler, hash-routed, with **no server at all**. Ground truth:
`hydronium/examples/spa_hash_demo` in the framework repo.

## Getting started

```bash
moon sync
moon run build
```

`moon run build` runs `ballad play partiture.lua`, which produces a
complete, static `dist/` directory:

```
dist/
  index.html
  client/runtime-<hash>.lua
  assets/app-<hash>.css
  hydronium-manifest.lua
  hydronium-manifest.json
```

`dist/` is deployable to any static file server -- there is no Meteorite
process, no server rewrite rules, and no SSR. During development, serve
it with anything, e.g.:

```bash
npx --yes serve dist
```

Client-side routing is `location.hash`-driven (`#/`, `#/about`) --
`hydronium_router`'s hash history adapter, joined into the same client
bundle. Editing `app.lua` and re-running `moon run build` is the whole
edit loop; there is no HMR for this template (a from-scratch static
bundle rebuild each time).
]], project_name)
  else
    files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "bin"
description = "Client-only Hydronium SPA (single screen, no client router) served by Meteorite"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
dev = "moon exec --dev -- hydronium dev --ballad --meteorite-args='--mode hybrid_dev --backend fast_http --lua-root .moonstone/env/libexec/luajit'"
build = "moon exec --dev -- ballad play partiture.lua && meteorite build --mode release-hybrid --backend fast_http"

[[dependencies]]
name = "moonstone/meteorite"
constraint = "^0.2.9"
role = "tool"

[[dependencies]]
name = "hydronium/cli"
constraint = "^0.3.0"
role = "tool"

[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.4.0"
role = "tool"

[[dependencies]]
name = "hydronium/ballad"
constraint = "^0.2.0"
role = "runtime"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.2.0"
role = "runtime"

[[dependencies]]
name = "hydronium/dom"
constraint = "^0.2.0"
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
const meteorite = @import(".moonstone/env/libexec/meteorite/meteorite/zig/build_api.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = meteorite.addService(b, .{
        .meteorite_root = ".moonstone/env/libexec/meteorite/meteorite",
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
  port = 8080,
})

meteorite.site(app, {
  root = ".",
  assets = {
    ["/assets/:path*"] = { dir = "dist/assets", param = "path" },
    ["/client/:path*"] = { dir = "dist/client", param = "path" },
    ["/js/bootstrap/:path*"] = { dir = "dist/js/bootstrap", param = "path" },
  },
})

app:get("/", meteorite.file("dist/index.html"))
app:get("/hydronium-manifest.lua", meteorite.file("dist/hydronium-manifest.lua"))

return app
]], project_name)

    files["README.md"] = string.format([[# %s

Client-only Hydronium SPA (single screen, no client-side router), built
with [hydronium/ballad](https://moonstone.sh/packages/hydronium)'s real
client bundler and served by a real Meteorite process instead of a bare
static file server -- "relying on Meteorite" means Meteorite decides what
gets served and is where a future server route or page would be added by
hand. Ground truth: `hydronium/examples/spa_hash_demo` in the framework
repo (this template omits its `hydronium_router` bundling on purpose --
see templates/spa.lua's own header comment).

## Getting Started

1. **Install Dependencies:**
   ```bash
   moon sync
   ```

2. **Start Dev Server:**
   ```bash
   moon run dev
   ```

   This runs `hydronium dev --ballad ...`: `ballad play partiture.lua` builds
   this project's static client bundle ONCE before `meteorite dev` starts
   (there is no watch/rebuild loop for the Ballad half -- re-run `moon run
   dev` after editing `app.lua`/`app.css`).

3. **Build for Production:**
   ```bash
   moon run build
   ./dist/server
   ```
]], project_name)
  end

  return files
end

return spa
