// Tests for ../src/supervisor.mjs (M2, item 3 of
// docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md). Exercises the real
// child_process/signal-forwarding logic against two trivial `node -e`
// one-liners standing in for "meteorite dev" and "vite dev" -- nothing
// about the supervisor itself is specific to either tool (see its own
// header), so this is a faithful, fast, dependency-free proof.
//
// Run with: node --test js/packages/vite/tests/supervisor.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { runDualDevServer } from "../src/supervisor.mjs";

function longRunningScript(name) {
  // Prints one line, then blocks forever (until killed) -- stands in for
  // a real dev server that stays up until told to stop.
  return `process.stdout.write(${JSON.stringify(name)} + " ready\\n"); setInterval(() => {}, 1000);`;
}

test("spawns every named process and merges their stdout with a name prefix", async () => {
  const lines = [];
  const supervisor = runDualDevServer(
    [
      { name: "meteorite", command: process.execPath, args: ["-e", longRunningScript("meteorite")] },
      { name: "vite", command: process.execPath, args: ["-e", longRunningScript("vite")] },
    ],
    { onLog: (name, line) => lines.push([name, line]), forwardProcessSignals: false }
  );

  await new Promise((resolve) => {
    const check = () => {
      if (lines.some(([n]) => n === "meteorite") && lines.some(([n]) => n === "vite")) resolve();
      else setTimeout(check, 20);
    };
    check();
  });

  assert.ok(lines.some(([name, line]) => name === "meteorite" && line === "meteorite ready"));
  assert.ok(lines.some(([name, line]) => name === "vite" && line === "vite ready"));

  supervisor.stop();
  await supervisor.exited;
});

test("stop() kills every child, and exited resolves once both have exited", async () => {
  const supervisor = runDualDevServer(
    [
      { name: "a", command: process.execPath, args: ["-e", longRunningScript("a")] },
      { name: "b", command: process.execPath, args: ["-e", longRunningScript("b")] },
    ],
    { onLog: () => {}, forwardProcessSignals: false }
  );

  // Give both children a moment to actually start before killing them.
  await new Promise((resolve) => setTimeout(resolve, 100));

  supervisor.stop();
  const results = await supervisor.exited;

  assert.equal(results.length, 2);
  for (const r of results) {
    // Killed by a signal (SIGTERM), not a clean exit(0) -- these scripts
    // never exit on their own.
    assert.equal(r.code, null);
    assert.ok(r.signal === "SIGTERM" || r.signal === "SIGKILL", `unexpected signal ${r.signal}`);
  }
});

test("one process exiting brings the other down too (no half-alive dev session)", async () => {
  const supervisorLog = [];
  const supervisor = runDualDevServer(
    [
      // Exits almost immediately on its own.
      { name: "short-lived", command: process.execPath, args: ["-e", "process.exit(0)"] },
      { name: "long-lived", command: process.execPath, args: ["-e", longRunningScript("long-lived")] },
    ],
    { onLog: (name, line) => supervisorLog.push([name, line]), forwardProcessSignals: false }
  );

  const results = await supervisor.exited;
  assert.equal(results.length, 2);

  const shortLived = results.find((r) => r.name === "short-lived");
  const longLived = results.find((r) => r.name === "long-lived");
  assert.equal(shortLived.code, 0);
  assert.equal(shortLived.signal, null);
  // The survivor was killed by the supervisor, not left running.
  assert.ok(longLived.signal === "SIGTERM" || longLived.signal === "SIGKILL");

  assert.ok(
    supervisorLog.some(([name, line]) => name === "supervisor" && line.includes("short-lived exited")),
    "supervisor should log which process triggered the shutdown"
  );
});

test("rejects an empty process list rather than silently doing nothing", () => {
  assert.throws(() => runDualDevServer([]), /non-empty array/);
});

test("rejects a process spec missing name or command", () => {
  assert.throws(() => runDualDevServer([{ name: "x" }]), /string `name` and `command`/);
});
