// Dual dev-server supervisor -- M2, item 3 of
// docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md ("a supervisor that starts
// Meteorite dev + vite dev together, forwards signals, and merges logs").
//
// Plain JS (.mjs), not TypeScript: this package has no build step yet
// (see its own package.json description -- M0/M1 left @hydronium-js/vite as
// a type-checked skeleton with nothing compiling it), and this file is
// meant to be run directly with `node`, e.g. as the actual dev entry
// point for an app that wired both a Meteorite backend and a Vite
// frontend together (§2.5 of the plan: two real processes, forced,
// because Meteorite cannot serve websockets and Vite's HMR socket must
// reach Vite's own origin directly).
//
// Generic over "N named child processes", not hardcoded to exactly
// "meteorite" and "vite" -- keeps this file trivially testable against
// two plain `node` one-liners instead of needing a real Meteorite/Vite
// project on disk, and nothing about the merge/signal-forwarding logic
// below is actually specific to either tool.

import { spawn } from "node:child_process";

/**
 * @typedef {object} ProcessSpec
 * @property {string} name Short label used to prefix merged log lines.
 * @property {string} command
 * @property {string[]} [args]
 * @property {string} [cwd]
 * @property {NodeJS.ProcessEnv} [env] Merged over `process.env`, not replacing it.
 */

/**
 * @param {ProcessSpec[]} processes
 * @param {object} [options]
 * @param {(name: string, line: string) => void} [options.onLog] Called
 *   once per merged, newline-split output line (stdout and stderr both),
 *   prefixed by which process it came from. Defaults to a plain
 *   `[name] line` console.log -- pass your own to capture instead of
 *   printing (this is what the test suite does).
 * @param {string[]} [options.signals] Signals this process listens for
 *   and forwards to every child. Defaults to SIGINT and SIGTERM.
 * @param {boolean} [options.forwardProcessSignals] Set false to skip
 *   installing `process.on(signal, ...)` handlers entirely -- for tests,
 *   or for a caller that wants to drive `stop()` itself instead.
 * @returns {{
 *   children: import("node:child_process").ChildProcess[],
 *   stop: (signal?: string) => void,
 *   exited: Promise<{ name: string, code: number|null, signal: string|null }[]>,
 *   dispose: () => void,
 * }}
 */
export function runDualDevServer(processes, options = {}) {
  if (!Array.isArray(processes) || processes.length === 0) {
    throw new Error("runDualDevServer: `processes` must be a non-empty array of process specs");
  }
  const { onLog = defaultOnLog, signals = ["SIGINT", "SIGTERM"], forwardProcessSignals = true } = options;

  const entries = processes.map((spec) => {
    if (!spec || typeof spec.name !== "string" || typeof spec.command !== "string") {
      throw new Error("runDualDevServer: every process spec needs a string `name` and `command`");
    }
    const child = spawn(spec.command, spec.args ?? [], {
      cwd: spec.cwd,
      env: spec.env ? { ...process.env, ...spec.env } : process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    attachLineForwarding(child.stdout, spec.name, onLog);
    attachLineForwarding(child.stderr, spec.name, onLog);
    return { name: spec.name, child };
  });

  let stopping = false;
  /** @param {string} [signal] */
  function stop(signal = "SIGTERM") {
    if (stopping) return;
    stopping = true;
    for (const { child } of entries) {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill(signal);
      }
    }
  }

  // One process dying is not a state anyone wants the other left running
  // in -- a half-alive dev session (Vite up, Meteorite gone, or vice
  // versa) silently serves stale/broken pages instead of failing loudly.
  for (const { name, child } of entries) {
    child.on("exit", (code, signal) => {
      onLog("supervisor", `${name} exited (code=${code ?? "null"} signal=${signal ?? "null"})`);
      stop();
    });
  }

  const installed = [];
  if (forwardProcessSignals) {
    for (const sig of signals) {
      const handler = () => stop(sig);
      process.on(sig, handler);
      installed.push([sig, handler]);
    }
  }

  const exited = Promise.all(
    entries.map(
      ({ name, child }) =>
        new Promise((resolve) => {
          child.on("exit", (code, signal) => resolve({ name, code, signal }));
        })
    )
  );

  return {
    children: entries.map((e) => e.child),
    stop,
    exited,
    dispose() {
      for (const [sig, handler] of installed) process.off(sig, handler);
    },
  };
}

function defaultOnLog(name, line) {
  console.log(`[${name}] ${line}`);
}

function attachLineForwarding(stream, name, onLog) {
  if (!stream) return;
  let buffer = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, index).replace(/\r$/, "");
      buffer = buffer.slice(index + 1);
      onLog(name, line);
    }
  });
  stream.on("end", () => {
    if (buffer.length > 0) {
      onLog(name, buffer);
      buffer = "";
    }
  });
}
