# hydronium/query

Share server-state results between components in one mounted client app. This
optional cache is distinct from local resources and navigation-owned route
loaders. Create one client per app; do not share a process-global SSR cache.

## Install and observe a result

In an empty directory:

```sh
moon init . --name demo --interpreter luajit@2.1
moon add hydronium/query
```

Save demo.lua:

```lua
local query = require("hydronium_query")
local client = query.createClient({ stale_time = 60 })
local options = {
  key = { "greeting", "Ada" },
  query = function(ctx, done)
    done(nil, "Hello, " .. ctx.key[2])
  end,
}
local unsubscribe = client:observe(options, function(state)
  if state.status == "success" then print(state.data) end
end)
unsubscribe()
```

```sh
moon exec -- luajit demo.lua
```

Expected output: Hello, Ada. The example uses a synchronous callback so no
network service is required. Query callbacks use done(error, data); this is a
different argument order from router loader callbacks. For real fetches,
return a cancellation function and respect ctx.signal.aborted().

## Use the same cache in a component

In the mounted app, keep client outside the component so sibling observers
share it. Call client:useQuery(options) in component setup, then read data(),
error() or state() in the returned render function. Scope cleanup unsubscribes
and may abort an unobserved request. Do not call useQuery during render.

Invalidate a key with client:invalidate(key) after a mutation, or call the
observer's refetch() when the user requests a refresh. Keys are JSON-shaped
values; functions, cyclic tables and sparse arrays are not valid keys.

See [async ownership](https://github.com/moonstone-sh/hydronium/blob/main/docs/ASYNC_DATA.md)
for choosing a resource, route loader or client cache.
