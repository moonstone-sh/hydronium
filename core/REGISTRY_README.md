# Hydronium

`hydronium` is the reactive UI core for Lua and LuaJIT applications.

```sh
moon add moonstone/hydronium
```

It provides the `hydronium` Lua namespace. Install `moonstone/hydronium-dom`
for DOM hosting and SSR, `moonstone/hydronium-luax` for the `.luax` compiler,
or `moonstone/hydronium-ink` for terminal rendering.

Live hosts can share `hydronium.core.hmr`:

```lua
local H = require("hydronium")
local loader = H.family_loader
local hmr = H.hmr

loader.enable() -- before the application's first require
hmr.install("app", initial_source)
local App = require("app")

-- Later, when a host-specific transport supplies changed source:
local result = hmr.replace("app", changed_source)
assert(result.failed == 0)
```

The core owns compilation, `package.preload` replacement, component-family
refresh, and rollback when the replacement module cannot load. Browsers,
terminal loops, and other hosts remain responsible for detecting edits and
delivering source.
