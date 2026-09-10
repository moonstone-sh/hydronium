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
