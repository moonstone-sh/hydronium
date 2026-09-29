# Hydronium Ballad

`hydronium/ballad` provides Ballad build plugins for Hydronium projects:
`.luax` compilation, CSS/style normalization and static-asset handling, and
client-side bundling/minification for the WASM (wasmoon) browser runtime. It
also packages Bun build operations for public routes marked `prerender = true`
in a Hydronium site tree.

```sh
moon add hydronium/ballad
```

It installs the `hydronium_ballad` Lua namespace, resolving `hydronium/core`,
`hydronium/luax`, and `hydronium/dom` automatically.

## Compile a component into a release directory

In an empty directory:

```sh
moon init . --name build-demo --interpreter luajit@2.1
moon add hydronium/ballad
moon add --tool moonstone/ballad
```

Save Card.luax:

```luax
local H = require("hydronium")
local d = require("hydronium_dom").d
return function(props)
  return <d.h1>{props.title}</d.h1>
end
```

Save partiture.lua:

```lua
local ballad = require("ballad")
local hb = require("hydronium_ballad")
return ballad.partiture(function(p)
  local luax = p:use(hb.plugins.luax)
  local sources = p.source.files({ "Card.luax" }, { root = "." })
  local compiled = luax.compile(sources, { target = "shared" })
  p.sink.directory(compiled, { out = "dist", file_graph = true })
end)
```

```sh
moon exec -- ballad play partiture.lua
```

Expected output tree:

```text
dist/
  Card.lua
  file-graph.json
```

Card.lua is compiled Lua; it still needs Hydronium/DOM at runtime. This build
compiles a module and does not create a standalone browser bundle or server.
The sink owns its output directory: use a separate build directory, not a
source directory. Rerun after editing Card.luax to regenerate it.

For a complete browser build, scaffold with hydronium/create and choose Bun:

```sh
moon add --tool hydronium/create
moon exec -- hydronium-create ./site-demo --template spa --package-manager bun
cd site-demo
moon sync
bun install
bun run build
moon run build
```

The generated SPA partiture bundles the reachable Lua application and merges
its Vite assets into dist. Use the scaffolded README for its serving command.

## Export an existing SSR site's static pages

The following is an integration recipe, not a fresh-project example: it assumes
an existing Meteorite app at src/main.lua, views.Site, and the listed public
assets. Install Pagefind with bun add --dev pagefind if enabling search. Save
the TypeScript coordinator below as build-static.ts and run bun build-static.ts.

For static HTML, mark literal, loader-free leaves in `views/Site.lua`:

```lua
local r = require("hydronium_router")
r.node({ id = "guide", path = "docs/guide", screen = "views.Guide", prerender = true })
```

Then import the installed build coordinator from a Bun build script:

```ts
import { buildStaticSite } from "./.moonstone/env/libexec/hydronium-ballad/hydronium_ballad/web/site-build";

await buildStaticSite({
  export: {
    appDir: ".",
    outputDir: "static-dist",
    siteModule: "views.Site",
    meteoriteInput: "src/main.lua",
    assets: ["public/style.css", "public/icon.svg"],
  },
  pagefind: { executable: "./node_modules/.bin/pagefind" },
  pwa: {
    scope: "/",
    workerUrl: "/service-worker.js",
    startUrl: "/",
    name: "My docs",
    shortName: "Docs",
    icons: [{ src: "/public/icon.svg", sizes: "any", type: "image/svg+xml" }],
    offline: "all_docs",
    assetDirectories: ["/pagefind"],
    assets: ["/public/style.css"],
    maxPrecacheBytes: 4 * 1024 * 1024,
  },
});
```

Pin Pagefind in the project's Bun lockfile and serve the generated worker and
manifest at the declared URLs. Register the worker only in release HTML, not
in a development page.

The exporter calls Meteorite's in-process route invocation through `moon exec`,
requires a 200 HTML response for each marked route, and writes `index.html`
under the matching path. It refuses to replace an existing output directory
without its own marker. It does not export parameterized routes or routes with
loaders. Supply `transformHtml(html, route)` if the static document needs a
different script or manifest; the exporter otherwise keeps the SSR HTML.

`buildStaticSite` runs export, Pagefind, then PWA generation. The worker hashes
the finished HTML and search assets, caches only declared static assets and
public documents, and leaves API fetches to the network. The lower-level
`exportStaticSite` and `buildPwa` functions are available from `web/static-export`
and `web/pwa` when a project needs to compose the steps itself. The package
does not install Pagefind or choose which routes contain safe public data.

See `docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md`,
`docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md`, and
`docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md` in the `hydronium` repo for
the full design.

## Development API: host provider inventory (unreleased)

Client resolution records literal host-capability references and declarative
provider/effect/cleanup contracts in the module graph and bundle metadata.
Dynamic or unresolved access conservatively retains providers. This inventory
is unreleased; capability elimination is disabled. See
[Host capabilities](../docs/HOST_CAPABILITIES.md) for the limits of the analysis.
