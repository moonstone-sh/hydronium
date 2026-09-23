#!/usr/bin/env node
// hydronium dual dev-server launcher -- the thin CLI wrapper that finally
// wires up runDualDevServer (../src/supervisor.mjs, M2 item 3 of
// docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md, tested 5/5 in
// tests/supervisor.test.mjs) to something real. Before this file existed,
// that supervisor was written, tested, and never spawned by anything.
//
// Spawned by hydronium's Lua CLI (cli/src/dev_supervisor.lua's
// Supervisor, via cli/src/main.lua's `hydronium dev --vite`) as its ONE
// child process, in place of a bare `meteorite dev`: this script starts
// Meteorite dev and `vite dev` TOGETHER, merges their output with a
// `[name]` prefix, and forwards SIGINT/SIGTERM to both, so the Lua CLI's
// existing single-pid liveness/stop model (kill -0, SIGTERM then
// SIGKILL) keeps working unmodified even though two real dev servers are
// now running underneath it.
//
// Usage:
//   node dual-dev.mjs --specs '<json array of {name,command,args?,cwd?,env?}>'
//
// Deliberately ONE json-encoded argv word rather than a flag per process:
// this script is itself spawned from a Lua shell line
// (dev_supervisor.spawn_detached), which shell-quotes each argv element
// as one opaque token -- a JSON blob round-trips safely through that
// (arbitrary bytes, one word), while a bespoke per-process flag grammar
// would not (a command or arg containing a space breaks a %S+ word split
// on the Lua side, see cli/src/main.lua's own --meteorite-args comment on
// exactly this hazard).
//
// Exit code: 0 only if every supervised process exited 0 on its own
// (the ordinary case is neither ever does -- they are dev servers killed
// by a signal, which this reports as a non-zero exit, matching what a
// real crash would also report).

import { runDualDevServer } from "../src/supervisor.mjs";

function fail(message) {
  process.stderr.write(`dual-dev: ${message}\n`);
  process.exit(1);
}

function readSpecsArg(argv) {
  const index = argv.indexOf("--specs");
  if (index === -1 || argv[index + 1] === undefined) {
    fail("--specs <json> is required, e.g. --specs '[{\"name\":\"meteorite\",\"command\":\"meteorite\",\"args\":[\"dev\"]}]'");
  }
  return argv[index + 1];
}

function parseSpecs(raw) {
  let specs;
  try {
    specs = JSON.parse(raw);
  } catch (err) {
    fail(`--specs is not valid JSON: ${err.message}`);
  }
  if (!Array.isArray(specs) || specs.length === 0) {
    fail("--specs must be a non-empty JSON array of {name, command, args, cwd}");
  }
  return specs;
}

const specs = parseSpecs(readSpecsArg(process.argv.slice(2)));

const supervisor = runDualDevServer(specs);

supervisor.exited.then((results) => {
  for (const r of results) {
    process.stderr.write(
      `dual-dev: ${r.name} exited (code=${r.code ?? "null"} signal=${r.signal ?? "null"})\n`
    );
  }
  const allClean = results.every((r) => r.code === 0 && r.signal === null);
  process.exit(allClean ? 0 : 1);
});
