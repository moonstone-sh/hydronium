import test from "node:test";
import assert from "node:assert/strict";
import { createFormGlobals, valuesFromForm } from "../../dom/src/hydronium_dom/client/forms.js";
import { createDomBridge, shouldHandleNavigation } from "../../dom/src/hydronium_dom/client/dom_bridge.js";

class FakeFormData {
  constructor(form) { this.form = form; }
  entries() { return this.form.entries[Symbol.iterator](); }
}

test("DOM event props run with a prevent-default bridge atom", () => {
  const listeners = new Map();
  const element = {
    addEventListener(name, fn) { listeners.set(name, fn); },
    removeEventListener() {},
  };
  let called = false;
  let payload;
  let prevented = false;
  createFormGlobals({ FormData: FakeFormData, fetch: async () => ({}) });
  const bridge = createDomBridge();
  bridge.set_listener(element, "submit", (captured) => {
    called = true;
    payload = captured;
    bridge.prevent_default();
  });
  const event = {
    currentTarget: { entries: [["name", "Ada"]] },
    preventDefault() { prevented = true; },
  };
  listeners.get("submit")(event);
  assert.equal(called, true);
  assert.equal(prevented, true);
  assert.equal(payload, '{ name = "Ada" }');
});

test("router navigation leaves modified and external links to the browser", () => {
  const previousLocation = globalThis.location;
  globalThis.location = { href: "https://example.test/", origin: "https://example.test" };
  const anchor = {
    hasAttribute: () => false,
    getAttribute(name) { return name === "href" ? "/about" : null; },
  };
  assert.equal(shouldHandleNavigation({ currentTarget: anchor, button: 0 }), true);
  assert.equal(shouldHandleNavigation({ currentTarget: anchor, button: 0, metaKey: true }), false);
  anchor.getAttribute = (name) => name === "href" ? "https://other.test/" : null;
  assert.equal(shouldHandleNavigation({ currentTarget: anchor, button: 0 }), false);
  if (previousLocation === undefined) delete globalThis.location;
  else globalThis.location = previousLocation;
});

test("form values preserve repeated controls and punctuation", () => {
  assert.deepEqual(valuesFromForm({ entries: [["tag", "lua"], ["tag", "zig"], ["name", "sad pepe"]] }, FakeFormData), {
    tag: ["lua", "zig"],
    name: "sad pepe",
  });
});

test("form globals compose a cancellable JSON action request", async () => {
  let request;
  let redirected;
  let prevented = false;
  const globals = createFormGlobals({
    FormData: FakeFormData,
    navigate: (url) => { redirected = url; },
    fetch: async (url, options) => {
      request = { url, options };
      return {
        status: 422,
        headers: { get: (name) => name === "content-type" ? "application/json" : null },
        json: async () => ({ ok: false, errors: { name: ["Required"] } }),
      };
    },
  });
  const event = {
    currentTarget: { entries: [["name", "sad pepe"], ["tag", "lua"], ["tag", "zig"]] },
    preventDefault() { prevented = true; },
  };
  globals.__hydronium_form_prevent_default(event);
  const literal = globals.__hydronium_form_values(event);
  assert.equal(prevented, true);
  assert.match(literal, /tag = \{ "lua", "zig" \}/);

  const settled = new Promise((resolve) => {
    globals.__hydronium_form_request("/actions/profile", "POST", "name=sad%20pepe", "profile.save", (status, body) => resolve({ status, body }));
  });
  const result = await settled;
  assert.equal(request.url, "/actions/profile");
  assert.equal(request.options.headers["x-hydronium-action"], "profile.save");
  assert.equal(result.status, 422);
  assert.match(result.body, /Required/);
  globals.__hydronium_form_redirect("/done");
  assert.equal(redirected, "/done");
});
