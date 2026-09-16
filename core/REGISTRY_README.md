# Hydronium

`hydronium` is the reactive UI core for Lua and LuaJIT applications.

```sh
moon add hydronium/core
```

It provides the `hydronium` Lua namespace. Install `hydronium/dom`
for DOM hosting and SSR, `hydronium/luax` for the `.luax` compiler,
or `hydronium/ink` for terminal rendering.

## Core API

| Area | API |
| --- | --- |
| Reactivity | `createSignal`, `createComputed`, `createEffect`, `batch`, `untrack` |
| Components | `h`, `Fragment`, `createScope`, `onCleanup`, `createContext`, `useContext`, `createRef` |
| Async rendering | `resource`, `Suspense`, `ErrorBoundary` |
| Actions and forms | `action`, `action_ok`, `action_fail`, `useForm`, `FormTransportContext` |
| Host integration | `Reconciler`, `setDefaultHost`, `mount`, `reconcile`, `unmount` |
| Live replacement | `hmr`, `family_loader` |

## Actions and forms

An action is an immutable description of a mutation. Its id, URL, method,
encoding, and optional [Standard Schema](https://standardschema.dev/) validator
can be shared by a form and a server adapter.

```lua
local H = require("hydronium")

local save_profile = H.action({
  id = "profile.save",
  path = "/profiles/:user",
  method = "POST",
  schema = profile_schema,
})

local function ProfileForm()
  local form = H.useForm(save_profile, { params = { user = "ada" } })

  return function()
    return d.form({
      method = form.props.method,
      action = form.props.action,
      onSubmit = form.props.onSubmit,
    },
      d.input({ name = "display_name" }),
      d.button({ type = "submit", disabled = form:pending() }, "Save"),
      d.p(nil, function() return form:error("display_name") or "" end)
    )
  end
end
```

Without a browser transport, the form remains an ordinary HTML POST. With
`createFormGlobals()` from `hydronium-dom`, `onSubmit` validates locally,
sends an encoded request, and updates `pending`, `status`, `errors`, `values`,
and `data` without replacing the page. Repeated fields remain arrays. File
controls require an explicit upload transport.

`useForm(action, opts)` accepts `params`, `initial`, `transport`, `enctype`,
and `enhance`. The returned form exposes `values`, `errors`, `error`,
`pending`, `status`, `data`, `is_valid`, `set_value`, `set_values`,
`set_errors`, `validate`, `submit`, and `reset`. A transport receives
`(request, done)` and may return a cancellation function. Use
`FormTransportContext` to provide one for a subtree.

Action handlers can return `action_ok({ status, data, redirect })` or
`action_fail({ status, values, errors, data })`. `action:path_for(params)`
fills and percent-encodes path parameters; `action:meteorite({ handler = ... })`
produces a canonical Meteorite route spec.

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
