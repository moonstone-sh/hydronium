// M3 gate (docs/HYDRONIUM_SPA_MODE_PLAN.md): a real two-route static SPA,
// hash-routed, mounted with `hydrate: false`, served by a dumb static file
// server with NO Meteorite process at all -- gated in a real browser.
//
// It is also the M4 gate: the asset path. A static SPA has no SSR fallback,
// so a class that never matches or an asset URL that 404s is a blank page
// with nothing in any log -- both are asserted against the real build output
// below, including that the build-time and runtime scoped class AGREE.
//
// This test IS the static host: a plain node:http server on a free
// (OS-assigned) port, serving ONLY examples/spa_hash_demo/dist/ -- the
// real, complete build output, nothing supplemented from the source tree.
// This is the actual M4 deliverable (docs/HYDRONIUM_SPA_MODE_PLAN.md
// section 2.1: "One HTML shell, served by anything (`python -m
// http.server` is a valid host)"): dist/index.html references
// /js/bootstrap/mount.js and /js/router/hash_history.js as absolute site
// paths, and until hydronium_ballad.plugins.site's `mount.vendor` option
// (build/src/hydronium_ballad/plugins/site.lua) existed, NEITHER of those
// was actually in dist/ -- verified for real: `python3 -m http.server`
// rooted at dist/ 404'd on both before this, a blank page with nothing in
// any log, exactly the failure class this milestone exists to prevent.
// examples/spa_hash_demo/partiture.lua's `mount.vendor` now copies
// dom/src/hydronium_dom/client/ (the real, synced @hydronium-js/dom-client)
// to dist/js/bootstrap/ and router/client/ (a second, unpackaged pile --
// see the SPA plan's own hazard list for why that should eventually fold
// into dom-client; not done here) to dist/js/router/, so this server's
// ONE route (serve a file under dist/, or 404) is now sufficient:
//   /                 dist/index.html, unmodified
//   /client/*         dist/client/ (M2's real bundled chunk)
//   /js/bootstrap/*   dist/js/bootstrap/ (vendored by the build itself)
//   /js/router/*      dist/js/router/ (vendored by the build itself)
//   /assets/*         dist/assets/ (M4's real scoped CSS + hashed asset)
//   /hydronium-manifest.lua
//                     the build's own manifest, fetched by mount()'s
//                     `assetManifestUrl` and loaded INSIDE the Lua VM --
//                     wasmoon has no filesystem, so assets.configure()'s
//                     loadfile() cannot be used client-side
//
// PREREQUISITE (this test does not build it; it fails with a clear
// message if missing):
//   cd examples/spa_hash_demo && moon exec -- ballad play partiture.lua
//
// Run: node --test js/tests/spa_hash_demo.browser.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, extname, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "../..");
const DIST_DIR = join(REPO_ROOT, "examples/spa_hash_demo/dist");
const DIST_CLIENT_DIR = join(DIST_DIR, "client");

const MIME = {
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".lua": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".html": "text/html; charset=utf-8",
};

async function startServer() {
  const server = createServer(async (req, res) => {
    const url = req.url.split("?")[0];
    const urlPath = url === "/" ? "index.html" : url.replace(/^\/+/, "");
    // Refuses anything that would walk out of DIST_DIR (e.g. "../..") --
    // this is a test harness standing in for "any dumb static file
    // server", not a hardening exercise, but it must not silently serve
    // files OUTSIDE dist/ and make the gate meaningless.
    const resolved = join(DIST_DIR, normalize(urlPath));
    if (resolved !== DIST_DIR && !resolved.startsWith(DIST_DIR + sep)) {
      res.writeHead(400);
      res.end("bad path");
      return;
    }
    try {
      const body = await readFile(resolved);
      res.writeHead(200, { "content-type": MIME[extname(resolved)] || "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404);
      res.end("not found");
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server;
}

test("M3+M4: a real two-route hash-routed static SPA -- routing, scoped CSS and hashed assets -- no Meteorite process, gated in a real browser", async (t) => {
  if (!existsSync(DIST_CLIENT_DIR) || !existsSync(join(DIST_DIR, "index.html"))) {
    assert.fail(
      `${DIST_CLIENT_DIR} and/or ${join(DIST_DIR, "index.html")} do not exist.\nBuild it first:\n` +
      "  cd examples/spa_hash_demo && moon exec -- ballad play partiture.lua"
    );
  }
  const entries = await readdir(DIST_CLIENT_DIR);
  const chunkFile = entries.find((f) => /^runtime-.*\.lua$/.test(f));
  assert.ok(chunkFile, `no runtime-*.lua chunk found in ${DIST_CLIENT_DIR}; rebuild the partiture`);

  // M4 reads the build's OWN manifest rather than re-deriving names from a
  // readdir glob: the manifest is what a real app resolves URLs through, so
  // driving the page from it means a wrong manifest fails this test instead
  // of being papered over by a directory listing that happens to match.
  const manifest = JSON.parse(await readFile(join(DIST_DIR, "hydronium-manifest.json"), "utf8"));
  const styleUrl = manifest.styles && manifest.styles.url;
  const logoUrl = manifest.assets && manifest.assets["logo.svg"] && manifest.assets["logo.svg"].url;
  assert.ok(styleUrl, `manifest has no styles.url; rebuild the partiture`);
  assert.ok(logoUrl, `manifest has no assets["logo.svg"].url; rebuild the partiture`);
  assert.notEqual(logoUrl, "/logo.svg", "the manifest url must be the HASHED one, not the dev fallback");

  const server = await startServer();
  const { port } = server.address();
  const ORIGIN = `http://127.0.0.1:${port}`;

  const browser = await chromium.launch();
  const page = await browser.newPage();
  // The real dist/index.html has no boot-id script of its own (that would
  // be test-only scaffolding baked into a production shell) -- Playwright's
  // addInitScript runs before ANY of the page's own scripts, on every real
  // navigation including a hard reload, which is exactly what proving "no
  // full-page reload occurred" needs (js/examples/islands-tailwind/tests/
  // dual-hmr.test.mjs uses the same pattern for the same reason).
  await page.addInitScript(() => {
    window.__pageBootId = Math.random().toString(36).slice(2) + "-" + Date.now();
  });
  const pageErrors = [];
  page.on("pageerror", (e) => pageErrors.push(String(e)));
  const requestOrigins = new Set();
  page.on("request", (req) => {
    try {
      requestOrigins.add(new URL(req.url()).origin);
    } catch {
      /* non-http request (e.g. about:blank); ignore */
    }
  });

  t.after(async () => {
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
  });

  // --- initial route renders ---------------------------------------------
  await page.goto(ORIGIN + "/", { waitUntil: "networkidle" });
  await page.waitForFunction(() => window.__hydroniumMounted === true, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__hydroniumMountError ?? null), null, "mount() must not have errored");
  assert.equal((await page.textContent("#home-marker")).trim(), "This is the home route.");
  assert.equal(await page.locator("#second-screen").count(), 0, "second screen must not be present on /");

  // --- M4 gate: the asset path (docs/HYDRONIUM_SPA_MODE_PLAN.md) ----------
  //
  // A static SPA has no SSR fallback, so a class that never matches or an
  // asset URL that 404s is a blank or unstyled page with nothing in any log.
  // Both halves are checked against the REAL build output, not a literal:
  // the scoped class is derived independently at build time
  // (plugins.style.bundle) and at runtime (hydronium_dom.css.sheet), and
  // they have to land on the same string or the rule simply never applies.
  const homeClass = (await page.getAttribute("#home-screen", "class") || "").trim();
  assert.ok(homeClass, "#home-screen has no class at all -- css.sheet returned nothing");
  assert.notEqual(homeClass, "card", "the raw authored class leaked through unscoped");

  const sheetRes = await fetch(ORIGIN + styleUrl);
  assert.equal(sheetRes.status, 200, `the manifest's stylesheet url must serve: ${styleUrl}`);
  const sheetText = await sheetRes.text();
  assert.ok(
    sheetText.includes("." + homeClass),
    `build/runtime disagree on the scoped class: the component rendered ".${homeClass}", ` +
    `which the built stylesheet does not declare.\n--- ${styleUrl} ---\n${sheetText}`
  );

  // ...and the browser actually applies it. A value nothing else could
  // produce by accident, so this cannot be a default or a coincidence.
  const styled = await page.evaluate(() => {
    const cs = getComputedStyle(document.querySelector("#home-screen"));
    return { outlineColor: cs.outlineColor, padding: cs.padding };
  });
  assert.equal(styled.outlineColor, "rgb(7, 113, 199)", "the scoped rule did not apply");
  assert.equal(styled.padding, "11px");

  // The static asset: resolved through the real manifest inside the Lua VM
  // (mount's assetManifestUrl -> assets.configure_table), not by the shell.
  const logoSrc = await page.getAttribute("#logo", "src");
  assert.equal(logoSrc, logoUrl, "the component did not resolve the hashed asset url");
  const logoRes = await fetch(ORIGIN + logoUrl);
  assert.equal(logoRes.status, 200, `the hashed asset must serve: ${logoUrl}`);
  assert.equal(logoRes.headers.get("content-type"), "image/svg+xml");

  const bootId = await page.evaluate(() => window.__pageBootId);
  assert.ok(bootId, "page boot id should be set once at load");

  // --- clicking a link changes the hash and swaps the view, with NO real
  //     navigation (same boot id proves it) -------------------------------
  await page.click("#go-second");
  await page.waitForFunction(() => window.location.hash === "#/second", null, { timeout: 5000 });
  await page.waitForSelector("#second-screen", { timeout: 5000 });
  assert.equal((await page.textContent("#second-marker")).trim(), "This is the second route.");
  assert.equal(await page.locator("#home-screen").count(), 0, "home screen must be gone after navigating");
  assert.equal(await page.evaluate(() => window.__pageBootId), bootId, "clicking a link must not reload the page");

  // --- back/forward work --------------------------------------------------
  await page.goBack();
  await page.waitForSelector("#home-screen", { timeout: 5000 });
  assert.equal(await page.locator("#second-screen").count(), 0);
  assert.equal(await page.evaluate(() => window.__pageBootId), bootId, "back() must not reload the page");

  await page.goForward();
  await page.waitForSelector("#second-screen", { timeout: 5000 });
  assert.equal(await page.evaluate(() => window.location.hash), "#/second");
  assert.equal(await page.evaluate(() => window.__pageBootId), bootId, "forward() must not reload the page");

  // --- a hard reload at #/second lands on the second route, not the
  //     first -- the assertion that actually proves hash routing rather
  //     than a click handler that happens to also work -------------------
  await page.reload({ waitUntil: "networkidle" });
  await page.waitForFunction(() => window.__hydroniumMounted === true, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__hydroniumMountError ?? null), null, "mount() must not have errored on reload");
  assert.notEqual(
    await page.evaluate(() => window.__pageBootId), bootId,
    "a real reload MUST get a new boot id -- otherwise this isn't testing a real navigation"
  );
  assert.equal(await page.locator("#second-screen").count(), 1, "hard reload at #/second must land on the second route");
  assert.equal(await page.locator("#home-screen").count(), 0, "hard reload at #/second must NOT land on home");
  assert.equal((await page.textContent("#second-marker")).trim(), "This is the second route.");

  // --- zero requests to any origin beyond the static host -----------------
  assert.deepEqual([...requestOrigins], [ORIGIN], "every request must stay on the static host's own origin");

  assert.deepEqual(pageErrors, [], "uncaught page errors during the SPA hash-routing round trip");
});
