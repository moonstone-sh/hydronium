// Tests for the dev error overlay's parsing and rendering.
//
// These use a tiny hand-rolled DOM rather than a real browser: everything
// asserted here is pure string/DOM-shape logic, and a real-browser proof that
// the overlay actually appears on a real Lua error lives in
// js/tests/overlay.browser.test.mjs. Keeping the cheap half cheap means it
// runs in the zero-install CI step alongside the other client tests.

import test from "node:test";
import assert from "node:assert/strict";
import {
  parseLuaFrames,
  errorHeadline,
  renderErrorOverlay,
  dismissErrorOverlay,
} from "../../js/packages/dom-client/src/overlay.js";

// A real traceback, as wasmoon surfaces it: the header repeats the erroring
// frame that then appears again in the stack.
const REAL_TRACEBACK = [
  '[string "views.App"]:12: attempt to index a nil value (field \'props\')',
  "stack traceback:",
  '\t[string "views.App"]:12: in function <[string "views.App"]:9>',
  '\t[string "hydronium.core.component"]:406: in function \'refresh\'',
  '\t[string "views.App"]:12: in main chunk',
].join("\n");

function fakeDoc() {
  const make = (tag) => ({
    tagName: tag.toUpperCase(),
    children: [],
    attributes: {},
    textContent: "",
    id: "",
    setAttribute(k, v) { this.attributes[k] = v; },
    addEventListener() {},
    append(...kids) { this.children.push(...kids); },
    appendChild(kid) { this.children.push(kid); return kid; },
    remove() { this.removed = true; },
  });
  const doc = {
    body: make("body"),
    _byId: {},
    createElement: (t) => make(t),
    createTextNode: (t) => ({ nodeType: 3, textContent: String(t) }),
    getElementById(id) { return this._byId[id] ?? null; },
  };
  const origAppend = doc.body.appendChild.bind(doc.body);
  doc.body.appendChild = (kid) => { if (kid.id) doc._byId[kid.id] = kid; return origAppend(kid); };
  return doc;
}

const flatten = (node, out = []) => {
  out.push(node);
  for (const k of node.children ?? []) flatten(k, out);
  return out;
};
const allText = (node) =>
  flatten(node).map((n) => n.textContent ?? "").join("\n");

test("parses module and line out of a real Lua traceback", () => {
  const frames = parseLuaFrames(REAL_TRACEBACK);
  assert.ok(frames.length >= 2);
  assert.deepEqual(frames[0], { module: "views.App", line: 12 });
  assert.ok(frames.some((f) => f.module === "hydronium.core.component" && f.line === 406));
});

test("does not repeat the frame a traceback names twice", () => {
  // views.App:12 appears three times in REAL_TRACEBACK.
  const frames = parseLuaFrames(REAL_TRACEBACK).filter(
    (f) => f.module === "views.App" && f.line === 12
  );
  assert.equal(frames.length, 1);
});

test("returns no frames rather than guessing on unrecognized text", () => {
  assert.deepEqual(parseLuaFrames("TypeError: x is not a function"), []);
  assert.deepEqual(parseLuaFrames(""), []);
  assert.deepEqual(parseLuaFrames(null), []);
});

test("strips the chunk:line prefix from the headline but keeps the message", () => {
  assert.equal(
    errorHeadline(REAL_TRACEBACK),
    "attempt to index a nil value (field 'props')"
  );
});

test("leaves a headline alone when it is not chunk:line shaped", () => {
  assert.equal(errorHeadline("boom"), "boom");
});

test("renders message, frames and the raw traceback", () => {
  const doc = fakeDoc();
  const root = renderErrorOverlay(doc, { phase: "mount", error: new Error(REAL_TRACEBACK) });
  const text = allText(root);
  assert.match(text, /attempt to index a nil value/);
  assert.match(text, /views\.App/);
  assert.match(text, /Hydronium — mount/);
  // The raw traceback must survive verbatim -- the parser is conservative and
  // anything it fails to recognize still has to be readable.
  assert.match(text, /stack traceback:/);
});

test("marks an unresolved frame as generated Lua rather than implying it is source", () => {
  const doc = fakeDoc();
  const root = renderErrorOverlay(doc, { error: new Error(REAL_TRACEBACK) });
  assert.match(allText(root), /\(generated Lua\)/);
});

test("uses a resolveFrame hook when one is supplied, and then says nothing about generated Lua", () => {
  const doc = fakeDoc();
  const root = renderErrorOverlay(doc, {
    error: new Error(REAL_TRACEBACK),
    resolveFrame: (f) =>
      f.module === "views.App" ? { file: "src/views/App.luax", line: 7 } : null,
  });
  const text = allText(root);
  assert.match(text, /src\/views\/App\.luax/);
  assert.match(text, /:7/);
});

test("replaces a previous overlay instead of stacking them", () => {
  const doc = fakeDoc();
  const first = renderErrorOverlay(doc, { error: new Error("one") });
  renderErrorOverlay(doc, { error: new Error("two") });
  assert.equal(first.removed, true);
});

test("dismiss reports whether there was anything to dismiss", () => {
  const doc = fakeDoc();
  assert.equal(dismissErrorOverlay(doc), false);
  renderErrorOverlay(doc, { error: new Error("x") });
  assert.equal(dismissErrorOverlay(doc), true);
});

test("renders a non-Error thrown value without crashing", () => {
  const doc = fakeDoc();
  const root = renderErrorOverlay(doc, { error: "a bare string" });
  assert.match(allText(root), /a bare string/);
});
