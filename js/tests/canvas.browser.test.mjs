// hydronium_dom.canvas end to end in a real browser: the default lua-wasm
// engine, the real canvas@1 capability (canvas_bridge.js) and the real Lua
// modules draw on a <canvas>; the test reads the pixels back from JS.
import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import * as playwright from "playwright";
const browserType = playwright[process.env.HYDRONIUM_BROWSER || "chromium"];

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const client = join(root, "js/packages/dom-client/src");
const modules = {
  "hydronium.runtime.hosts": "core/src/hydronium/runtime/hosts.lua",
  "hydronium.core.symbols": "core/src/hydronium/core/symbols.lua",
  "hydronium.core.errors": "core/src/hydronium/core/errors.lua",
  "hydronium.core.scope": "core/src/hydronium/core/scope.lua",
  "hydronium_dom.canvas": "dom/src/hydronium_dom/canvas.lua",
};
const mime = { ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".lua": "text/plain" };

const PAGE = `<!doctype html><meta charset="utf-8"><canvas width="64" height="16"></canvas>
<script type="module">
  import { createHydroniumLua54Provider } from "/js/bootstrap/engine_provider.js";
  import { installHostCapability } from "/js/bootstrap/host_capabilities.js";
  import { createCanvasBridge } from "/js/bootstrap/canvas_bridge.js";
  try {
    const lua = await createHydroniumLua54Provider().create();
    for (const [id, path] of Object.entries(${JSON.stringify(modules)})) {
      lua.global.set("__src", await (await fetch("/lua/" + path)).text());
      await lua.doString('package.preload["' + id + '"] = assert(load(__src, "@' + id + '"))');
    }
    await installHostCapability(lua, { name: "canvas", version: 1, bindings: createCanvasBridge() });
    window.__report = {};
    lua.global.set("__report", (key, value) => { window.__report[key] = value; });
    lua.global.set("__canvas_el", document.querySelector("canvas"));
    await lua.doString(\`
      local canvas = require("hydronium_dom.canvas")
      local ref = { current = __canvas_el }            -- what H.createRef() holds after mount
      local ctx = canvas.context(ref)
      __report("available", canvas.available())
      ctx.fillStyle = "rgb(255, 0, 0)"
      ctx:fillRect(0, 0, 10, 10)
      ctx.fillStyle = "#00ff00"
      ctx:fill(canvas.path("M20 0 L30 0 L30 10 L20 10 Z"))
      ctx:putImageData(canvas.image_data({ 0, 0, 255, 255, 0, 0, 255, 255 }, 2), 40, 0)
      local px = ctx:getImageData(0, 0, 1, 1)
      __report("lua_red", px.data[0])
      __report("lua_len", #px.data)
      __report("measure", ctx:measureText("hello").width > 0)
      local frames = 0
      canvas.frame(function(t, dt)
        frames = frames + 1
        __report("frames", frames)
        return frames < 3
      end)
    \`);
    window.__ready = true;
  } catch (error) { window.__error = String(error && error.stack || error); }
</script>`;

test("hydronium_dom.canvas draws through canvas@1 in a real browser", async (t) => {
  const server = createServer(async (request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname;
    if (pathname === "/") return response.writeHead(200, { "content-type": "text/html" }).end(PAGE);
    let base, relative;
    if (pathname.startsWith("/js/bootstrap/")) { base = client; relative = pathname.slice(14); }
    else if (pathname.startsWith("/lua/")) { base = root; relative = pathname.slice(5); }
    else return response.writeHead(404).end();
    const file = join(base, normalize(relative));
    if (!file.startsWith(base + sep)) return response.writeHead(400).end();
    try { response.writeHead(200, { "content-type": mime[extname(file)] ?? "application/octet-stream" }).end(await readFile(file)); }
    catch { response.writeHead(404).end(); }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const browser = await browserType.launch();
  t.after(async () => { await browser.close(); await new Promise((resolve) => server.close(resolve)); });
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.waitForFunction(() => window.__ready || window.__error, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__error ?? null), null);

  const pixel = (x, y) => page.evaluate(([x, y]) => [...document.querySelector("canvas").getContext("2d").getImageData(x, y, 1, 1).data], [x, y]);
  assert.deepEqual(await pixel(5, 5), [255, 0, 0, 255], "fillRect");
  assert.deepEqual(await pixel(25, 5), [0, 255, 0, 255], "fill(Path2D) from canvas.path");
  assert.deepEqual(await pixel(41, 0), [0, 0, 255, 255], "putImageData from a Lua byte array");

  await page.waitForFunction(() => window.__report.frames === 3, null, { timeout: 10_000 });
  await page.waitForTimeout(300);
  const report = await page.evaluate(() => window.__report);
  assert.equal(report.available, true);
  assert.equal(report.lua_red, 255, "Lua reads pixel bytes from 0 (Uint8ClampedArray host reference)");
  assert.equal(report.lua_len, 4);
  assert.equal(report.measure, true);
  assert.equal(report.frames, 3, "the frame loop stops when the callback returns false");
});
