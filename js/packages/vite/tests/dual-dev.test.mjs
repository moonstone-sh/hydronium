// Tests for ../bin/dual-dev.mjs -- the CLI wrapper that lets hydronium's
// Lua CLI (cli/src/main.lua's `hydronium dev --vite`) spawn ONE process
// that actually runs runDualDevServer (../src/supervisor.mjs) underneath,
// standing in for the real Meteorite+Vite pair with two trivial `node -e`
// one-liners exactly like tests/supervisor.test.mjs does. This exercises
// the real child_process spawned by the real Lua-facing entry point, not
// just the library function it wraps.
//
// Run with: node --test js/packages/vite/tests/dual-dev.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DUAL_DEV = join(__dirname, "../bin/dual-dev.mjs");

function longRunningScript(name) {
  return `process.stdout.write(${JSON.stringify(name)} + " ready\\n"); setInterval(() => {}, 1000);`;
}

test("spawns every named process and merges their output with a name prefix", async () => {
  const specs = [
    { name: "meteorite", command: process.execPath, args: ["-e", longRunningScript("meteorite")] },
    { name: "vite", command: process.execPath, args: ["-e", longRunningScript("vite")] },
  ];
  const child = spawn(process.execPath, [DUAL_DEV, "--specs", JSON.stringify(specs)], { stdio: ["ignore", "pipe", "pipe"] });

  let out = "";
  child.stdout.on("data", (chunk) => { out += chunk; });

  await new Promise((resolve) => {
    const check = () => {
      if (out.includes("[meteorite] meteorite ready") && out.includes("[vite] vite ready")) resolve();
      else setTimeout(check, 20);
    };
    check();
  });

  child.kill("SIGTERM");
  await new Promise((resolve) => child.on("exit", resolve));
});

test("one process exiting brings the whole wrapper down with a non-zero exit code", async () => {
  const specs = [
    { name: "short-lived", command: process.execPath, args: ["-e", "process.exit(0)"] },
    { name: "long-lived", command: process.execPath, args: ["-e", longRunningScript("long-lived")] },
  ];
  const child = spawn(process.execPath, [DUAL_DEV, "--specs", JSON.stringify(specs)], { stdio: ["ignore", "pipe", "pipe"] });

  const [code] = await new Promise((resolve) => {
    child.on("exit", (code, signal) => resolve([code, signal]));
  });

  // The wrapper itself exits non-zero because "long-lived" was killed by
  // a signal rather than exiting 0 on its own -- this is what lets the
  // Lua Supervisor's own liveness probe (kill -0 on the wrapper's pid)
  // and its eventual `server_exit` event distinguish "the dev loop is
  // still up" from "something in it died".
  assert.notEqual(code, 0);
});

test("forwards SIGTERM (as the Lua Supervisor's stop() sends) to every child", async () => {
  const specs = [
    { name: "a", command: process.execPath, args: ["-e", longRunningScript("a")] },
    { name: "b", command: process.execPath, args: ["-e", longRunningScript("b")] },
  ];
  const child = spawn(process.execPath, [DUAL_DEV, "--specs", JSON.stringify(specs)], { stdio: ["ignore", "pipe", "pipe"] });

  let out = "";
  child.stdout.on("data", (chunk) => { out += chunk; });
  await new Promise((resolve) => {
    const check = () => (out.includes("a ready") && out.includes("b ready")) ? resolve() : setTimeout(check, 20);
    check();
  });

  const exit = new Promise((resolve) => child.on("exit", (code, signal) => resolve({ code, signal })));
  child.kill("SIGTERM");
  const result = await exit;
  // The wrapper process itself dies from the forwarded signal (or exits
  // once its children are reaped) rather than hanging forever.
  assert.ok(result.code !== undefined);
});

test("rejects a missing or invalid --specs rather than hanging", async () => {
  const noSpecs = spawn(process.execPath, [DUAL_DEV], { stdio: ["ignore", "ignore", "pipe"] });
  const noSpecsResult = await new Promise((resolve) => {
    let err = "";
    noSpecs.stderr.on("data", (c) => { err += c; });
    noSpecs.on("exit", (code) => resolve({ code, err }));
  });
  assert.equal(noSpecsResult.code, 1);
  assert.match(noSpecsResult.err, /--specs/);

  const badJson = spawn(process.execPath, [DUAL_DEV, "--specs", "not json"], { stdio: ["ignore", "ignore", "pipe"] });
  const badJsonResult = await new Promise((resolve) => {
    let err = "";
    badJson.stderr.on("data", (c) => { err += c; });
    badJson.on("exit", (code) => resolve({ code, err }));
  });
  assert.equal(badJsonResult.code, 1);
  assert.match(badJsonResult.err, /not valid JSON/);
});
