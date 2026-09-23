// Unit tests for the @hydronium-js/vite plugin's config contribution.
//
// These call the plugin's `config()` hook directly rather than booting Vite:
// the hook is a pure function of the user's config, and the browser-level
// proof that its output is correct already exists in
// ../../examples/islands-tailwind/tests/ (the Tailwind/manifest gate and the
// dual-HMR gate). What is worth pinning down here is the exact shape it
// returns, because two of these fields fail SILENTLY and only in production.
//
// Run: node --test js/packages/vite/tests/plugin.test.mjs
// (requires `pnpm -C js/packages/vite build` first -- these import the
// compiled output, same as a consumer would.)

import test from "node:test";
import assert from "node:assert/strict";
import { hydronium, resolveIslandModule, manifestUrl } from "../dist/index.js";

const ROOT = new URL("./fixtures/", import.meta.url).pathname;

function configOf(options, userConfig = {}) {
  const plugin = hydronium(options);
  return plugin.config({ root: ROOT, ...userConfig });
}

test("enables the build manifest hydronium_ballad ingests", () => {
  assert.equal(configOf().build.manifest, true);
});

test("enables cross-origin dev serving for the Meteorite-served page", () => {
  // The page lives on Meteorite's origin; every island import is cross-origin.
  assert.equal(configOf().server.cors, true);
});

test("declares islands as real build inputs", () => {
  const input = configOf({ islands: ["src/widget.js"] }).build.rollupOptions.input;
  assert.equal(input["src/widget.js"], "src/widget.js");
});

test("preserves entry exports, or islands build to an empty file", () => {
  // Vite's app mode sets preserveEntrySignatures:false, so Rollup tree-shakes
  // an entry whose exports nothing imports -- which is every island, by
  // definition. The chunk is still emitted and still lands in the manifest,
  // so without this the failure reaches production as an island with no
  // `hydrate` export. Verified live: 0 bytes before, 533 bytes after.
  const opts = configOf({ islands: ["src/widget.js"] }).build.rollupOptions;
  assert.equal(opts.preserveEntrySignatures, "exports-only");
});

test("does not contribute rollup input when no islands are declared", () => {
  // Nothing to add and no index.html in the fixture dir: leave Vite's own
  // defaults completely alone rather than pinning an empty input map.
  assert.equal(configOf().build.rollupOptions, undefined);
});

test("merges with a user-supplied input instead of clobbering it", () => {
  const input = configOf(
    { islands: ["src/widget.js"] },
    { build: { rollupOptions: { input: { admin: "admin.html" } } } }
  ).build.rollupOptions.input;
  assert.equal(input.admin, "admin.html");
  assert.equal(input["src/widget.js"], "src/widget.js");
});

test("normalizes an array-shaped user input", () => {
  const input = configOf(
    { islands: ["src/widget.js"] },
    { build: { rollupOptions: { input: ["a.html", "b.html"] } } }
  ).build.rollupOptions.input;
  assert.equal(input["a.html"], "a.html");
  assert.equal(input["b.html"], "b.html");
  assert.equal(input["src/widget.js"], "src/widget.js");
});

test("resolveIslandModule builds an absolute dev URL", () => {
  // Absolute, not relative: the importing page is on another origin.
  assert.equal(
    resolveIslandModule("src/widget.js", { mode: "dev", origin: "http://localhost:5174/" }),
    "http://localhost:5174/src/widget.js"
  );
  assert.equal(
    resolveIslandModule("./src/widget.js", { mode: "dev", origin: "http://localhost:5174" }),
    "http://localhost:5174/src/widget.js"
  );
});

test("resolveIslandModule resolves through the build manifest in prod", () => {
  const manifest = { "src/widget.js": { file: "assets/widget-abc123.js" } };
  assert.equal(
    resolveIslandModule("src/widget.js", { mode: "prod", manifest }),
    "/assets/widget-abc123.js"
  );
});

test("resolveIslandModule names the likely cause when an island is missing", () => {
  // The overwhelmingly common reason is forgetting to declare it, so say so.
  assert.throws(
    () => resolveIslandModule("src/missing.js", { mode: "prod", manifest: {} }),
    /declare it in the plugin's `islands` option/
  );
});

test("manifestUrl returns null for an unknown source rather than guessing", () => {
  assert.equal(manifestUrl({}, "src/nope.js"), null);
});
