# lua-language-server in the browser

The real `lua-language-server` (LuaLS), with Hydronium's LuaLS plugin and
types, running in a Web Worker: the same diagnostics, completion, hover and
signatures as VS Code and Neovim, for the site playground's Monaco editor.

## How

LuaLS is Lua. What it needs from its native host is small:

| Native piece | Here |
|---|---|
| Lua 5.5 (LuaLS 3.19 targets it) | PUC Lua 5.5.1 compiled to wasm |
| `lpeglabel` (its tokenizer and LuaCATS parser) | compiled into the same wasm |
| `bee.filesystem`, `bee.time`, `bee.platform`, ... | `shim.lua`: an in-memory filesystem and Lua stand-ins |
| worker threads (`bee.thread`, `pub`/`brave`) | `shim.lua`: worker tasks run in place, single-threaded |
| stdio JSON-RPC | `boot.lua`: `LUALS.receive(json)` / `LUALS.emit(json)` |
| the C++ code formatter | not built: formatting and the code-style check report nothing |

`luals_web.c` is the bridge: `luals_invoke(fn, bytes)` calls `LUALS[fn]`,
`__host_emit` hands LSP messages to JavaScript, `__host_now` is the clock.

Two details that are easy to get wrong:

- `bee.time.monotonic` must return whole milliseconds. LuaLS's timer keys
  callbacks by integer frame; a fractional clock makes it skip frames it has
  already ticked, and queued LSP methods never run.
- `bee.filesystem` paths must be userdata: `fs-utility` treats tables as its
  own in-memory "dummy" paths.

The host must not answer LuaLS's requests (e.g. `workspace/configuration`)
from inside the emit callback: queue its messages and handle them after the
call returns, or the Lua state is re-entered mid-call.

## Build

```sh
./build.sh      # downloads pinned, checksummed inputs; needs emcc and node
node test.mjs   # boots dist/ in Node: diagnostics, `<d.` completion, hover
```

Pinned: Lua 5.5.1, `lpeglabel` 912b0b9, `lua-language-server` 3.19.1 (its
Lua sources, en-us strings and stdlib template from the release archive).
`dist/` holds `luals.mjs`, `luals.wasm` (~110 KB brotli), `luals-bundle.bin`
(LuaLS + Hydronium's plugin and types, ~320 KB brotli) and `shim.lua`. A site
serves them and runs them from a worker; see `public/js/luals-worker.js` and
`src/client/luals-client.js` in moonstone.sh's `apps/hydronium`.
