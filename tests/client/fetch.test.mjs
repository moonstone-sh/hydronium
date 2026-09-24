import test from "node:test";
import assert from "node:assert/strict";
import { createBrowserRequest, readResponse } from "../../js/packages/dom-client/src/fetch.js";

test("browser request applies same-origin credentials and its abort controller", async () => {
  let init;
  const request = createBrowserRequest({
    fetch: (_url, passed) => {
      init = passed;
      return new Promise((_resolve, reject) => passed.signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" }))));
    },
  });
  const pending = request("/api/todos", { method: "GET" });
  assert.equal(init.credentials, "same-origin");
  pending.abort();
  await assert.rejects(pending.promise, { name: "AbortError" });
  assert.equal(pending.signal.aborted, true);
});

test("browser request forwards an external abort signal and response decoding preserves HTTP status", async () => {
  let init;
  const external = new AbortController();
  const request = createBrowserRequest({ fetch: (_url, passed) => { init = passed; return Promise.resolve({ status: 422, headers: { get: () => "application/json" }, json: async () => ({ ok: false }) }); } });
  const pending = request("/api/todos", { signal: external.signal });
  external.abort();
  const response = await pending.promise;
  assert.equal(init.signal.aborted, true);
  assert.deepEqual(await readResponse(response), { status: 422, headers: { "content-type": "application/json" }, body: { ok: false } });
});
