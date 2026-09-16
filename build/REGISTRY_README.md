# Hydronium Ballad

`hydronium/ballad` provides Ballad build plugins for Hydronium projects:
`.luax` compilation, CSS/style normalization and static-asset handling, and
client-side bundling/minification for the WASM (wasmoon) browser runtime. It
also packages Bun build operations for public routes marked `prerender = true`
in a Hydronium site tree.

```sh
moon add hydronium/ballad
```

It installs the `hydronium_ballad` Lua namespace, resolving `hydronium`,
`hydronium/luax`, and `hydronium/dom` automatically.

For static HTML, mark literal, loader-free leaves in `views/Site.lua`:

```lua
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
