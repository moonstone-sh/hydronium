import test from "node:test";
import assert from "node:assert/strict";

import {
  createWasmoonLua54Provider,
  defaultBrowserEngineProvider,
} from "../../js/packages/dom-client/src/engine_provider.js";

test("the default browser provider keeps the existing Lua 5.4 Wasmoon selection", () => {
  assert.equal(defaultBrowserEngineProvider.id, "lua54");
  assert.equal(typeof defaultBrowserEngineProvider.create, "function");
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
