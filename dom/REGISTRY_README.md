# Hydronium DOM

`moonstone/hydronium-dom` is Hydronium's HTML/SVG host. It provides immutable
DOM descriptors, HTML rendering, browser mounting code, and a Meteorite
adapter for server-rendered applications.

```sh
moon add moonstone/hydronium-dom
```

It installs the `hydronium_dom` Lua namespace and resolves
`moonstone/hydronium` automatically.

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

Require the adapter inside an inline route handler. Meteorite's compiled
hybrid mode reloads that handler independently, so it cannot capture a module
required at the file's top level.

```lua
app:get("/", function(c)
  local meteorite = require("hydronium_dom.server.meteorite")
  local App = require("views.App")

  return meteorite.render(c, App, {
    status = 200,
    props = { title = "Hello" },
  })
end)
```

`meteorite.render` accepts a component or vnode. It makes route params, query
data, headers, request state, and the Meteorite context available through
`meteorite.RequestContext`. For streaming responses, create a sink with
`meteorite.make_stream_sink()` and call `meteorite.render_stream()` from the
same inline handler.

## Browser mount and HMR

`mount()` starts one browser Lua VM and preloads the application modules it
needs. Keep the server-rendered document as a stable bootstrap boundary, then
mount the editable application beneath it:

```js
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
  hmr: true,
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

## LuaLS types

The package contains typed HTML and SVG descriptor catalogs. Add its `types`
directory alongside `hydronium-luax`'s types in `.luarc.json` for completion
on `d.button`, event objects, and DOM props:

```json
{
  "workspace": {
    "library": [
      ".moonstone/env/libexec/hydronium-luax/types",
      ".moonstone/env/libexec/hydronium-dom/types"
    ]
  }
}
```

Adding `ambient-types` as a third library directory makes bare DOM tags typed
too. That is deliberately separate: it is useful for a DOM-only project, but
it would otherwise leak hundreds of names into every LuaLS workspace. It does
not create runtime globals. `table` and `select` remain lexical-only as
`d.table` and `d.select`, preserving Lua's standard globals.
