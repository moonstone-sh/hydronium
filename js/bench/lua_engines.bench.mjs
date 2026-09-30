// End-to-end browser benchmark: lua-wasm (Bridge API 2, Hydronium's default)
// vs the Wasmoon fallback, same page, same machine, same Hydronium code.
//
//   node js/bench/lua_engines.bench.mjs [--runs 12] [--json out.json]
//
// Needs examples/spa_hash_demo built (`moon run build` there) for the
// framework chunk. Every run uses a fresh browser context (cold: no HTTP or
// compile cache) and engines alternate run by run. Metrics per run:
//   boot.*       mount()'s own phase timings (engine import/create, total)
//   create1000   click -> 1,000 new <li> rows in the DOM
//   update1000   click -> all 1,000 rows re-rendered with new text
//   event        median of 50 click -> DOM text updated round trips
// Reported as p50/p95 across runs; ratio = wasmoon / lua-wasm (>1: lua-wasm faster).
import { chromium } from "playwright";
import { writeFile } from "node:fs/promises";
import { distBuilt, startServer } from "../tests/lib/lua_wasm_harness.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const RUNS = Number(option("--runs", 12));
const JSON_OUT = option("--json", null);
const ENGINES = ["api2", "wasmoon"];

const APP = `
local signals = require("hydronium.signals")
local d = require("hydronium_dom").d
local unpack = table.unpack or unpack

return function()
  local rows, set_rows = signals.createSignal({})
  local gen, set_gen = signals.createSignal(0)
  local count, set_count = signals.createSignal(0)
  return function()
    local items = {}
    for i, value in ipairs(rows()) do items[i] = d.li({}, "row " .. tostring(value)) end
    return d.div({ id = "bench" },
      d.button({ id = "fill", onClick = function()
        local g, list = gen() + 1, {}
        for i = 1, 1000 do list[i] = i + g end
        set_gen(g); set_rows(list)
      end }, "fill"),
      d.button({ id = "inc", onClick = function() set_count(count() + 1) end }, "inc"),
      d.p({ id = "gen" }, tostring(gen())),
      d.p({ id = "count" }, tostring(count())),
      d.ul({ id = "list" }, unpack(items)))
  end
end
`;

// In-page: click, then resolve when `predicate` holds (checked synchronously
// first -- both engines can finish inside the click -- then on DOM mutation).
const TIMED_CLICK = `async (selector, predicateSource) => {
  const predicate = new Function("return (" + predicateSource + ")()");
  const t0 = performance.now();
  document.querySelector(selector).click();
  if (!predicate()) await new Promise((resolve) => {
    const observer = new MutationObserver(() => { if (predicate()) { observer.disconnect(); resolve(); } });
    observer.observe(document.body, { subtree: true, childList: true, characterData: true });
  });
  return performance.now() - t0;
}`;

async function oneRun(browser, origin, engine) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.goto(`${origin}/?engine=${engine}`);
  await page.waitForFunction(() => window.__mounted === true, null, { timeout: 60_000 });
  const mountError = await page.evaluate(() => window.__mountError ?? null);
  if (mountError) throw new Error(`${engine}: mount failed: ${mountError}`);
  const timings = await page.evaluate(() => window.__timings);
  const timed = (selector, predicate) => page.evaluate(`(${TIMED_CLICK})(${JSON.stringify(selector)}, ${JSON.stringify(predicate)})`);

  const create1000 = await timed("#fill", `() => document.querySelector("#gen").textContent === "1" && document.querySelector("#list").children.length === 1000`);
  const update1000 = await timed("#fill", `() => document.querySelector("#gen").textContent === "2" && document.querySelector("#list").lastElementChild?.textContent === "row 1002"`);
  const events = [];
  for (let i = 1; i <= 50; i++) events.push(await timed("#inc", `() => document.querySelector("#count").textContent === "${i}"`));
  await context.close();
  if (errors.length) throw new Error(`${engine}: page errors: ${errors.join("; ")}`);
  return {
    "boot.engineImport": timings["engine:import"], "boot.engineCreate": timings["engine:create"],
    "boot.total": timings.total, create1000, update1000, event: median(events),
  };
}

const median = (values) => percentile(values, 50);
function percentile(values, p) {
  const sorted = values.filter((v) => typeof v === "number").sort((a, b) => a - b);
  if (!sorted.length) return null;
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

async function main() {
  if (!distBuilt) { console.error("build examples/spa_hash_demo first (moon run build)"); process.exit(1); }
  const server = await startServer(APP);
  const browser = await chromium.launch();
  const samples = Object.fromEntries(ENGINES.map((engine) => [engine, []]));
  try {
    // One discarded warm-up per engine (Chromium process/JIT start-up).
    for (const engine of ENGINES) await oneRun(browser, server.origin, engine);
    for (let run = 0; run < RUNS; run++) {
      const order = run % 2 === 0 ? ENGINES : [...ENGINES].reverse();
      for (const engine of order) samples[engine].push(await oneRun(browser, server.origin, engine));
    }
  } finally {
    await browser.close();
    await server.close();
  }
  const metrics = Object.keys(samples.api2[0]);
  const summary = {};
  for (const metric of metrics) {
    const row = {};
    for (const engine of ENGINES) {
      const values = samples[engine].map((sample) => sample[metric]);
      row[engine] = { p50: percentile(values, 50), p95: percentile(values, 95) };
    }
    row.ratioP50 = row.wasmoon.p50 && row.api2.p50 ? row.wasmoon.p50 / row.api2.p50 : null;
    summary[metric] = row;
  }
  const fmt = (v) => (v == null ? "n/a" : v < 10 ? v.toFixed(2) : v.toFixed(1));
  console.log(`\nlua-wasm (Bridge API 2) vs Wasmoon -- ${RUNS} cold runs per engine, ${new Date().toISOString()}`);
  console.log(`Chromium ${browser.version?.() ?? ""}\n`);
  console.log("| metric | lua-wasm p50 | lua-wasm p95 | wasmoon p50 | wasmoon p95 | wasmoon/lua-wasm (p50) |");
  console.log("|---|---|---|---|---|---|");
  for (const [metric, row] of Object.entries(summary)) {
    console.log(`| ${metric} (ms) | ${fmt(row.api2.p50)} | ${fmt(row.api2.p95)} | ${fmt(row.wasmoon.p50)} | ${fmt(row.wasmoon.p95)} | ${row.ratioP50 == null ? "n/a" : row.ratioP50.toFixed(2) + "x"} |`);
  }
  if (JSON_OUT) await writeFile(JSON_OUT, JSON.stringify({ runs: RUNS, date: new Date().toISOString(), summary, samples }, null, 2));
}

main().catch((error) => { console.error(error); process.exit(1); });
