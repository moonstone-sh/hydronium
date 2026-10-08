// dom/types/dom/webgl.d.lua and webgpu.d.lua are generated from the vendored
// WebIDL; fail when someone edits the IDL or the generator without
// regenerating them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../..");

test("WebGL and WebGPU LuaCATS match their WebIDL", () => {
  execFileSync(process.execPath, [join(repo, "dom/webidl/generate.mjs"), "--check"]);
});

test("dom/types/dom/style.d.lua is current with the vendored CSS property data", () => {
  execFileSync(process.execPath, [join(repo, "dom/webidl/css-style.mjs"), "--check"]);
  const style = readFileSync(join(repo, "dom/types/dom/style.d.lua"), "utf8");
  assert.match(style, /---@field backgroundColor\? HydroniumStyleValue/);
  assert.match(style, /---@field position\? "static" \| "relative"/);
  assert.match(readFileSync(join(repo, "dom/types/dom/html.d.lua"), "utf8"), /---@alias HydroniumStyleProp string \| HydroniumStyle$/m);
});
