// Form controls in a real browser, on both Lua engines: handlers read the
// event (e.value, e.checked, e.key), a signal-bound value writes what the
// control shows, and re-rendering with an unchanged value keeps what the user
// typed (the dom 0.3.10 regression, which only bridge unit tests covered).
//
// Needs examples/spa_hash_demo built (`moon run build` there), like the other
// lua_wasm harness tests.
import test from "node:test";
import assert from "node:assert/strict";
import * as playwright from "playwright";
const chromium = playwright[process.env.HYDRONIUM_BROWSER || "chromium"];
import { distBuilt, startServer, openApp } from "./lib/lua_wasm_harness.mjs";

const APP = `
local H = require("hydronium")
local signals = require("hydronium.signals")
local d = require("hydronium_dom").d

return function()
  local name, setName = signals.createSignal("")
  local loud, setLoud = signals.createSignal(false)
  local said, setSaid = signals.createSignal("")
  local ticks, setTicks = signals.createSignal(0)
  return function()
    local _ = ticks() -- re-render the whole component on Tick
    return d.div({ id = "form" },
      d.input({ id = "name", value = name, onInput = function(e) setName(e.value) end,
        onKeyDown = function(e) if e.key == "Enter" then setSaid(name()) end end }),
      d.input({ id = "static", value = "3" }),
      d.input({ id = "loud", type = "checkbox", checked = loud, onChange = function(e) setLoud(e.checked) end }),
      d.p({ id = "out" }, function() return (loud() and name():upper() or name()) .. "|" .. said() end),
      d.button({ id = "clear", onClick = function() setName("") end }, "Clear"),
      d.button({ id = "tick", onClick = function() setTicks(ticks() + 1) end }, "Tick"))
  end
end
`;

if (!distBuilt) test("form controls", { skip: "build examples/spa_hash_demo first" }, () => {});

for (const engine of ["api2", "wasmoon"]) {
  test(`${engine}: handlers read the event and bound values drive what controls show`, { skip: !distBuilt }, async (t) => {
    const { origin, close } = await startServer(APP);
    const browser = await chromium.launch();
    t.after(async () => { await browser.close(); await close(); });
    const { page, errors } = await openApp(browser, origin, engine);
    await page.waitForSelector("#out");
    const out = () => page.textContent("#out");

    await page.fill("#name", "");
    await page.type("#name", "ada", { delay: 20 });
    await page.waitForFunction(() => document.querySelector("#out").textContent === "ada|");
    await page.press("#name", "Enter");
    await page.waitForFunction(() => document.querySelector("#out").textContent === "ada|ada");

    await page.click("#loud");
    await page.waitForFunction(() => document.querySelector("#out").textContent === "ADA|ada");
    assert.equal(await page.isChecked("#loud"), true);

    // Clear writes the signal; the bound value empties the field the user typed in.
    await page.click("#clear");
    await page.waitForFunction(() => document.querySelector("#out").textContent === "|ada");
    assert.equal(await page.inputValue("#name"), "");

    // A static value="3": what the user types survives a re-render.
    await page.fill("#static", "42");
    await page.click("#tick");
    await page.click("#tick");
    await page.waitForTimeout(150);
    assert.equal(await page.inputValue("#static"), "42");
    assert.equal(await out(), "|ada");
    assert.deepEqual(errors, []);
  });
}
