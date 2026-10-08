// dom/types/dom/webgl.d.lua and webgpu.d.lua are generated from the vendored
// WebIDL; fail when someone edits the IDL or the generator without
// regenerating them.
import { test } from "node:test";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../..");

test("WebGL and WebGPU LuaCATS match their WebIDL", () => {
  execFileSync(process.execPath, [join(repo, "dom/webidl/generate.mjs"), "--check"]);
});
