/*
  Browser Lua engine providers.

  `mount()` talks to a provider, not directly to a particular WASM package.
  That keeps the currently shipped Wasmoon/Puc Lua 5.4 engine as the stable
  default while making a future vendored Lua 5.1 (or another compatible
  browser engine) an explicit, per-mount choice.  A provider must return the
  engine shape mount already relies on: `global.set`, `global.get`, and
  `doString`.

  This module intentionally does not select or ship another interpreter.
  It is the narrow compatibility seam that lets a later engine be added
  without coupling mount, preload, and HMR orchestration to Wasmoon's API.
*/

export const DEFAULT_WASMOON_URL = new URL("./vendor/wasmoon/wasmoon.esm.js", import.meta.url).href;
export const DEFAULT_WASMOON_WASM_URL = new URL("./vendor/wasmoon/glue.wasm", import.meta.url).href;

/**
 * Create a provider for the existing vendored Wasmoon Lua 5.4 engine.
 * `importModule` is injectable only so the provider contract can be tested
 * without instantiating WebAssembly in Node.
 */
export function createWasmoonLua54Provider({
  wasmoonUrl = DEFAULT_WASMOON_URL,
  wasmoonWasmUrl = DEFAULT_WASMOON_WASM_URL,
  importModule = (url) => import(/* @vite-ignore */ url),
} = {}) {
  return {
    id: "lua54",
    async create({ wasmoonUrl: overrideUrl, wasmoonWasmUrl: overrideWasmUrl, onPhase } = {}) {
      const moduleUrl = overrideUrl || wasmoonUrl;
      const wasmUrl = overrideWasmUrl || wasmoonWasmUrl;
      onPhase?.("import:start");
      const { LuaFactory } = await importModule(moduleUrl);
      onPhase?.("import:end");
      onPhase?.("create:start");
      const factory = new LuaFactory(wasmUrl);
      const engine = await factory.createEngine();
      onPhase?.("create:end");
      return engine;
    },
  };
}

// Compatibility default: this is exactly the Wasmoon Lua 5.4 boot path that
// mount used before providers existed, including its self-hosted asset URLs.
export const defaultBrowserEngineProvider = createWasmoonLua54Provider();
