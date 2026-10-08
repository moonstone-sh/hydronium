import test from "node:test";
import assert from "node:assert/strict";
import { createDomBridge, snapshotDomEvent } from "../../js/packages/dom-client/src/dom_bridge.js";

function element(tagName, props = {}) {
  const attrs = new Map();
  const listeners = new Map();
  return Object.assign({
    tagName,
    attrs,
    listeners,
    setAttribute(k, v) { attrs.set(k, v); },
    removeAttribute(k) { attrs.delete(k); },
    addEventListener(name, fn) { listeners.set(name, fn); },
    removeEventListener(name) { listeners.delete(name); },
  }, props);
}

function event(type, target, fields = {}) {
  return { type, target, currentTarget: target, timeStamp: 1, defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}, ...fields };
}

test("Lua handlers receive an event snapshot with the control's value", () => {
  const bridge = createDomBridge();
  const input = element("INPUT", { value: "hel", name: "greeting" });
  const seen = [];
  bridge.set_listener(input, "input", (e) => seen.push(e));
  input.value = "hello";
  input.listeners.get("input")(event("input", input, { data: "o", inputType: "insertText" }));
  assert.equal(seen.length, 1);
  assert.equal(seen[0].value, "hello");
  assert.equal(seen[0].name, "greeting");
  assert.equal(seen[0].data, "o");
  assert.equal(seen[0].target, input);
  // A snapshot: later typing does not change what the handler saw.
  input.value = "hello!";
  assert.equal(seen[0].value, "hello");
});

test("keyboard and checkbox events carry key and checked; preventDefault reaches the event", () => {
  const box = element("INPUT", { value: "on", checked: true });
  const snap = snapshotDomEvent(event("change", box));
  assert.equal(snap.checked, true);
  const key = event("keydown", element("INPUT", { value: "" }), { key: "Enter", code: "Enter", shiftKey: false });
  const k = snapshotDomEvent(key);
  assert.equal(k.key, "Enter");
  assert.equal(k.shiftKey, false);
  k.preventDefault();
  assert.equal(key.defaultPrevented, true);
  assert.equal(k.isDefaultPrevented(), true);
});

test("submit and navigate stay argument-free unless an adapter is registered", () => {
  const bridge = createDomBridge();
  const form = element("FORM");
  const args = [];
  bridge.set_listener(form, "submit", (...a) => args.push(a.length));
  form.listeners.get("submit")(event("submit", form));
  assert.deepEqual(args, [0]);
});

test("Wasmoon-style callables get the snapshot through call()", () => {
  const bridge = createDomBridge();
  const button = element("BUTTON");
  let received;
  bridge.set_listener(button, "click", { call(args) { received = args; } });
  button.listeners.get("click")(event("click", button, { clientX: 4, button: 0 }));
  assert.equal(received.length, 1);
  assert.equal(received[0].clientX, 4);
});

test("value, checked and selected set the live property as well as the attribute", () => {
  const bridge = createDomBridge();
  const input = element("INPUT", { value: "typed by user" });
  bridge.set_attr(input, "value", "reset");
  assert.equal(input.value, "reset");
  assert.equal(input.attrs.get("value"), "reset");
  bridge.remove_attr(input, "value");
  assert.equal(input.value, "");
  const box = element("INPUT", { value: "on", checked: false });
  bridge.set_attr(box, "checked", true);
  assert.equal(box.checked, true);
  bridge.set_attr(box, "checked", false);
  assert.equal(box.checked, false);
  assert.equal(box.attrs.has("checked"), false);
  // Other elements keep plain attribute semantics.
  const div = element("DIV");
  bridge.set_attr(div, "value", "x");
  assert.equal(div.value, undefined);
  assert.equal(div.attrs.get("value"), "x");
});
