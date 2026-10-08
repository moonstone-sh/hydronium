// Lua <-> JS value parity between the default lua-wasm engine and the
// Wasmoon fallback, using the vendored copies dom-client actually serves.
// Every case either matches on both engines or has its difference written
// out here and in docs/LUA_ENGINES.md. Undocumented drift fails this test.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const vendor = path.join(path.dirname(fileURLToPath(import.meta.url)), "../../js/packages/dom-client/src/vendor");

async function luaWasm() {
  const dir = path.join(vendor, "lua-wasm/5.4.9");
  const { default: moduleFactory } = await import(pathToFileURL(path.join(dir, "engine.js")).href);
  const { createTaskEngine } = await import(pathToFileURL(path.join(dir, "task-runtime.mjs")).href);
  const engine = await createTaskEngine({ moduleFactory });
  return { run: (source) => engine.run(source), set: (k, v) => engine.global.set(k, v), get: (k) => engine.global.get(k), close: () => engine.close() };
}

async function wasmoon() {
  // The vendored UMD build sits in a "type": "module" package; load a .cjs
  // copy of the exact same bytes.
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), "hydronium-wasmoon-"));
  fs.copyFileSync(path.join(vendor, "wasmoon/index.js"), path.join(stage, "wasmoon.cjs"));
  const { LuaFactory } = createRequire(import.meta.url)(path.join(stage, "wasmoon.cjs"));
  const engine = await new LuaFactory(path.join(vendor, "wasmoon/glue.wasm")).createEngine();
  return {
    run: (source) => engine.doString(source), set: (k, v) => engine.global.set(k, v), get: (k) => engine.global.get(k),
    close: () => { engine.global.close(); fs.rmSync(stage, { recursive: true, force: true }); },
  };
}

const [api2, fallback] = await Promise.all([luaWasm(), wasmoon()]);
test.after(async () => { await api2.close(); fallback.close(); });

const both = async (source) => [await api2.run(source), await fallback.run(source)];
const describe = (value) => typeof value === "object" && value !== null ? JSON.stringify(value) : `${typeof value}:${String(value)}`;
const same = async (source, expected) => {
  const [a, w] = await both(source);
  assert.deepEqual(a, expected, `lua-wasm: ${source} -> ${describe(a)}`);
  assert.deepEqual(w, expected, `wasmoon: ${source} -> ${describe(w)}`);
};

test("results: numbers, strings, first of several values", async () => {
  await same("return 1", 1);
  await same("return 1.5", 1.5);
  await same("return math.maxinteger", 9223372036854775807);
  await same("return 1, 2", 1);
  await same("return 'á水'", "á水");
});

test("results: tables convert to arrays and objects", async () => {
  await same("return {1, 2, 3}", [1, 2, 3]);
  await same("return {}", {});
  await same("return {1, 2, nil, 4}", { 1: 1, 2: 2, 4: 4 });
  await same("return {a = 1, b = {c = 'x', d = {true}}}", { a: 1, b: { c: "x", d: [true] } });
  await same("return setmetatable({}, {__index = {a = 1}})", {});
  for (const engine of [api2, fallback]) {
    const cyclic = await engine.run("local t = {} t.self = t return t");
    assert.equal(cyclic.self, cyclic);
  }
});

test("results: an HMR summary table reads the same on both engines", async () => {
  // The shape hydronium.core.hmr.apply_batch returns, which the Lab preview reads.
  const source = "return {outcome = 'applied', families = 1, refreshed = 2, failed = 0, results = {['app.counter'] = {refreshed = 2, failed = 0}}}";
  await same(source, { outcome: "applied", families: 1, refreshed: 2, failed: 0, results: { "app.counter": { refreshed: 2, failed: 0 } } });
});

test("globals: tables and scalars", async () => {
  await both("parity_config = {mode = 'dev', ports = {8080, 8081}}");
  assert.deepEqual(api2.get("parity_config"), { mode: "dev", ports: [8080, 8081] });
  assert.deepEqual(fallback.get("parity_config"), { mode: "dev", ports: [8080, 8081] });
});

test("JS -> Lua numbers keep the integer/float subtype", async () => {
  for (const [value, type] of [[3, "integer"], [3.5, "float"], [2 ** 53 + 2, "integer"]]) {
    for (const engine of [api2, fallback]) {
      engine.set("parity_n", value);
      assert.equal(await engine.run("return math.type(parity_n)"), type, `${value}`);
    }
  }
});

test("JS objects are indexable from Lua (router-state shaped)", async () => {
  const state = { canonical_url: "/about", route_chain: ["root", "about"], resources: { about: { status: "ready" } } };
  const probe = "return s.canonical_url .. '|' .. #s.route_chain .. '|' .. s.route_chain[1] .. '|' .. s.resources.about.status .. '|' .. tostring(s.route_chain[0])";
  for (const engine of [api2, fallback]) {
    engine.set("s", state);
    assert.equal(await engine.run(probe), "/about|2|root|ready|nil");
    await engine.run("s.visited = true");
  }
  assert.equal(state.visited, true, "assignments write through on both engines");
  for (const engine of [api2, fallback]) assert.equal(await engine.run("return type(s)"), "userdata");
});

test("documented drift: these differ on purpose (docs/LUA_ENGINES.md)", async () => {
  // nil crosses as undefined on lua-wasm, null on Wasmoon.
  const [nilA, nilW] = await both("return nil");
  assert.equal(nilA, undefined);
  assert.equal(nilW, null);

  // -0 stays a float (-0.0) on lua-wasm; Wasmoon makes it integer 0.
  for (const engine of [api2, fallback]) engine.set("parity_z", -0);
  assert.equal(await api2.run("return math.type(parity_z) .. ' ' .. tostring(parity_z)"), "float -0.0");
  assert.equal(await fallback.run("return math.type(parity_z) .. ' ' .. tostring(parity_z)"), "integer 0");

  // Strings with NUL bytes: lua-wasm keeps them, Wasmoon truncates.
  const [nulA, nulW] = await both("return 'a\\0b'");
  assert.equal(nulA, "a\0b");
  assert.equal(nulW, "a");

  // Functions: lua-wasm returns a handle with .call([args]) -> Promise.
  const [fnA, fnW] = await both("return function(x) return x * 2 end");
  assert.equal(await fnA.call([21]), 42);
  fnA.release();
  assert.equal(typeof fnW, "function");

  // BigInt: an exact Lua integer on lua-wasm, unsupported on Wasmoon.
  api2.set("parity_big", 2n ** 62n);
  assert.equal(await api2.run("return tostring(parity_big)"), "4611686018427387904");
  assert.throws(() => fallback.set("parity_big", 5n));

  // Error values: lua-wasm gives tostring() text (and the table as
  // error.luaValue); Wasmoon appends a traceback.
  const failure = async (engine) => { try { await engine.run("error({code = 42})"); } catch (error) { return error; } };
  const [errA, errW] = [await failure(api2), await failure(fallback)];
  assert.match(errA.message, /^table: 0x[0-9a-f]+$/);
  assert.equal(errA.luaValue.code, 42);
  assert.match(errW.message, /^table: 0x[0-9a-f]+\nstack traceback:/);

  // Promise-returning JS functions: lua-wasm suspends the Lua task until
  // the promise settles; Wasmoon hands Lua the promise (use :await()).
  for (const engine of [api2, fallback]) engine.set("parity_later", () => Promise.resolve(5));
  assert.equal(await api2.run("return parity_later()"), 5);
  assert.equal(await fallback.run("return type(parity_later())"), "userdata");
  assert.equal(await fallback.run("return parity_later():await()"), 5);
});

test("Lua event handlers read the DOM bridge's event snapshot on both engines", async () => {
  const { createDomBridge } = await import("../../js/packages/dom-client/src/dom_bridge.js");
  for (const engine of [api2, fallback]) {
    await engine.run(`
      seen = nil
      handler = function(e)
        seen = e.type .. "|" .. e.value .. "|" .. tostring(e.checked) .. "|" .. e.key
        e.preventDefault()
      end`);
    const listeners = new Map();
    const input = { tagName: "INPUT", value: "hello", checked: false, name: "q",
      addEventListener: (n, fn) => listeners.set(n, fn), removeEventListener() {} };
    createDomBridge().set_listener(input, "keydown", engine.get("handler"));
    const domEvent = { type: "keydown", target: input, currentTarget: input, key: "Enter", timeStamp: 0,
      defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {} };
    await listeners.get("keydown")(domEvent);
    // Promise-backed callbacks settle after the listener returns.
    for (let i = 0; i < 20 && engine.get("seen") == null; i++) await new Promise((r) => setTimeout(r, 5));
    assert.equal(engine.get("seen"), "keydown|hello|false|Enter");
    assert.equal(domEvent.defaultPrevented, true);
  }
});
