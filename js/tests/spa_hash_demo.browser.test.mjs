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
// (OS-assigned) port, serving these straight off disk, none of them
// copies:
//   /                 a generated index.html shell (the only thing not
//                     read from disk -- a static SPA's shell has no
//                     server-side templating to do)
//   /client/*         examples/spa_hash_demo/dist/client/ (M2's real
//                     bundled chunk -- build it first: see prerequisite
//                     below)
//   /js/bootstrap/*   dom/src/hydronium_dom/client/ (the real, synced
//                     @hydronium-js/dom-client: mount.js + vendored wasmoon)
//   /js/router/*      router/client/ (hash_history.js, the real M1 bridge)
//   /assets/*         examples/spa_hash_demo/dist/assets/ (M4's real
//                     scoped CSS bundle and content-hashed static file)
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
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "../..");
const DIST_CLIENT_DIR = join(REPO_ROOT, "examples/spa_hash_demo/dist/client");
const BOOTSTRAP_DIR = join(REPO_ROOT, "dom/src/hydronium_dom/client");
const ROUTER_CLIENT_DIR = join(REPO_ROOT, "router/client");
// M4: the real built asset output -- the scoped CSS bundle and the
// content-hashed static file, both produced by the plugins under test.
const DIST_DIR = join(REPO_ROOT, "examples/spa_hash_demo/dist");
const DIST_ASSETS_DIR = join(DIST_DIR, "assets");

const MIME = {
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".lua": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".html": "text/html; charset=utf-8",
};

function indexHtml(chunkFile, styleUrl) {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>Hydronium SPA hash demo (static, no Meteorite)</title></head>
<body>
<link rel="stylesheet" href="${styleUrl}">
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
    assetManifestUrl: "/hydronium-manifest.lua",
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

async function startServer(chunkFile, styleUrl) {
  const server = createServer(async (req, res) => {
    const url = req.url.split("?")[0];
    if (url === "/") {
      res.writeHead(200, { "content-type": MIME[".html"] });
      res.end(indexHtml(chunkFile, styleUrl));
      return;
    }
    if (url.startsWith("/assets/")) {
      await serveFrom(DIST_ASSETS_DIR, url.slice("/assets/".length), res);
      return;
    }
    if (url === "/hydronium-manifest.lua") {
      await serveFrom(DIST_DIR, "hydronium-manifest.lua", res);
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

test("M3+M4: a real two-route hash-routed static SPA -- routing, scoped CSS and hashed assets -- no Meteorite process, gated in a real browser", async (t) => {
  if (!existsSync(DIST_CLIENT_DIR)) {
    assert.fail(
      `${DIST_CLIENT_DIR} does not exist.\nBuild it first:\n` +
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

  const server = await startServer(chunkFile, styleUrl);
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
