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
import * as playwright from "playwright";
// HYDRONIUM_BROWSER=firefox|webkit runs the same suite in another engine.
const chromium = playwright[process.env.HYDRONIUM_BROWSER || "chromium"];
import { distBuilt, startServer, openApp as openHarness } from "./lib/lua_wasm_harness.mjs";

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

async function openApp(browser, origin, engine) {
  const opened = await openHarness(browser, origin, engine);
  await opened.page.waitForSelector("#runs");
  return opened;
}

const runsAtLeast = (page, n) => page.waitForFunction((n) => {
  const text = document.querySelector("#runs")?.textContent ?? "";
  return Number(text.split(":")[1]) >= n;
}, n, { timeout: 10_000 });

if (!distBuilt) test("lua-wasm event semantics", { skip: "build examples/spa_hash_demo first" }, () => {});

for (const engine of ["api2", "wasmoon"]) {
  test(`${engine}: a Lua prevent_default() cancels a trusted click's default action`, { skip: !distBuilt }, async (t) => {
    const { origin, close } = await startServer(APP);
    const browser = await chromium.launch();
    t.after(async () => { await browser.close(); await close(); });
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

  test(`${engine}: a form submit runs its Lua handler without navigating`, { skip: !distBuilt }, async (t) => {
    const { origin, requests, close } = await startServer(APP);
    const browser = await chromium.launch();
    t.after(async () => { await browser.close(); await close(); });
    const { page, errors } = await openApp(browser, origin, engine);

    await page.click("#submit");
    await page.waitForFunction(() => document.querySelector("#submitted")?.textContent === "submitted:1", null, { timeout: 10_000 });
    await page.waitForTimeout(150);
    assert.equal(await page.evaluate(() => location.pathname), "/", "the native submission must be cancelled");
    assert.ok(!requests.includes("/submitted"), "the browser must not request the form action");
    assert.deepEqual(errors, []);
  });

  test(`${engine}: a synthetic dispatchEvent is cancelled by Lua before it returns`, { skip: !distBuilt }, async (t) => {
    const { origin, close } = await startServer(APP);
    const browser = await chromium.launch();
    t.after(async () => { await browser.close(); await close(); });
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
