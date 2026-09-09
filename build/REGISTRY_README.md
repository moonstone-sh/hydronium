# Hydronium Ballad

`hydronium-ballad` provides Ballad build plugins for Hydronium projects:
`.luax` compilation, CSS/style normalization and static-asset handling, and
client-side bundling/minification for the WASM (wasmoon) browser runtime.

```sh
moon add hydronium-ballad
```

It installs the `hydronium_ballad` Lua namespace, resolving `hydronium`,
`hydronium-luax`, and `hydronium-dom` automatically.

See `docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md`,
`docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md`, and
`docs/HYDRONIUM_CLIENT_BUNDLER_MINIFIER_PLAN.md` in the `hydronium` repo for
the full design.
