# Hydronium DOM

`hydronium/dom` is Hydronium's HTML/SVG host. It provides immutable
DOM descriptors, HTML rendering, browser mounting code, and a Meteorite
adapter for server-rendered applications.

```sh
moon add hydronium/dom
```

It installs the `hydronium_dom` Lua namespace and resolves
`hydronium/core` automatically.

## Render HTML now

In an empty directory:

```sh
moon init . --name demo --interpreter luajit@2.1
moon add hydronium/dom
```

Save demo.lua:

```lua
local H = require("hydronium")
local d = require("hydronium_dom").d
local server = require("hydronium_dom.server")
local function Greeting(props)
  return d.h1(nil, "Hello, " .. props.name)
end
print((server.renderToString(H.h(Greeting, { name = "Ada" }))))
```

```sh
moon exec -- luajit demo.lua
```

Expected output: <h1>Hello, Ada</h1>. This is server-side rendering only; it does
not launch a browser or attach event handlers.

## Create a hydrated app with Bun

Install the generator in a separate tooling project or your current one:

```sh
moon add --tool hydronium/create
moon exec -- hydronium-create ./web-demo --template ssr --package-manager bun --tailwind
cd web-demo
moon sync
bun install
bun run dev
```

Open the URL printed by the dev command (normally http://localhost:8080/).
The counter is interactive after hydration. Edit views/Counter.luax to test
component HMR; edit styles to test CSS updates. The generated document is a
reload boundary. Run bun run build to build the application's release output.
This path requires Bun plus Meteorite's native build prerequisites.

## Build a DOM tree

`require("hydronium_dom")` exposes `d`, whose descriptors are callable in
ordinary Lua and work as lexical LUAX tags.

```lua
local h = require("hydronium")
local d = require("hydronium_dom").d

local function Greeting(props)
  return d.main({ class = "page" },
    d.h1(nil, "Hello, " .. props.name),
    d.p(nil, "This tree can render on the server or mount in a browser.")
  )
end

local page = h.h(Greeting, { name = "Ada" })
```

In LUAX, prefer the lexical form when a file has an explicit DOM alias:

```luax
local d = require("hydronium_dom").d

return <d.main class="page"><d.h1>Hello</d.h1></d.main>
```

The repository's [Meteorite example](../examples/meteorite_ssr/) uses bare
HTML/SVG tags for a full server-rendered page, then renders it from an inline
Meteorite route with `hydronium_dom.server.meteorite`.

## Meteorite SSR

Meteorite owns HTTP; Hydronium renders. Any Meteorite route can return a
server-rendered component. Put the handler in its own module and reference it
with `meteorite.lua(...)`: Meteorite's compiled hybrid mode loads each handler
standalone, so a handler must not capture locals from `main.lua`.

```lua
-- src/main.lua
app:get("/hello/:name", { summary = "Greeting" },
  meteorite.lua("app.hello", { arg_mode = "lazy_context" }))
```

```lua
-- src/app/hello.lua
require("hydronium_luax").loader.install() -- lets require() find .luax
local dom = require("hydronium_dom.server.meteorite")
local Greeting = require("features.greeting.Greeting")

return function(c)
  return dom.render(c, Greeting, { props = { name = c:param("name") } })
end
```

An inline handler works too, as long as it does its own `require` calls inside
the function body.

`render` accepts a component or vnode. It makes route params, query data,
headers, request state, and the Meteorite context available through
`RequestContext`. For streaming responses, create a sink with
`make_stream_sink()` and call `render_stream()` from the same handler.

### Framework routes: `mount` and `dev_watch`

A browser Lua VM needs a few framework routes: the client runtime, framework
source, the framework module manifest, the dev module server and the HMR
stream. Declare them with one call instead of writing them into your app:

```lua
local meteorite = require("meteorite")
local hydronium = require("hydronium_dom.server.meteorite")

local app = meteorite.app({
  name = "my-app",
  port = 8080,
  dev_watch = hydronium.dev_watch(), -- hot UI modules never restart the server
})
hydronium.mount(app) -- before meteorite.site: routes match in declaration order
```

| Route | Purpose |
| --- | --- |
| `GET /js/bootstrap/:path*`, `/js/bootstrap/vendor/:path*` | `mount.js`, `hmr.js`, vendored wasmoon |
| `GET /js/router/{history,http}.js` | Router browser bridges, when `hydronium/router` is installed |
| `GET /hydronium-src/:path*` | Framework Lua for the browser VM (allowlisted namespaces only) |
| `GET /__hydronium/client_manifest.json` | Framework modules, derived from your client modules' real `require` graph |
| `GET /__hydronium/dev/manifest.json` | Your client modules, their update policies, and whether HMR is on |
| `GET /__hydronium/dev/module/:id` | One declared module, `.luax` compiled on demand |
| `GET /__hydronium/watch` | HMR change stream (SSE); development builds only |
| `GET <href>` per watched stylesheet | The file from disk; development builds only |
| `GET /__hydronium/client/:path*` | The Ballad production bundle (immutable); release builds, when one was built |

In a Meteorite release build (`release-hybrid`, `release-static`), `mount`
leaves out the HMR stream and the from-disk stylesheet routes, and the module
manifest reports `hmr: false`. The page should skip `installHmr` then:
`if (manifest.hmr !== false) installHmr(...)`.

If a release build ran `hydronium_ballad.client_bundle(p)` first (the `ssr`
template's `build.partiture.lua`), the manifest also lists `chunks`: one
content-hashed chunk holding every declared client/shared module plus the
framework modules they reach. Boot with `mount({ chunkUrls: manifest.chunks,
appModuleId: manifest.entry, ... })` to load the app in one request. Without a
bundle, release pages load modules one by one.

Options: `hmr = true|false` overrides that build-mode default, `dev = false`
omits the module manifest, module and HMR routes, `router = false` omits the
router bridges, `client_manifest = "file.json"` serves a fixed manifest instead
and `false` omits it. Every route has a stable id and summary. The Lua routes
are `m.lua` file handlers inside this package, so Meteorite's handler lifting
has nothing to reject.

Sources come from the first file that exists:

1. `.hydronium/ballad/source-inventory.lua`, written by Ballad. Add a
   `partiture.lua` that calls `require("hydronium_ballad").source_inventory(p)`,
   and run `hydronium dev --watch-sources`, which re-runs it when files are added
   or removed.
2. `.hydronium/sources.lua`, written by the Vite discovery script in apps
   generated before Ballad owned discovery.
3. `hydronium.sources.lua` with an explicit `files` list.

A top-level `watch` list in `hydronium.sources.lua` adds non-module files to
the HMR stream. A plain path is only reported. A `{ path, href }` entry is a
stylesheet the browser swaps in place; in development `mount` serves it from
disk at `href` and `dev_watch()` keeps it from restarting the server:

```lua
watch = { { path = "public/style.css", href = "/public/style.css" } },
```

## Browser mount and HMR

The following snippets are embedding configuration fragments. They assume
that your server exposes the listed source, manifest and bootstrap URLs. Use
the generated app above for a complete asset and transport setup.

`mount()` starts one browser Lua VM and preloads the application modules it
needs. Keep the server-rendered document as a stable bootstrap boundary, then
mount the editable application beneath it:

```js
import { mount } from "/js/bootstrap/mount.js";
import { createBrowserRequest } from "/js/bootstrap/fetch.js";
import { createFormGlobals } from "/js/bootstrap/forms.js";
import { createHistoryGlobals } from "/js/router/history.js";

const request = createBrowserRequest();
const { lua } = await mount({
  hydroniumBaseUrl: "/hydronium-src",
  manifestUrl: "/__hydronium/client_manifest.json",
  appModuleId: "views.App",
  appModuleUrl: "/__hydronium/dev/module/views.App",
  moduleUrls: {
    "views.Counter": "/__hydronium/dev/module/views.Counter",
  },
  container: "#app",
  props: { initial: 0 },
  hydrate: true,
  hmr: true,
  luaGlobals: {
    ...createHistoryGlobals(),
    ...createFormGlobals({ request }),
  },
});
```

`moduleUrls` maps additional application module IDs to their source URLs;
framework modules still come from `manifestUrl`. When HMR is enabled before
the application is required, `installHmr()` can refresh those component
families inside the surviving VM:

```js
installHmr({
  lua,
  updates: {
    "views/App.luax": { action: "hot", module: "views.App" },
    "views/Counter.luax": { action: "hot", module: "views.Counter" },
    "views/Document.luax": { action: "reload" },
    "public/style.css": { action: "style", href: "/public/style.css" },
    "generated/report.json": { action: "ignore" },
  },
});
```

The update policy is exhaustive by design. `hot` swaps a Lua component
module, `style` replaces a linked stylesheet without navigation, `reload`
marks a document or bootstrap boundary, and `ignore` acknowledges a watched
file with no browser effect. An unlisted path is reported as `unhandled` and
does not discard application state. A failed requested hot swap reloads as a
safety fallback because the displayed tree can no longer be proven current.

`createFormGlobals()` supplies progressive action transport. The DOM host
captures form values during the native submit event, before the browser clears
`currentTarget`, and passes a Lua-safe snapshot to `useForm`. Native POST still
works when JavaScript or the browser Lua VM is unavailable.

## LuaLS types

The package contains typed HTML and SVG descriptor catalogs. Add its `types`
directory alongside `hydronium-luax`'s types in `.luarc.json` for completion
on `d.button`, event objects, and DOM props:

```json
{
  "workspace": {
    "library": [
      ".moonstone/env/libexec/luax/types",
      ".moonstone/env/libexec/dom/types"
    ]
  }
}
```

Adding `ambient-types` as a third library directory makes bare DOM tags typed
too. That is deliberately separate: it is useful for a DOM-only project, but
it would otherwise leak hundreds of names into every LuaLS workspace. It does
not create runtime globals. `table` and `select` remain lexical-only as
`d.table` and `d.select`, preserving Lua's standard globals.

## Development API: embedding contract (unreleased)

Browser bootstrap installs `dom@1` in `hydronium.runtime.hosts` before
loading the application. Custom embeddings may install the same capability or
provide `createDomHost(bridge)` explicitly. Legacy `__dom_*` globals remain
supported when the capability is absent. The declarative DOM contract records
methods, effects and cleanup for build tools. This capability API is unreleased;
see [Host capabilities](../docs/HOST_CAPABILITIES.md).

### Importing styles from Lua

Declare global styles in the document and component styles beside their owner:

```lua
local H = require("hydronium")
local d = require("hydronium_dom").d
local css = require("hydronium_dom.css")
local styles = css.import("src/components/Card.module.css")

return function(props)
  return H.h(H.Fragment, nil,
    styles:subscribe(),
    d.section({class = styles.classes.card}, props.children))
end
```

`subscribe()` returns stylesheet nodes for the renderer to mount and remove;
it does not mutate the DOM at module import time. Use `styles.classes` for real
CSS Modules exports, including composed classes. Existing `css.sheet(path)`
continues to serve Ballad's deterministic scoped-style pipeline; its computed
names are a separate contract from Vite CSS Modules.

Enable `luaStyles()` from `@hydronium-js/vite`. It discovers literal
`css.import("project/path.css")` declarations under `src` and `stories` and
adds those styles as build inputs. Use `entries` for dynamic declarations or a
different local alias. The current adapter uses Vite's default PostCSS
transformer. Production class exports travel in Vite's manifest and survive
Ballad's `vite_assets` → `site.manifest` conversion. Browser mounts can load
that Lua manifest through their existing `assetManifestUrl` option.

In development configure the `vite-dev` asset provider with
`modules_path = ".hydronium/css-modules.json"`; the plugin creates this map
before the server becomes ready. Global CSS uses Vite's normal HMR. CSS Modules
edits refresh the class map and reload the page, so mounted DOM cannot retain
stale class names or composition. Preserving Lua state across those map changes
will need a browser renderer integration.

CSS Modules use content-independent scoped names by default. Declaration edits
use Vite CSS HMR and preserve component state and focus. Changes to composition
or exported class names trigger a full reload so Lua never renders an obsolete
class mapping. A custom `generateScopedName` is respected; if it changes exports
on a style edit, that edit also requires a reload.
