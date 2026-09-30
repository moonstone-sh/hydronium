// Event default-action semantics on the default lua-wasm (Bridge API 2)
// engine, run side by side with the Wasmoon fallback so every difference is
// explicit. On an idle engine lua-wasm runs a Lua callback, and the
// plain-valued host calls it makes, synchronously inside the DOM listener, so
// a Lua `prevent_default()` cancels trusted and synthetic events alike (see
// lua-wasm/STATUS.md, follow-up 1).
//
// Needs examples/spa_hash_demo built (`moon run build` there): its client
// chunk supplies the framework modules; the test app is served as an extra
// chunk.
import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const dist = join(root, "examples/spa_hash_demo/dist");
const client = join(root, "js/packages/dom-client/src");
const mime = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8", ".wasm": "application/wasm",
  ".lua": "text/plain; charset=utf-8", ".json": "application/json",
};
const luaLongString = (source) => {
  let equals = "";
  while (source.includes(`]${equals}]`)) equals += "=";
  return `[${equals}[${source}]${equals}]`;
};

// The app under test. Every handler bumps a counter so the test can wait for
// Lua to have actually run before judging the default action.
const APP = `
local H = require("hydronium")
local signals = require("hydronium.signals")
local d = require("hydronium_dom").d
local hosts = require("hydronium.runtime.hosts")
local function cancel() hosts.require("dom", 1).prevent_default() end

return function()
  local runs, set_runs = signals.createSignal(0)
  local submitted, set_submitted = signals.createSignal(0)
  local bump = function() set_runs(runs() + 1) end
  return function()
    return d.div({ id = "events" },
      d.p({ id = "runs" }, "runs:" .. tostring(runs())),
      d.p({ id = "submitted" }, "submitted:" .. tostring(submitted())),
      d.input({ id = "cb-prevent", type = "checkbox", onClick = function() cancel(); bump() end }),
      d.input({ id = "cb-plain", type = "checkbox", onClick = function() bump() end }),
      d.a({ id = "link-prevent", href = "#/elsewhere", onClick = function() cancel(); bump() end }, "prevented link"),
      d.form({ id = "form", action = "/submitted", method = "get",
          onSubmit = function() set_submitted(submitted() + 1) end },
        d.input({ name = "q", value = "x" }),
        d.button({ id = "submit", type = "submit" }, "send"))
    )
  end
end
`;

const PAGE = `<!doctype html><html><head><meta charset="utf-8"></head><body><div id="app"></div>
<script type="module">
  import { mount } from "/js/bootstrap/mount.js";
  import { createWasmoonLua54Provider } from "/js/bootstrap/engine_provider.js";
  const engine = new URL(location.href).searchParams.get("engine");
  mount({
    chunkUrls: [window.__RUNTIME_CHUNK__, "/client/overrides.lua", "/client/events_app.lua"],
    appModuleId: "events_app", container: "#app", hydrate: false,
    ...(engine === "wasmoon" ? { engineProvider: createWasmoonLua54Provider() } : {}),
  }).then(() => { window.__mounted = true; })
    .catch((e) => { window.__mountError = String((e && e.stack) || e); window.__mounted = true; });
</script></body></html>`;

async function startServer() {
  const runtime = (await readdir(join(dist, "client"))).find((name) => /^runtime-.*\.lua$/.test(name));
  assert.ok(runtime, "build examples/spa_hash_demo first (moon run build)");
  const [hostSource, cssSource] = await Promise.all([
    readFile(join(root, "core/src/hydronium/runtime/hosts.lua"), "utf8"),
    readFile(join(root, "dom/src/hydronium_dom/css/init.lua"), "utf8"),
  ]);
  const overrides = [
    `package.preload["hydronium.runtime.hosts"] = assert(load(${luaLongString(hostSource)}, "@hydronium.runtime.hosts"))`,
    `package.preload["hydronium_dom.css.init"] = assert(load(${luaLongString(cssSource)}, "@hydronium_dom.css.init"))`,
    `package.preload["events_app"] = assert(load(${luaLongString(APP)}, "@events_app"))`,
  ];
  const requests = [];
  const server = createServer(async (request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname;
    requests.push(pathname);
    if (pathname === "/") {
      response.writeHead(200, { "content-type": mime[".html"] })
        .end(PAGE.replace("window.__RUNTIME_CHUNK__", JSON.stringify(`/client/${runtime}`)));
      return;
    }
    if (pathname === "/client/overrides.lua") { response.writeHead(200, { "content-type": mime[".lua"] }).end(overrides.slice(0, 2).join("\n")); return; }
    if (pathname === "/client/events_app.lua") { response.writeHead(200, { "content-type": mime[".lua"] }).end(overrides[2]); return; }
    let base = dist, relative = pathname.slice(1);
    if (pathname.startsWith("/js/bootstrap/")) { base = client; relative = pathname.slice("/js/bootstrap/".length); }
    const resolved = join(base, normalize(relative));
    if (resolved !== base && !resolved.startsWith(base + sep)) { response.writeHead(400).end(); return; }
    try {
      response.writeHead(200, { "content-type": mime[extname(resolved)] ?? "application/octet-stream" }).end(await readFile(resolved));
    } catch { response.writeHead(404).end("not found"); }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, requests, origin: `http://127.0.0.1:${server.address().port}` };
}

async function openApp(browser, origin, engine) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.goto(`${origin}/?engine=${engine}`);
  await page.waitForFunction(() => window.__mounted === true, null, { timeout: 30_000 });
  assert.equal(await page.evaluate(() => window.__mountError ?? null), null, `${engine}: mount failed`);
  await page.waitForSelector("#runs");
  return { page, errors };
}

const runsAtLeast = (page, n) => page.waitForFunction((n) => {
  const text = document.querySelector("#runs")?.textContent ?? "";
  return Number(text.split(":")[1]) >= n;
}, n, { timeout: 10_000 });

if (!existsSync(dist)) test("lua-wasm event semantics", { skip: "build examples/spa_hash_demo first" }, () => {});

for (const engine of ["api2", "wasmoon"]) {
  test(`${engine}: a Lua prevent_default() cancels a trusted click's default action`, { skip: !existsSync(dist) }, async (t) => {
    const { server, origin } = await startServer();
    const browser = await chromium.launch();
    t.after(async () => { await browser.close(); await new Promise((r) => server.close(r)); });
    const { page, errors } = await openApp(browser, origin, engine);

    await page.click("#cb-plain");
    await runsAtLeast(page, 1);
    assert.equal(await page.isChecked("#cb-plain"), true, "control: an unprevented checkbox toggles");

    await page.click("#cb-prevent");
    await runsAtLeast(page, 2);
    assert.equal(await page.isChecked("#cb-prevent"), false, "Lua prevent_default() must keep the checkbox unchecked");

    await page.click("#link-prevent");
    await runsAtLeast(page, 3);
    await page.waitForTimeout(150);
    assert.equal(await page.evaluate(() => location.hash), "", "Lua prevent_default() must stop the link's navigation");
    assert.deepEqual(errors, []);
  });

  test(`${engine}: a form submit runs its Lua handler without navigating`, { skip: !existsSync(dist) }, async (t) => {
    const { server, origin, requests } = await startServer();
    const browser = await chromium.launch();
    t.after(async () => { await browser.close(); await new Promise((r) => server.close(r)); });
    const { page, errors } = await openApp(browser, origin, engine);

    await page.click("#submit");
    await page.waitForFunction(() => document.querySelector("#submitted")?.textContent === "submitted:1", null, { timeout: 10_000 });
    await page.waitForTimeout(150);
    assert.equal(await page.evaluate(() => location.pathname), "/", "the native submission must be cancelled");
    assert.ok(!requests.includes("/submitted"), "the browser must not request the form action");
    assert.deepEqual(errors, []);
  });

  test(`${engine}: a synthetic dispatchEvent is cancelled by Lua before it returns`, { skip: !existsSync(dist) }, async (t) => {
    const { server, origin } = await startServer();
    const browser = await chromium.launch();
    t.after(async () => { await browser.close(); await new Promise((r) => server.close(r)); });
    const { page } = await openApp(browser, origin, engine);

    const notCancelled = await page.evaluate(() =>
      document.querySelector("#cb-prevent").dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true })));
    await runsAtLeast(page, 1);
    const checked = await page.isChecked("#cb-prevent");
    // lua-wasm runs an idle engine's callback synchronously (its "synchronous
    // entry"), so el.click()/dispatchEvent/testing-library fireEvent see the
    // cancellation exactly as with Wasmoon.
    assert.equal(notCancelled, false, "dispatchEvent must report the Lua cancellation");
    assert.equal(checked, false, "the synthetic click's default action must not apply");
  });
}
