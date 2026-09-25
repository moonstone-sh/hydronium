# Hydronium Ink Lab

Ink Lab combines `hydronium/lab` stories with Ink's in-memory session and a
Hydronium DOM browser shell. Native LuaJIT produces canonical styled cell
frames (`hydronium_ink_lab.snapshot`); `hydronium_ink_lab.frame` compresses
that into style-interned, run-length wire frames -- a self-contained "full"
frame for `open`/`resize`/`color`/`colorProfile`/`snapshot`, and a "delta"
frame (only the cells that changed) for everything else. `client/
virtual_terminal.js` applies those to an in-memory grid model, paints only
the cells that changed, and forwards browser interaction through an injected
request function.

The Lua implementation lives under `src/hydronium_ink_lab`. Focused coverage:

```sh
moon exec -- luajit tests/runner.lua tests/host/ink_session_spec.lua tests/host/ink_lab_spec.lua tests/host/ink_lab_frame_spec.lua
node --test tests/client/ink_lab.test.mjs
```

See [`../docs/HYDRONIUM_INK_LAB.md`](../docs/HYDRONIUM_INK_LAB.md) for the
architecture and protocol. Build the registry artifact with `moon run package`.
