# Async data: choose the owner by lifetime

Hydronium has three deliberately separate async primitives. Do not turn one
into an alias for another: their ownership and cancellation boundaries differ.

| Need | Use | Owner |
| --- | --- | --- |
| A value that blocks or suspends one render subtree | `H.resource()` | that render dependency |
| Data for a URL transition or server render | `RouteResource` / route loader | router transition / request |
| Shared, stale client data reused by unrelated views | `hydronium/query` | one mounted browser app |
| A submit with validation and native fallback | `H.useForm()` | one form interaction |

`Resource` is not a fetch cache. A resource can be manually resolved, can
suspend a Suspense boundary, and has no query key, retry policy, or cross-view
invalidation. Use it for a local dependency such as a plugin-controlled async
operation. Create it in a component's setup phase, not its returned render
function, so the same dependency survives reactive rerenders:

```lua
local H = require("hydronium")

local function Preview(props)
  local preview = H.resource()
  props.plugin.render_preview(props.path, function(err, value)
    if err then preview:reject(err) else preview:resolve(value) end
  end)

  return function()
    return H.h(H.Suspense, { fallback = H.h("p", nil, "Rendering preview…") },
      H.h("pre", nil, preview:get())
    )
  end
end
```

`Resource.new(loader)` is also available for a synchronous/buffered SSR
loader. It runs once at the first `:get()`; it is not an asynchronous HTTP
shortcut in v1.

Route loaders remain the SSR owner. They run for a navigation, are cancelled
when that navigation becomes obsolete, and hydrate route data. Do not put a
global `QueryClient` on the server: it could retain user-specific request data.

`hydronium/query` is optional and browser-only in v1. Give each mounted app an
explicit client, then subscribe from a component's setup function. Do not call
`useQuery` from its returned render function: a render may run many times,
whereas one setup scope owns one observation and its cleanup.

```lua
local query = require("hydronium_query")
local client = query.createClient({ stale_time = 30, gc_time = 300 })

local function TodoList(props)
  local todos = client:useQuery({
    key = { "todos", props.project_id },
    query = function(ctx, done)
      -- Start an abortable request. Call done(error, value) once.
      return api.todos({ id = props.project_id, signal = ctx.signal }, done)
    end,
  })

  return function()
    local state = todos.state()
    if state.status == "pending" then return H.h("p", nil, "Loading todos…") end
    if state.status == "error" then return H.h("p", nil, tostring(todos.error())) end
    return TodoRows(todos.data())
  end
end
```

`useQuery` registers cleanup with that active Hydronium component scope. Keep
the client at the browser-app composition root (or provide it through a
context); never create a process-global client for SSR requests.

Keys are deterministic JSON-shaped values: dense arrays and string-keyed
objects only. This makes `invalidate({ "todos" })` safely cover every
`{ "todos", id }` query, while `invalidate({ "todos", id }, { exact = true })`
targets one entry. The first observer starts the request, later observers share
it, and dropping the final observer aborts it. Late callbacks are ignored by a
generation guard. Entries are removed lazily after `gc_time`.

For browser I/O, use the DOM adapter's `createBrowserRequest()`. It creates an
`AbortController` per request, defaults to same-origin credentials, forwards an
external signal, and returns `{ promise, abort, signal }`. Router and form
bridges accept this same factory:

```js
import { createBrowserRequest } from "/js/bootstrap/fetch.js";
import { createHttpGlobals } from "/js/router/http.js";
import { createFormGlobals } from "/js/bootstrap/forms.js";

const request = createBrowserRequest();
mount({ luaGlobals: {
  ...createHttpGlobals({ request }),
  ...createFormGlobals({ request }),
}});
```

HTTP failures are still responses. Router loaders map them to route errors;
forms map validation JSON to form state; query functions decide whether a
non-2xx response is cacheable data or an error. Network failures reject.

V1 intentionally excludes SSR query execution/dehydration, retries, polling,
persistence, and optimistic writes. Add those only after the explicit
per-request SSR boundary is designed.
