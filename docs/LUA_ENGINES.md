# Browser Lua engines

Hydronium runs your Lua in the browser on a WebAssembly build of PUC Lua.
There are two engine providers:

| | lua-wasm (default) | Wasmoon (fallback) |
|---|---|---|
| Lua | PUC Lua 5.4.9, built by Moonstone (`moonstone/lua-wasm`), Bridge API 2 | PUC Lua 5.4 via Wasmoon |
| Shipped as | `vendor/lua-wasm/5.4.9/` in `@hydronium-js/dom-client` and `hydronium/dom` | `vendor/wasmoon/` |
| Host calls | synchronous; a promise suspends only the calling Lua task | through Wasmoon's JS proxies |

To pin the fallback for one mount:

```js
import { mount } from "@hydronium-js/dom-client/src/mount.js";
import { createWasmoonLua54Provider } from "@hydronium-js/dom-client/src/engine_provider.js";

mount({ /* ... */ engineProvider: createWasmoonLua54Provider() });
```

## What is identical

Inside Lua, both engines are real Lua 5.4: the same syntax, standard library,
64-bit integers, coroutines, metatables, `pcall`/`error` and `string.format`.
Code that stays in Lua behaves the same as under a native `lua5.4`, with the
sandbox differences listed below.

Both engines also convert these the same way at the JS boundary (checked by
`tests/client/lua_engine_parity.test.mjs`):

- Numbers. Integral JS numbers become Lua integers, others become floats.
  Lua integers above 2^53 reach JS rounded, because JS `number` can't hold them.
- `return a, b` gives JS `a`.
- A Lua table with keys exactly `1..n` becomes an `Array`. Any other table,
  including `{}`, becomes a plain object with string keys. Metatables are
  ignored. Cycles and shared subtables keep their identity.
- A JS object or array reaches Lua as userdata that you can index
  (`state.items[1]`, 1-based for arrays), measure (`#state.items`), call
  methods on (`obj:method()` or `obj.method()`) and assign to (writes go
  through to the JS object). `type()` of it is `"userdata"`, not `"table"`.

## Where the engines differ

The test above pins each of these differences, so a new one fails CI until
it's documented here.

| | lua-wasm | Wasmoon |
|---|---|---|
| Lua `nil` in JS | `undefined` | `null` |
| `-0` into Lua | float `-0.0` | integer `0` |
| `bigint` into Lua | exact integer within int64, `RangeError` outside | throws |
| string containing `\0` | intact | truncated at the NUL |
| Lua function in JS | `LuaFunctionHandle`: `await fn.call([args])`, `fn.release()` (also released on GC) | JS function |
| JS function returning a promise | the Lua task suspends until it settles, so Lua sees the value | Lua gets the promise; use `:await()` |
| error value that isn't a string | message is `tostring(value)` (honours `__tostring`); a table is also on `error.luaValue` | `"table: 0x…"` plus traceback |
| error message | no traceback | traceback appended |
| table key that is a table or function | `TypeError` | stringified |
| `pairs(jsObject)` | iterates `Object.keys` (1..n for arrays) | throws |
| same JS object passed twice | the same userdata (`==` holds) | not guaranteed |
| `os.execute` | does nothing | throws |
| extra global | `hydronium_task` | none |

Bridge API 2 exists only for Lua 5.4.9. Selecting another Lua version in the
browser isn't supported.

## Sandbox differences from native Lua (both engines)

- `io` reads and writes an in-memory filesystem that starts empty and vanishes
  with the page. No host files are visible.
- `os.getenv` returns Emscripten's synthetic environment (`HOME=/home/web_user`).
- `require` resolves modules Hydronium preloaded into `package.preload`. C
  modules (`package.loadlib`, `require "socket"`) can't load.
- `print` writes to the browser console.

## If you depend on the boundary

- Pass structured data from JS to Lua as JSON text and decode it in Lua when
  Lua code checks `type(x) == "table"`. Hydronium's router hydration state
  already works this way.
- Compare Lua results with `== null` in JS, not `=== null` or `=== undefined`.
- Release function handles you keep (`handle.release()`). GC releases the rest
  eventually.
- Don't send integers beyond ±2^53 through JS numbers. Use strings or `bigint`.
