# Hydronium Auth

Optional authentication UI orchestration, separate from reactive Core. The runtime module is `hydronium_auth`; the installable Moonstone package is `hydronium/auth`.

- `src/hydronium_auth/init.lua`: reactive flow state and transport lifecycle.
- `types/auth.d.lua`: LuaCATS public declarations.
- `tests/auth_flow_spec.lua`: cancellation, stale replies and transition tests.
- `partiture.lua`: source artifact and declarations.

Run the workspace suite with `moon exec -- luajit tests/runner.lua` from the repository root. Run `sh tests/test_application_artifacts.sh` to verify the exported package closure. Package from this directory using `moon run package` after `moon sync`.

The only runtime dependency is Core. Validators and transports are injected; provider credentials, cookies, sessions, step-up authorization and audit persistence belong to the server application. See [REGISTRY_README.md](REGISTRY_README.md) for consumer usage. Release this package through the workspace's coordinated package release.
