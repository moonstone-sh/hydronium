import test from "node:test";
import assert from "node:assert/strict";

import { boot } from "../../js/packages/dom-client/src/mount.js";

test("boot installs the Lua 5.1-compatible compiler before compiling bundled source", async () => {
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;
  const commands = [];
  const globals = new Map();
  const container = {
    setAttribute() {},
    removeAttribute() {},
  };
  const lua = {
    global: {
      set(key, value) { globals.set(key, value); },
      get(key) { return globals.get(key); },
    },
    async doString(source) {
      commands.push(source);
    },
  };

  globalThis.document = { querySelector: () => container };
  globalThis.fetch = async () => ({ ok: true, text: async () => "return {}" });

  try {
    await boot({
      chunkUrls: ["/client.lua"],
      appModuleId: "App",
      container: "#app",
      engineProvider: { create: async () => lua },
    });

    const compilerIndex = commands.findIndex((source) => source.includes("loadstring or load"));
    const chunkIndex = commands.findIndex((source) => source.includes("__hydronium_chunk_src"));
    assert.ok(compilerIndex >= 0, "the compiler is installed in the browser VM");
    assert.ok(chunkIndex > compilerIndex, "chunks compile only after the helper exists");
    assert.match(commands[chunkIndex], /__hydronium_compile/);
    assert.ok(
      commands.every((source) => !source.includes("assert(load(")),
      "mount source evaluation has no Lua-5.4-only load() call",
    );
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});
