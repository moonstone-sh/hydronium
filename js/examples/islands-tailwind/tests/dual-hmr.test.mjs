// M2 gate (docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md §4):
//
//   "a Playwright run where a JS island hydrates from a module served off
//    Vite's port, a click drives real state, editing that JS file HMR-patches
//    without reload, WHILE a co-located .luax component's Lua-side HMR is
//    undisturbed on the same page."
//
// This is the plan's own "single highest-value experiment": two independent,
// deliberately uncoordinated HMR systems -- hydronium.core.family_loader
// driving a Lua VM over SSE, and Vite's import.meta.hot over its own
// websocket -- updating disjoint halves of ONE real page without either
// reloading it.
//
// PREREQUISITES (this test does not start them; it asserts they are up and
// fails with a clear message if not):
//   1. examples/meteorite_ssr built and running:
//        moon run graph
//        moon exec --dev -- meteorite build --mode hybrid_dev --backend fast_http
//        ./dist/server                       # serves :8080
//   2. Vite dev serving this example on the port /dual-hmr's client_plan
//      names (5174 -- see vite_module.configure in meteorite_ssr/src/main.lua):
//        pnpm exec vite --port 5174 --strictPort --host 127.0.0.1
//
// Run: node --test js/examples/islands-tailwind/tests/dual-hmr.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "../../../..");
const LUA_ISLAND = join(REPO_ROOT, "examples/meteorite_ssr/dual_hmr/app.lua");
const JS_ISLAND = join(__dirname, "../src/dual-hmr-island.js");
const PAGE = "http://127.0.0.1:8080/dual-hmr";
const VITE = "http://127.0.0.1:5174/";

async function requireUp(url, what, hint) {
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  } catch (err) {
    assert.fail(`${what} is not reachable at ${url} (${err.message}).\nStart it with:\n  ${hint}`);
  }
}

test("Lua family_loader HMR and Vite JS HMR update one page, neither reloading it", async (t) => {
  await requireUp(PAGE, "the Meteorite server", "cd examples/meteorite_ssr && ./dist/server");
  await requireUp(VITE, "the Vite dev server",
    "cd js/examples/islands-tailwind && pnpm exec vite --port 5174 --strictPort --host 127.0.0.1");

  const luaBefore = readFileSync(LUA_ISLAND, "utf8");
  const jsBefore = readFileSync(JS_ISLAND, "utf8");
  assert.match(luaBefore, /Lua island \(real family_loader HMR\)/, "fixture assumption: Lua h3 label");
  assert.match(jsBefore, /JS count: \$\{count\}/, "fixture assumption: JS island label");

  const browser = await chromium.launch();
  const page = await browser.newPage();
  const pageErrors = [];
  page.on("pageerror", (e) => pageErrors.push(String(e)));

  t.after(async () => {
    writeFileSync(LUA_ISLAND, luaBefore);
    writeFileSync(JS_ISLAND, jsBefore);
    await browser.close();
  });

  await page.goto(PAGE, { waitUntil: "networkidle" });

  // --- both halves alive -------------------------------------------------
  await page.waitForFunction(() => window.__luaMounted === true, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__luaMountError ?? null), null, "Lua VM mount error");
  assert.equal(await page.evaluate(() => window.__jsIslandError ?? null), null, "JS island activation error");

  assert.equal((await page.textContent("#lua-counter-btn")).trim(), "Lua count: 5");
  assert.equal((await page.textContent("#js-counter-btn")).trim(), "JS count: 7");

  const bootId = await page.evaluate(() => window.__pageBootId);
  assert.ok(bootId, "page boot id should be set once at load");

  // --- drive real state, so the Lua swap has something to preserve -------
  await page.click("#lua-counter-btn");
  await page.waitForFunction(
    () => document.querySelector("#lua-counter-btn")?.textContent.trim() === "Lua count: 6",
    null, { timeout: 10_000 });

  // --- edit the LUA island: family_loader should hot-swap the render -----
  writeFileSync(LUA_ISLAND, luaBefore.replace("Lua island (real family_loader HMR)", "Lua isle (hot-swapped)"));
  await page.waitForFunction(
    () => document.querySelector("#lua-card h3")?.textContent.includes("Lua isle (hot-swapped)"),
    null, { timeout: 30_000 });

  // The signal lives OUTSIDE the replaced render closure, so the click above
  // must survive the swap. This is the whole point of family_loader HMR over
  // a reload, and the assertion that would catch a silent full remount.
  assert.equal((await page.textContent("#lua-counter-btn")).trim(), "Lua count: 6",
    "Lua state did not survive the hot swap -- this was a remount, not an HMR patch");
  assert.equal(await page.evaluate(() => window.__pageBootId), bootId,
    "page reloaded during the Lua hot swap");

  // --- edit the JS island: Vite should patch it, Lua side undisturbed ----
  writeFileSync(JS_ISLAND, jsBefore.replace(/JS count: \$\{count\}/g, "JS clicks: ${count}"));
  await page.waitForFunction(
    () => document.querySelector("#js-counter-btn")?.textContent.startsWith("JS clicks:"),
    null, { timeout: 30_000 });

  assert.equal(await page.evaluate(() => window.__pageBootId), bootId,
    "page reloaded during the JS hot swap");

  // The Lua half must be untouched by a Vite update -- that is what
  // "deliberately uncoordinated" has to mean in practice.
  assert.equal((await page.textContent("#lua-counter-btn")).trim(), "Lua count: 6",
    "the Vite update disturbed the Lua island's state");
  assert.ok((await page.textContent("#lua-card h3")).includes("Lua isle (hot-swapped)"),
    "the Vite update reverted the Lua island's hot-swapped render");

  // --- both halves still interactive after their respective swaps --------
  await page.click("#lua-counter-btn");
  await page.waitForFunction(
    () => document.querySelector("#lua-counter-btn")?.textContent.trim() === "Lua count: 7",
    null, { timeout: 10_000 });
  await page.click("#js-counter-btn");
  await page.waitForFunction(
    () => document.querySelector("#js-counter-btn")?.textContent.trim() === "JS clicks: 8",
    null, { timeout: 10_000 });

  assert.deepEqual(pageErrors, [], "uncaught page errors during the dual HMR round trip");
});
