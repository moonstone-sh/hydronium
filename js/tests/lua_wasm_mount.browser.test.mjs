import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const dist = join(root, "examples/spa_hash_demo/dist");
const client = join(root, "js/packages/dom-client/src");
const router = join(root, "router/client");
const hostsSource = join(root, "core/src/hydronium/runtime/hosts.lua");
const cssSource = join(root, "dom/src/hydronium_dom/css/init.lua");
const mime = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8", ".wasm": "application/wasm",
  ".lua": "text/plain; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml", ".json": "application/json",
};
function luaLongString(source) {
  let equals = "";
  while (source.includes(`]${equals}]`)) equals += "=";
  return `[${equals}[${source}]${equals}]`;
}

test("Hydronium mount and hash routing run on the default Bridge API 2 provider", async (t) => {
  assert.ok(existsSync(join(dist, "index.html")) && existsSync(join(dist, "client")),
    "build examples/spa_hash_demo first with moon run build");
  const server = createServer(async (request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname;
    if (pathname === "/client/api2-runtime-overrides.lua") {
      const [hostSource, currentCss] = await Promise.all([
        readFile(hostsSource, "utf8"), readFile(cssSource, "utf8"),
      ]);
      const body = [
        `package.preload["hydronium.runtime.hosts"] = assert(load(${luaLongString(hostSource)}, "@hydronium.runtime.hosts"))`,
        `package.preload["hydronium_dom.css.init"] = assert(load(${luaLongString(currentCss)}, "@hydronium_dom.css.init"))`,
        `package.preload["hydronium_dom.css"] = function() return require("hydronium_dom.css.init") end`,
      ].join("\n");
      response.writeHead(200, { "content-type": mime[".lua"] }).end(body);
      return;
    }
    let base = dist, relative = pathname === "/" ? "index.html" : pathname.slice(1);
    if (pathname.startsWith("/js/bootstrap/")) { base = client; relative = pathname.slice("/js/bootstrap/".length); }
    else if (pathname.startsWith("/js/router/")) { base = router; relative = pathname.slice("/js/router/".length); }
    const resolved = join(base, normalize(relative));
    if (resolved !== base && !resolved.startsWith(base + sep)) { response.writeHead(400).end(); return; }
    try {
      let body = await readFile(resolved);
      if (pathname === "/") {
        body = Buffer.from(body.toString("utf8").replace(/chunkUrls:\s*\[([^\]]+)\]/,
          (_, urls) => `chunkUrls: [${urls}, "/client/api2-runtime-overrides.lua"]`));
      }
      response.writeHead(200, { "content-type": mime[extname(resolved)] ?? "application/octet-stream" }).end(body);
    } catch { response.writeHead(404).end("not found"); }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const pageErrors = [], requested = [];
  page.on("pageerror", (error) => pageErrors.push(String(error)));
  page.on("request", (request) => requested.push(new URL(request.url()).pathname));
  await page.addInitScript(() => { window.__pageBootId = crypto.randomUUID(); });
  t.after(async () => { await browser.close(); await new Promise((resolve) => server.close(resolve)); });

  await page.goto(`${origin}/`, { waitUntil: "networkidle" });
  await page.waitForFunction(() => window.__hydroniumMounted === true, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__hydroniumMountError ?? null), null);
  assert.equal((await page.textContent("#home-marker")).trim(), "This is the home route.");
  assert.ok(requested.includes("/js/bootstrap/vendor/lua-wasm/5.4.9/engine.js"));
  assert.ok(requested.includes("/js/bootstrap/vendor/lua-wasm/5.4.9/engine.wasm"));
  assert.ok(requested.includes("/js/bootstrap/vendor/lua-wasm/5.4.9/task-runtime.mjs"));
  assert.ok(!requested.some((path) => path.includes("vendor/wasmoon")), "default boot must not request Wasmoon");

  const bootId = await page.evaluate(() => window.__pageBootId);
  await page.click("#go-second");
  await page.waitForFunction(() => window.location.hash === "#/second");
  await page.waitForSelector("#second-screen");
  assert.equal((await page.textContent("#second-marker")).trim(), "This is the second route.");
  assert.equal(await page.evaluate(() => window.__pageBootId), bootId, "client route changes must not reload the page");
  assert.deepEqual(pageErrors, []);
});
