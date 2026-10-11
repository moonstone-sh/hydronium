# Hydronium Auth

An optional reactive authentication flow controller for Lua and LuaJIT. Inject your application's transport; the server remains responsible for authentication and authorization.

```sh
moon add hydronium/auth
```

```lua
local auth = require("hydronium_auth")
local flow = auth.createFlow({
  initial_step = "email",
  steps = {email=true, challenge=true, complete=true},
  transport = function(operation, payload, done)
    return request(operation, payload, done) -- application adapter; returns cancellation
  end,
})
flow:submit("send-code", {email="developer@example.com"})
-- Transport calls done(nil, {step="challenge"}) after sending a code.
-- Read flow.state() inside a reactive computation or UI component.
```

`request` is supplied by your application, not by this package. Use it to connect email codes, TOTP, WebAuthn or OAuth to your own endpoints.

`require("hydronium_auth").createFlow(options)` manages pending, error and
challenge steps around an injected transport. Read `flow.state()` reactively;
call `flow:submit(operation, payload)`, `flow:reset()` and `flow:dispose()`.
The transport receives `(operation, payload, done)` and may return a cancellation
function. Complete with `done(error, {step=..., data=..., message=...})`.
Optional `steps` restricts accepted server transitions; `validate` checks input
before transport. Reset, disposal and scope cleanup cancel pending work and
ignore stale replies. Duplicate submissions and duplicate callbacks are ignored.
Thrown transport exceptions become a generic retry message; explicit server errors remain visible.

The server must enforce authentication, challenge expiry, permissions and audit
logging. Keep tokens and challenge secrets out of long-lived UI state. Provider
adapters remain application-owned; this controller does not create sessions.

Source, tests and contributor instructions: see the repository README.
