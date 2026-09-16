import test from "node:test";
import assert from "node:assert/strict";
import { createHttpGlobals } from "../../router/client/http.js";

test("router GET bridge decodes JSON and is same-origin", async () => {
  let options;
  const globals = createHttpGlobals({
    fetch: async (path, passed) => {
      assert.equal(path, "/api/packages/ballad");
      options = passed;
      return {
        status: 200,
        headers: { get: () => "application/json" },
        json: async () => ({ data: { coordinate: "moonstone/ballad" } }),
      };
    },
  });
  const result = await new Promise((resolve) => globals.__router_http_get("/api/packages/ballad", resolve));
  assert.equal(options.credentials, "same-origin");
  assert.equal(options.headers.accept, "application/json");
  assert.equal(JSON.parse(result).body.data.coordinate, "moonstone/ballad");
});

test("router GET bridge aborts an obsolete request without calling Lua", async () => {
  let release;
  const globals = createHttpGlobals({
    fetch: () => new Promise((resolve) => { release = resolve; }),
  });
  let called = false;
  const cancel = globals.__router_http_get("/api/packages/ballad", () => { called = true; });
  cancel();
  release({ status: 200, headers: { get: () => "application/json" }, json: async () => ({ ok: true }) });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(called, false);
});
