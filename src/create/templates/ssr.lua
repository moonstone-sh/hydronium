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
  - Rendering goes through `require("hydronium.server.meteorite").render(c,
    AppView, {status=200, props={...}})` -- takes the COMPONENT (not a
    pre-built vnode) plus an options table with `props`; there is no
    `hydronium.render_to_string(...)` + `res:header()`/`res:send()` (that
    response API doesn't exist anywhere in this framework).
  - LUAX has no arrow-function syntax (`() => expr` fails to parse --
    verified directly against hydronium_luax.compile) -- every callback is
    `function() ... end`.
  - The SSR client-boundary guard (hydronium/src/hydronium/server/init.lua,
    around the `onClick`/callback-prop handling) only recognizes a prop
    name whose 3rd byte is an uppercase ASCII letter (`onClick`, `onInput`,
    ...) -- `onclick` (lowercase) does NOT match, so a Lua function value on
    it is silently dropped by `html.serialize_attributes` (never an error,
    never rendered) instead of doing anything. But the inverse is also
    real and load-bearing: `onClick` (correctly-cased) with a Lua closure
    OUTSIDE a client-execution boundary is a hard render-time error ("Lua
    callback `onClick` requires a Lua client execution boundary"), verified
    directly by rendering both shapes. There is no real Lua-island client
    hydration yet in this framework (SSR-only; see
    hydronium/examples/meteorite_ssr/src/main.lua's own route 6 comment),
    so the interactive counter below is wrapped in `<d.lua.island
    hydrate="visible">` -- this satisfies the guard for real (verified: the
    real `<!--hy:i:...:lua-->` marker appears in the rendered output) and
    is honest about what's real today: the button's markup and its onClick
    reference survive intact through SSR with no error and no silent drop,
    but nothing in this template makes it interactive in a browser yet --
    that requires either the JS-island path (see the `islands` template)
    or a Lua client runtime this framework doesn't ship. Don't let the
    reactive-looking `H.signal` call fool you into thinking clicking this
    button does anything live; it renders the *initial* value correctly on
    every request, same as any other prop.
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
name = "lua"
version = "5.4"
abi = "5.4"

[scripts]
dev = "meteorite dev"
build = "meteorite build"

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

  files["views/App.luax"] = string.format([[-- Root View Component
local H = require("hydronium")
local d = require("hydronium_dom").d

local function Counter(props)
  local count, setCount = H.signal(props.initial or 0)

  return (
    <div class="counter-box">
      <span class="count-display">Count: {count()}</span>
      <div class="button-group">
        <button onClick={function() setCount(count() - 1) end} class="btn btn-secondary">-</button>
        <button onClick={function() setCount(count() + 1) end} class="btn btn-primary">+</button>
      </div>
    </div>
  )
end

-- Wrapped in a real Lua client-execution boundary: SSR's guard
-- hard-errors on an `onClick` callback with no enclosing
-- <d.lua.island>/<d.lua.mount> -- this is not decorative, it's the only
-- way this page renders at all.
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
            <d.lua.island hydrate="visible">
              <Counter initial={props.initial_count or 0} />
            </d.lua.island>
          </section>

          <footer>
            <p>Powered by <strong>Hydronium</strong> &amp; <strong>Meteorite</strong></p>
          </footer>
        </main>
      </body>
    </html>
  )
end

return App
]], project_name, project_name)

  -- Compiles views/App.luax on demand and returns the component function.
  -- Lives in its own requirable module (not a main.lua upvalue) for
  -- exactly the reason explained in this file's header comment and in
  -- hydronium/examples/meteorite_ssr/src/views/App.lua, which this
  -- mirrors structurally: Meteorite's hybrid build lifts inline route
  -- handlers, so a handler cannot close over a `local App = require(...)`
  -- declared above it.
  files["src/views/App.lua"] = [[local luax = require("hydronium_luax")

local function load_luax(filepath)
  local f = assert(io.open(filepath, "r"), "Cannot open .luax file: " .. filepath)
  local source = f:read("*a")
  f:close()

  local compiled = luax.compile(source, {
    filename = filepath,
    runtime = "hydronium",
    development = false,
  })

  local load_fn = loadstring or load
  local chunk, err = load_fn(compiled.code, "@" .. filepath)
  if not chunk then
    error("Syntax error loading compiled .luax [" .. filepath .. "]: " .. tostring(err))
  end
  return chunk()
end

return load_luax("views/App.luax")
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
  },
})

app:get("/", function(c)
  local meteorite_adapter = require("hydronium.server.meteorite")
  local AppView = require("views.App")
  local initial_count = tonumber(c:query("count")) or 0
  return meteorite_adapter.render(c, AppView, {
    status = 200,
    props = { title = "%s", initial_count = initial_count },
  })
end)

app:get("/api/health", function(c)
  return c:json({ status = "ok", timestamp = os.time() })
end)

return app
]], project_name, project_name)

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

The interactive counter is wrapped in `<d.lua.island>` because Hydronium's
SSR safety guard requires a real Lua client-execution boundary around any
element with a Lua-function `onClick`/`onInput`/... prop -- without one, a
correctly-cased handler is a hard render error, and a *lowercase* `onclick`
would instead be silently dropped with no error at all. `<d.lua.island>`
satisfies the guard and proves the callback isn't dropped (look for the
`<!--hy:i:...:lua-->` marker in the page source), but there is no real Lua
client-runtime hydration in Hydronium yet, so clicking the button in a
browser does nothing today -- the counter always renders its initial value.
For real client-side interactivity right now, see the `islands` template's
JS-island pattern instead.

## Getting Started

1. **Install Dependencies:**
   ```bash
   moon sync
   ```

2. **Start Dev Server (with HMR):**
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
