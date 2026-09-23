// M3 gate (docs/HYDRONIUM_SPA_MODE_PLAN.md): a real two-route static SPA,
// hash-routed, mounted with `hydrate: false`, served by a dumb static file
// server with NO Meteorite process at all -- gated in a real browser.
//
// This test IS the static host: a plain node:http server on a free
// (OS-assigned) port, serving four things straight off disk, none of them
// copies:
//   /                 a generated index.html shell (the only thing not
//                     read from disk -- a static SPA's shell has no
//                     server-side templating to do)
//   /client/*         examples/spa_hash_demo/dist/client/ (M2's real
//                     bundled chunk -- build it first: see prerequisite
//                     below)
//   /js/bootstrap/*   dom/src/hydronium_dom/client/ (the real, synced
//                     @hydronium/dom-client: mount.js + vendored wasmoon)
//   /js/router/*      router/client/ (hash_history.js, the real M1 bridge)
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
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "../..");
const DIST_CLIENT_DIR = join(REPO_ROOT, "examples/spa_hash_demo/dist/client");
const BOOTSTRAP_DIR = join(REPO_ROOT, "dom/src/hydronium_dom/client");
const ROUTER_CLIENT_DIR = join(REPO_ROOT, "router/client");

const MIME = {
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".lua": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
  ".html": "text/html; charset=utf-8",
};

function indexHtml(chunkFile) {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>Hydronium SPA hash demo (static, no Meteorite)</title></head>
<body>
<div id="app"></div>
<script>
  // Set once, synchronously, before mount.js ever runs -- the same
  // boot-id pattern js/examples/islands-tailwind/tests/dual-hmr.test.mjs
  // uses to prove a client-side route change did NOT reload the page.
  window.__pageBootId = Math.random().toString(36).slice(2) + "-" + Date.now();
</script>
<script type="module">
  import { mount } from "/js/bootstrap/mount.js";
  import { createHashHistoryGlobals } from "/js/router/hash_history.js";

  mount({
    chunkUrls: ["/client/${chunkFile}"],
    appModuleId: "app",
    container: "#app",
    hydrate: false,
    luaGlobals: createHashHistoryGlobals(),
  }).then(() => { window.__mounted = true; })
    .catch((e) => {
      window.__mountError = String((e && e.stack) || e);
      window.__mounted = true;
      console.error(e);
    });
</script>
</body></html>`;
}

async function serveFrom(root, urlPath, res) {
  try {
    const body = await readFile(join(root, urlPath));
    res.writeHead(200, { "content-type": MIME[extname(urlPath)] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
}

async function startServer(chunkFile) {
  const server = createServer(async (req, res) => {
    const url = req.url.split("?")[0];
    if (url === "/") {
      res.writeHead(200, { "content-type": MIME[".html"] });
      res.end(indexHtml(chunkFile));
      return;
    }
    if (url.startsWith("/client/")) {
      await serveFrom(DIST_CLIENT_DIR, url.slice("/client/".length), res);
      return;
    }
    if (url.startsWith("/js/bootstrap/")) {
      await serveFrom(BOOTSTRAP_DIR, url.slice("/js/bootstrap/".length), res);
      return;
    }
    if (url.startsWith("/js/router/")) {
      await serveFrom(ROUTER_CLIENT_DIR, url.slice("/js/router/".length), res);
      return;
    }
    res.writeHead(404);
    res.end("not found");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server;
}

test("M3: a real two-route hash-routed static SPA, no Meteorite process, gated in a real browser", async (t) => {
  if (!existsSync(DIST_CLIENT_DIR)) {
    assert.fail(
      `${DIST_CLIENT_DIR} does not exist.\nBuild it first:\n` +
      "  cd examples/spa_hash_demo && moon exec -- ballad play partiture.lua"
    );
  }
  const entries = await readdir(DIST_CLIENT_DIR);
  const chunkFile = entries.find((f) => /^runtime-.*\.lua$/.test(f));
  assert.ok(chunkFile, `no runtime-*.lua chunk found in ${DIST_CLIENT_DIR}; rebuild the partiture`);

  const server = await startServer(chunkFile);
  const { port } = server.address();
  const ORIGIN = `http://127.0.0.1:${port}`;

  const browser = await chromium.launch();
  const page = await browser.newPage();
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
  await page.waitForFunction(() => window.__mounted === true, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__mountError ?? null), null, "mount() must not have errored");
  assert.equal((await page.textContent("#home-marker")).trim(), "This is the home route.");
  assert.equal(await page.locator("#second-screen").count(), 0, "second screen must not be present on /");

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
  await page.waitForFunction(() => window.__mounted === true, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__mountError ?? null), null, "mount() must not have errored on reload");
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
