import test from "node:test";
import assert from "node:assert/strict";

import {
  createHydroniumLua54Provider,
  createWasmoonLua54Provider,
  defaultBrowserEngineProvider,
} from "../../js/packages/dom-client/src/engine_provider.js";

test("the default browser provider selects Bridge API 2 Lua 5.4", () => {
  assert.equal(defaultBrowserEngineProvider.id, "lua54-api2");
  assert.equal(typeof defaultBrowserEngineProvider.create, "function");
});

test("the API 2 provider imports its module and scheduler and exposes the Hydronium engine shape", async () => {
  const imports = [];
  const phases = [];
  const moduleFactory = () => {};
  const taskEngine = { global: { set() {}, get() {} }, run: async () => undefined, close: async () => {} };
  const provider = createHydroniumLua54Provider({
    engineUrl: "/assets/lua/engine.js",
    taskRuntimeUrl: "/assets/lua/task-runtime.mjs",
    wasmUrl: "/assets/lua/engine.wasm",
    importModule: async (url) => {
      imports.push(url);
      return url.endsWith("task-runtime.mjs")
        ? { createTaskEngine: async (options) => {
            assert.equal(options.moduleFactory, moduleFactory);
            assert.equal(options.moduleOptions.locateFile("engine.wasm", "/prefix/"), "/assets/lua/engine.wasm");
            return taskEngine;
          } }
        : { default: moduleFactory };
    },
  });

  const engine = await provider.create({ onPhase: (phase) => phases.push(phase) });
  assert.equal(engine, taskEngine);
  assert.equal(engine.id, "lua54-api2");
  assert.equal(engine.global, taskEngine.global);
  assert.equal(await engine.doString("return 1"), undefined);
  assert.deepEqual(imports, ["/assets/lua/engine.js", "/assets/lua/task-runtime.mjs"]);
  assert.deepEqual(phases, ["import:start", "import:end", "create:start", "create:end"]);
});

test("the Wasmoon provider preserves URL overrides and reports boot phases", async () => {
  const imports = [];
  const constructions = [];
  const phases = [];
  const engine = { global: {}, doString() {} };

  class LuaFactory {
    constructor(wasmUrl) {
      constructions.push(wasmUrl);
    }
    async createEngine() {
      return engine;
    }
  }

  const provider = createWasmoonLua54Provider({
    wasmoonUrl: "https://assets.example/lua54.js",
    wasmoonWasmUrl: "https://assets.example/lua54.wasm",
    importModule: async (url) => {
      imports.push(url);
      return { LuaFactory };
    },
  });

  assert.equal(
    await provider.create({ onPhase: (phase) => phases.push(phase) }),
    engine,
  );
  assert.deepEqual(imports, ["https://assets.example/lua54.js"]);
  assert.deepEqual(constructions, ["https://assets.example/lua54.wasm"]);
  assert.deepEqual(phases, ["import:start", "import:end", "create:start", "create:end"]);

  await provider.create({
    wasmoonUrl: "https://override.example/lua.js",
    wasmoonWasmUrl: "https://override.example/lua.wasm",
  });
  assert.deepEqual(imports, ["https://assets.example/lua54.js", "https://override.example/lua.js"]);
  assert.deepEqual(constructions, ["https://assets.example/lua54.wasm", "https://override.example/lua.wasm"]);
});
