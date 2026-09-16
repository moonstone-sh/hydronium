import test from "node:test";
import assert from "node:assert/strict";
import { createDomBridge } from "../../dom/src/hydronium_dom/client/dom_bridge.js";

test("DOM bridge treats explicit raw HTML as content, not an attribute", () => {
  const bridge = createDomBridge();
  const element = {
    innerHTML: "",
    setAttribute() { throw new Error("raw HTML must not become an attribute"); },
    removeAttribute() { throw new Error("raw HTML must not become an attribute"); },
  };
  bridge.set_attr(element, "unsafe_raw_html", "<strong>README</strong>");
  assert.equal(element.innerHTML, "<strong>README</strong>");
  bridge.remove_attr(element, "unsafe_raw_html");
  assert.equal(element.innerHTML, "");
});
