// M3 gate (docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md §4):
//
//   "a page with a d.js.island served entirely from the merged dist/ with NO
//    Vite process running, proven in Playwright; confirms zero runtime Vite
//    dependency in production."
//
// The chain under test: `vite build` emits a content-hashed island and a
// manifest -> hydronium_ballad.plugins.vite_assets re-emits those as ordinary
// hy_asset entries -> site.manifest (unmodified, and unaware Vite exists)
// merges them with the Lua chunk into one dist/ -> hydronium_dom.assets loads
// the merged hydronium-manifest.lua -> vite_module resolves the island's
// specifier to the hashed URL at SSR time -> Meteorite serves that file.
//
// PREREQUISITES (this test asserts them rather than starting anything):
//   pnpm -C js/examples/islands-tailwind exec vite build
//   cd examples/meteorite_ssr
//   moon run package                 # ballad: ingest + merge into dist/
//   moon run graph && moon exec --dev -- meteorite build --mode hybrid_dev --backend fast_http
//   ./dist/server                    # :8080 -- and NOTHING else
//
// Run: node --test js/examples/islands-tailwind/tests/prod-island.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { chromium } from "playwright";

const PAGE = "http://127.0.0.1:8080/prod-island";
const VITE_DEV_PORT = 5174;

test("a JS island hydrates from the merged dist/ with no Vite process running", async (t) => {
  try {
    const res = await fetch(PAGE);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  } catch (err) {
    assert.fail(
      `the Meteorite server is not serving ${PAGE} (${err.message}).\n` +
        "See this file's header for the build steps."
    );
  }

  // The whole point of M3: production must not depend on Vite at runtime. If a
  // dev server happens to be up, this gate proves nothing, so refuse to run.
  let viteUp = false;
  try {
    await fetch(`http://127.0.0.1:${VITE_DEV_PORT}/`, {
      signal: AbortSignal.timeout(1500),
    });
    viteUp = true;
  } catch {
    /* expected: nothing listening */
  }
  assert.equal(viteUp, false, `a Vite dev server is running on :${VITE_DEV_PORT} -- stop it; this gate is about production`);

  const browser = await chromium.launch();
  const page = await browser.newPage();
  const pageErrors = [];
  const requested = [];
  page.on("pageerror", (e) => pageErrors.push(String(e)));
  page.on("request", (r) => requested.push(r.url()));
  t.after(async () => browser.close());

  await page.goto(PAGE, { waitUntil: "networkidle" });

  // The island module must be the content-hashed build artifact, not a dev URL.
  const moduleUrl = await page.evaluate(() => {
    const tag = document.querySelector("#__HYDRONIUM_CLIENT_PLAN__");
    return JSON.parse(tag.textContent).islands[0].module;
  });
  assert.match(moduleUrl, /^\/assets\/.*dual-hmr-island\.js-[A-Za-z0-9_-]+\.js$/,
    `island module should be a hashed build URL, got ${moduleUrl}`);

  await page.waitForFunction(() => window.__jsIslandResult !== undefined, null, { timeout: 20_000 });
  assert.equal(await page.evaluate(() => window.__jsIslandError ?? null), null);
  assert.equal(await page.evaluate(() => window.__jsIslandResult.activatedJsIslands), 1);

  // Real hydration against the SSR'd markup, and a real click afterwards --
  // an island that loaded but exports nothing would render and then do
  // nothing, which is exactly the 0-byte-entry failure preserveEntrySignatures
  // exists to prevent.
  assert.equal((await page.textContent("#js-counter-btn")).trim(), "JS count: 7");
  await page.click("#js-counter-btn");
  await page.waitForFunction(
    () => document.querySelector("#js-counter-btn")?.textContent.trim() === "JS count: 8",
    null, { timeout: 10_000 });

  // Nothing on the page may have reached for Vite's origin.
  const viteRequests = requested.filter((u) => u.includes(`:${VITE_DEV_PORT}`));
  assert.deepEqual(viteRequests, [], "the production page requested something from Vite's dev origin");
  assert.deepEqual(pageErrors, [], "uncaught page errors on the production island page");
});
