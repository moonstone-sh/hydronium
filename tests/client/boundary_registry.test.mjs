// Tests for src/hydronium/client/boundary_registry.js.
//
// Uses Node's built-in test runner (`node --test`) and a minimal
// hand-rolled DOM stand-in -- no jsdom, no new dependency. This is the
// first JS code in a Lua-first framework; adding a real dependency for
// one test file would be a bigger footprint change than the module
// itself. The module's own real-DOM behavior (TreeWalker semantics,
// real dispatched click events, the exact SSR-produced HTML shape) was
// separately verified against jsdom during development -- see
// docs/HYDRONIUM_CLIENT_BOUNDARY_REGISTRY.md. This file exists so the
// module's own logic (marker matching, ownership, generations) has a
// permanent, runnable, dependency-free regression test.
//
// Run with: node --test tests/client/boundary_registry.test.mjs

import test from "node:test";
import assert from "node:assert/strict";

// --- Minimal fake DOM ---------------------------------------------------
// Only the surface boundary_registry.js actually uses: a "document" that
// can createTreeWalker over comment nodes, and nodes linked by
// nextSibling. Real DOM semantics (TreeWalker over an actual live tree,
// real Comment/Element nodes) are not reproduced beyond what the module
// touches.

globalThis.NodeFilter = { SHOW_COMMENT: 128 };

function comment(value) {
  return { nodeType: 8, nodeValue: value, nextSibling: null };
}
function element(tagName, textContent) {
  return { nodeType: 1, tagName, textContent, nextSibling: null };
}
function text(content) {
  return { nodeType: 3, textContent: content, nextSibling: null };
}

/** Builds a fake root from a flat list of fake nodes, wiring nextSibling and a createTreeWalker that yields comment nodes in order. */
function fakeRoot(children) {
  for (let i = 0; i < children.length; i++) {
    children[i].nextSibling = children[i + 1] || null;
  }
  return {
    nodeType: 1,
    tagName: "DIV",
    createTreeWalker(_root, _filter) {
      let idx = -1;
      return {
        nextNode() {
          idx++;
          while (idx < children.length) {
            if (children[idx].nodeType === 8) return children[idx];
            idx++;
          }
          return null;
        },
      };
    },
  };
}

// --- Tests ---------------------------------------------------------------

test("discover finds a simple island and elements() returns its content", async () => {
  const { discover, elements, _reset } = await freshRegistry();
  const root = fakeRoot([comment("hy:i:A:lua"), element("BUTTON", "x"), comment("hy:/i:A")]);
  const b = discover(root, "A");
  assert.ok(b);
  assert.equal(b.kind, "island");
  assert.equal(elements("A").length, 1);
  assert.equal(elements("A")[0].tagName, "BUTTON");
});

test("sibling islands are found independently and do not interfere", async () => {
  const { discover, elements } = await freshRegistry();
  const root = fakeRoot([
    comment("hy:i:A:lua"), element("SPAN", "a"), comment("hy:/i:A"),
    comment("hy:i:B:js"), element("SPAN", "b"), comment("hy:/i:B"),
  ]);
  assert.ok(discover(root, "A"));
  assert.ok(discover(root, "B"));
  assert.equal(elements("A")[0].textContent, "a");
  assert.equal(elements("B")[0].textContent, "b");
});

test("nested islands: outer and inner are both discoverable from the same root", async () => {
  const { discover, elements } = await freshRegistry();
  const root = fakeRoot([
    comment("hy:i:OUTER:lua"),
    element("DIV", "wrapper"),
    comment("hy:i:INNER:js"), element("SPAN", "inner"), comment("hy:/i:INNER"),
    comment("hy:/i:OUTER"),
  ]);
  assert.ok(discover(root, "OUTER"));
  assert.ok(discover(root, "INNER"));
  assert.equal(elements("INNER")[0].textContent, "inner");
});

test("a text-only range is discovered but has zero elements", async () => {
  const { discover, elements } = await freshRegistry();
  const root = fakeRoot([comment("hy:i:T:lua"), text("just text"), comment("hy:/i:T")]);
  assert.ok(discover(root, "T"));
  assert.equal(elements("T").length, 0);
});

test("a multi-element range returns every element in order", async () => {
  const { discover, elements } = await freshRegistry();
  const root = fakeRoot([
    comment("hy:i:M:lua"),
    element("SPAN", "1"), element("SPAN", "2"), element("SPAN", "3"),
    comment("hy:/i:M"),
  ]);
  discover(root, "M");
  assert.equal(elements("M").length, 3);
});

test("a missing closing marker throws instead of silently returning a wrong range", async () => {
  const { discover } = await freshRegistry();
  const root = fakeRoot([comment("hy:i:BROKEN:lua"), element("SPAN", "x")]);
  assert.throws(() => discover(root, "BROKEN"), /no matching end marker/);
});

test("a duplicate start marker for the same id throws", async () => {
  const { discover } = await freshRegistry();
  const root = fakeRoot([
    comment("hy:i:DUP:lua"), element("SPAN", "1"),
    comment("hy:i:DUP:lua"), element("SPAN", "2"),
    comment("hy:/i:DUP"),
  ]);
  assert.throws(() => discover(root, "DUP"), /duplicate start marker/);
});

test("unknown ids answer safely across every query method (no throw, no false positive)", async () => {
  const { discover, elements, find, has, generation, isStale } = await freshRegistry();
  const root = fakeRoot([]);
  assert.equal(discover(root, "GHOST"), null);
  assert.deepEqual(elements("GHOST"), []);
  assert.equal(find("GHOST"), null);
  assert.equal(has("GHOST"), false);
  assert.equal(generation("GHOST"), -1);
  assert.equal(isStale("GHOST", 0), true, "unknown boundary must be treated as stale -- nothing safe to mutate");
});

test("claim/release: idempotent for the same owner, rejects a different owner, allows re-claim after release", async () => {
  const { discover, claim, release } = await freshRegistry();
  const root = fakeRoot([comment("hy:i:C:lua"), element("SPAN", "x"), comment("hy:/i:C")]);
  discover(root, "C");
  assert.equal(claim("C", "ownerA"), true);
  assert.equal(claim("C", "ownerA"), true, "re-claiming with the same owner must be idempotent");
  assert.throws(() => claim("C", "ownerB"), /already owned by "ownerA"/, "two owners must never both believe they hold the same boundary");
  assert.equal(release("C", "ownerB"), false, "release by the wrong owner is a no-op");
  assert.equal(release("C", "ownerA"), true);
  assert.equal(claim("C", "ownerB"), true, "claim must succeed for a new owner after release");
});

test("claiming an unknown boundary throws", async () => {
  const { claim } = await freshRegistry();
  assert.throws(() => claim("NOPE", "x"));
});

test("generations: advance and reject stale mutations, accept current ones", async () => {
  const { discover, generation, advanceGeneration, isStale } = await freshRegistry();
  const root = fakeRoot([comment("hy:i:G:lua"), element("SPAN", "x"), comment("hy:/i:G")]);
  discover(root, "G");
  assert.equal(generation("G"), 0);
  assert.equal(advanceGeneration("G"), 1);
  assert.equal(isStale("G", 1), false, "current generation must not be rejected");
  assert.equal(isStale("G", 0), true, "an older generation must be rejected");
  advanceGeneration("G");
  assert.equal(isStale("G", 1), true, "a now-superseded generation must be rejected");
});

test("dispose removes a boundary from the registry", async () => {
  const { discover, has, dispose } = await freshRegistry();
  const root = fakeRoot([comment("hy:i:D:lua"), element("SPAN", "x"), comment("hy:/i:D")]);
  discover(root, "D");
  assert.equal(has("D"), true);
  dispose("D");
  assert.equal(has("D"), false);
});

test("markFinalized on an unknown id is a safe no-op", async () => {
  const { markFinalized } = await freshRegistry();
  assert.doesNotThrow(() => markFinalized("GHOST"));
});

test("a 'root' boundary (d.lua.mount) uses the same marker mechanism with a different kind label", async () => {
  const { discover } = await freshRegistry();
  const root = fakeRoot([comment("hy:i:R:lua"), element("DIV", "app"), comment("hy:/i:R")]);
  const b = discover(root, "R", "root");
  assert.equal(b.kind, "root");
});

// Each test gets a fresh module instance (via a cache-busting query
// string) so registry state never leaks between tests -- avoids needing
// a beforeEach/_reset dance and matches how the module is actually used
// (one page, one registry, for the process's lifetime).
let counter = 0;
async function freshRegistry() {
  counter += 1;
  return import(`../../src/hydronium/client/boundary_registry.js?test=${counter}`);
}
