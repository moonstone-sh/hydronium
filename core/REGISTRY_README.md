# Hydronium

`hydronium` is the reactive UI core for Lua and LuaJIT applications.

```sh
moon add hydronium/core
```

It provides the `hydronium` Lua namespace. Install `hydronium/dom`
for DOM hosting and SSR, `hydronium/luax` for the `.luax` compiler,
or `hydronium/ink` for terminal rendering.

## Run a reactive value

In an empty directory, initialize the Lua runtime before adding the package:

```sh
moon init . --name demo --interpreter luajit@2.1
moon add hydronium/core
```

Save demo.lua:

```lua
local H = require("hydronium")
local count, setCount = H.createSignal(1)
local doubled = H.createComputed(function() return count() * 2 end)
print(doubled())
setCount(3)
print(doubled())
```

```sh
moon exec -- luajit demo.lua
```

Expected output: 2, then 6 on separate lines. No DOM or terminal host is needed
for signals and computed values. Add hydronium/dom to render HTML, or
hydronium/ink for an interactive terminal application.

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

The following component fragment additionally needs hydronium/dom and an
application route handling POST /profiles/:user.

```lua
local H = require("hydronium")
local d = require("hydronium_dom").d

local save_profile = H.action({
  id = "profile.save",
  path = "/profiles/:user",
  method = "POST",
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

The following embedding fragment expects initial_source and changed_source
to be Lua module source strings. Generated applications supply the transport.

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

## Development API: host capabilities (unreleased)

`require("hydronium.runtime.hosts")` exposes a VM-local registry for versioned
embedding bindings: `install`, `require`, `get` and `describe`. Installation
returns an idempotent release function; host owners dispose listeners and
observers before releasing their capability. This API is unreleased.
In a development build, save hosts.lua and run moon exec -- luajit hosts.lua:

```lua
local hosts = require("hydronium.runtime.hosts")
local _, release = hosts.install("demo", 1, {
  greet = function(name) return "Hello, " .. name end,
})
print(hosts.require("demo", 1).greet("Ada"))
release()
assert(hosts.get("demo", 1) == nil)
```

Expected output: Hello, Ada. The registry belongs to one Lua VM; installation
in another VM is separate. Dispose resources owned by a real host before
release. See [Host capabilities](https://github.com/moonstone-sh/hydronium/blob/feat/host-capabilities/docs/HOST_CAPABILITIES.md).

## Application configuration

`require("hydronium.config").require(fields, environment)` decodes explicit
string, boolean and integer environment fields at startup. Descriptors accept
`env`, `default`, `required`, integer `min`/`max`, `values`, and a Standard Schema
`schema` such as a Valua schema. Use `read` to receive all validation issues
instead of raising. Errors identify fields without echoing their values.

```lua
local config = require("hydronium.config").require({
  port = {env="PORT", kind="integer", default=3000, min=1, max=65535},
  development = {env="DEV", kind="boolean", default=false},
})
```

Authentication flow state is available separately in the optional `hydronium/auth` package.
