/* Browser Lua engine providers.
 *
 * Hydronium defaults to its self-hosted Bridge API 2 Lua 5.4.9 build. The
 * Wasmoon provider remains available for explicit compatibility overrides.
 */

export const DEFAULT_LUA_ENGINE_URL = new URL("./vendor/lua-wasm/5.4.9/engine.js", import.meta.url).href;
export const DEFAULT_LUA_TASK_RUNTIME_URL = new URL("./vendor/lua-wasm/5.4.9/task-runtime.mjs", import.meta.url).href;
export const DEFAULT_LUA_WASM_URL = new URL("./vendor/lua-wasm/5.4.9/engine.wasm", import.meta.url).href;
export const DEFAULT_WASMOON_URL = new URL("./vendor/wasmoon/wasmoon.esm.js", import.meta.url).href;
export const DEFAULT_WASMOON_WASM_URL = new URL("./vendor/wasmoon/glue.wasm", import.meta.url).href;

export function createHydroniumLua54Provider({
  engineUrl = DEFAULT_LUA_ENGINE_URL,
  taskRuntimeUrl = DEFAULT_LUA_TASK_RUNTIME_URL,
  wasmUrl = DEFAULT_LUA_WASM_URL,
  importModule = (url) => import(/* @vite-ignore */ url),
} = {}) {
  return {
    id: "lua54-api2",
    async create({ luaEngineUrl: overrideEngineUrl, luaTaskRuntimeUrl: overrideRuntimeUrl, luaWasmUrl: overrideWasmUrl, onPhase } = {}) {
      const moduleUrl = overrideEngineUrl || engineUrl;
      const runtimeUrl = overrideRuntimeUrl || taskRuntimeUrl;
      const binaryUrl = overrideWasmUrl || wasmUrl;
      onPhase?.("import:start");
      const [{ default: moduleFactory }, { createTaskEngine }] = await Promise.all([
        importModule(moduleUrl), importModule(runtimeUrl),
      ]);
      onPhase?.("import:end");
      onPhase?.("create:start");
      const locateFile = (path, prefix) => path.endsWith(".wasm") ? binaryUrl : `${prefix}${path}`;
      const taskEngine = await createTaskEngine({ moduleFactory, moduleOptions: { locateFile } });
      onPhase?.("create:end");
      return Object.assign(taskEngine, {
        id: "lua54-api2",
        global: taskEngine.global,
        doString: (source) => taskEngine.run(source),
      });
    },
  };
}

/** Explicit compatibility fallback for applications that still need Wasmoon. */
export function createWasmoonLua54Provider({
  wasmoonUrl = DEFAULT_WASMOON_URL,
  wasmoonWasmUrl = DEFAULT_WASMOON_WASM_URL,
  importModule = (url) => import(/* @vite-ignore */ url),
} = {}) {
  return {
    id: "wasmoon-lua54",
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

export const defaultBrowserEngineProvider = createHydroniumLua54Provider();
