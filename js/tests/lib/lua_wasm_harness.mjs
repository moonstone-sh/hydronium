// Shared browser harness for the lua-wasm vs Wasmoon comparisons: serves
// dom-client's modules, the framework chunk built into
// examples/spa_hash_demo/dist, and a test app (plain Lua source) as an extra
// chunk, on a random loopback port. `?engine=wasmoon` selects the fallback
// provider; anything else uses the default (lua-wasm Bridge API 2).
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
export const dist = join(root, "examples/spa_hash_demo/dist");
export const distBuilt = existsSync(dist);
const client = join(root, "js/packages/dom-client/src");
const mime = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8", ".wasm": "application/wasm",
  ".lua": "text/plain; charset=utf-8", ".json": "application/json",
};

export function luaLongString(source) {
  let equals = "";
  while (source.includes(`]${equals}]`)) equals += "=";
  return `[${equals}[${source}]${equals}]`;
}

const page = (runtimeChunk) => `<!doctype html><html><head><meta charset="utf-8"></head><body><div id="app"></div>
<script type="module">
  import { mount } from "/js/bootstrap/mount.js";
  import { createWasmoonLua54Provider } from "/js/bootstrap/engine_provider.js";
  const engine = new URL(location.href).searchParams.get("engine");
  mount({
    chunkUrls: [${JSON.stringify(runtimeChunk)}, "/client/overrides.lua", "/client/app.lua"],
    appModuleId: "harness_app", container: "#app", hydrate: false,
    ...(engine === "wasmoon" ? { engineProvider: createWasmoonLua54Provider() } : {}),
  }).then((handle) => { window.__timings = handle.timings; window.__mounted = true; })
    .catch((e) => { window.__mountError = String((e && e.stack) || e); window.__mounted = true; });
</script></body></html>`;

/** Starts the harness server for `appSource` (a Lua module returning the root component). */
export async function startServer(appSource) {
  const runtime = (await readdir(join(dist, "client"))).find((name) => /^runtime-.*\.lua$/.test(name));
  assert.ok(runtime, "build examples/spa_hash_demo first (moon run build)");
  // The example's chunk comes from its installed packages; overlay the
  // current sources of the modules this harness relies on.
  const [hostSource, cssSource] = await Promise.all([
    readFile(join(root, "core/src/hydronium/runtime/hosts.lua"), "utf8"),
    readFile(join(root, "dom/src/hydronium_dom/css/init.lua"), "utf8"),
  ]);
  const overrides = [
    `package.preload["hydronium.runtime.hosts"] = assert(load(${luaLongString(hostSource)}, "@hydronium.runtime.hosts"))`,
    `package.preload["hydronium_dom.css.init"] = assert(load(${luaLongString(cssSource)}, "@hydronium_dom.css.init"))`,
  ].join("\n");
  const app = `package.preload["harness_app"] = assert(load(${luaLongString(appSource)}, "@harness_app"))`;
  const requests = [];
  const server = createServer(async (request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname;
    requests.push(pathname);
    if (pathname === "/") { response.writeHead(200, { "content-type": mime[".html"] }).end(page(`/client/${runtime}`)); return; }
    if (pathname === "/client/overrides.lua") { response.writeHead(200, { "content-type": mime[".lua"] }).end(overrides); return; }
    if (pathname === "/client/app.lua") { response.writeHead(200, { "content-type": mime[".lua"] }).end(app); return; }
    let base = dist, relative = pathname.slice(1);
    if (pathname.startsWith("/js/bootstrap/")) { base = client; relative = pathname.slice("/js/bootstrap/".length); }
    const resolved = join(base, normalize(relative));
    if (resolved !== base && !resolved.startsWith(base + sep)) { response.writeHead(400).end(); return; }
    // Read before writing headers: a missing file (Firefox asks for
    // /favicon.ico) must become a 404, not a second writeHead.
    let body;
    try { body = await readFile(resolved); } catch { response.writeHead(404).end("not found"); return; }
    response.writeHead(200, { "content-type": mime[extname(resolved)] ?? "application/octet-stream" }).end(body);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    requests,
    origin: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

/** Opens the harness page on `engine` ("api2" or "wasmoon") and waits for mount. */
export async function openApp(browser, origin, engine) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.goto(`${origin}/?engine=${engine}`);
  await page.waitForFunction(() => window.__mounted === true, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__mountError ?? null), null, `${engine}: mount failed`);
  return { page, errors };
}
