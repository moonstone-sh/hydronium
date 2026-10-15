# Plain rendering and site integrations

For rendering that does not need Meteorite or Vite, import the renderer directly:

```lua
local h = require("hydronium.core.element").h
local renderer = require("hydronium_dom.server.renderer")
local html = renderer.render_to_string(h("h1", {}, "Hello"))
```

This entrypoint has no Meteorite adapter, build-mode global, filesystem manifest
loader, or Vite configuration dependency. It retains component rendering,
contexts, Suspense, client plans, islands, streaming, and page-wide island IDs.
Function sinks receive `chunk`; table sinks implement `sink:write(chunk)` and
optional `:flush()` / `:close()` methods.

JavaScript island module URLs pass through unchanged by default. An embedding
can resolve them for one render without mutating global configuration:

```lua
local html, plan = renderer.render_to_string(vnode, {
  module_resolver = function(specifier)
    return manifest[specifier] or specifier
  end,
})
```

The resolver applies only to string-valued JavaScript module specifiers. Lua
module IDs never reach it, and the next render gets no resolver unless it is
explicitly supplied again. Plain rendering never reads `manifest` itself.

## Existing site entrypoint

`require("hydronium_dom.server")` remains the site-facing entrypoint. It wires
JavaScript module resolution to the existing
`hydronium_dom.server.vite_module` configuration and retains the lazy
`.meteorite` convenience API. Direct imports of
`hydronium_dom.server.meteorite` also remain available. Existing callers do not
need to migrate unless they want the smaller renderer dependency closure.

The site entrypoint passes its resolver through render options, including
streaming and `render_page` callbacks. It does not reconfigure the plain
renderer or mutate a caller's options. Both entrypoints share the renderer's
existing synchronous, non-reentrant render/page state contract.

## Optimization status

The Quaver fixture compares the original page with emitted Strict artifacts on
Lua 5.4 and LuaJIT. Its plain-renderer imports load 23 framework modules:
154,346 original source bytes, 74,230 compacted, or 73,112 with independently
mangled JSON/style helpers, including the page.

Explicit SVG lookup declarations let Quaver main verify export stability without
assuming initializer loops are pure. The statically retained Strict closure has
25 modules including the page and verification entry: 56,269 bytes as mangled
module files, or 57,454 bytes as a standalone bundle. Both artifacts produce the
same HTML, SVG casing, escaping, styles, JSON behavior, and repeated renders.
No consumer export profiles are supplied; unused features inside retained
modules are not eliminated. These are fixture source/artifact totals, not browser
transfer or native-server sizes. Quaver 0.1.2 does not include the scanner and
class-proof changes needed for this result.
