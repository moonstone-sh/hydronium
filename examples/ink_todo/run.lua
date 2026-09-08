--[[
  Hydronium Ink Todo -- runner. Compiles todo.luax through the real
  hydronium_luax compiler (runtime = "hydronium", the real execution
  backend -- see examples/ink_demo/run_luax.lua for the established
  pattern this mirrors) and drives it through the real `ink.render()`
  entry point (hydronium_ink.render), not a hand-assembled host/
  reconciler/loop the way the plain-Lua ink_demo/run.lua still does --
  this is what a real app is actually meant to call.

  Two equally real ways to run this (verified both):

    luajit examples/ink_todo/run.lua                  # from the repo root
    cd examples/ink_todo && moon sync && moon exec -- luajit run.lua

  The second is the actual point of this example having its own
  moonstone.toml (path: dependencies on ../../core, ../../ink,
  ../../luax): `moon exec` resolves `hydronium`/`hydronium_ink`/
  `hydronium_luax` via real moonstone materialization, no manual
  package.path needed for that at all -- only the plain-`luajit`
  invocation above (no moon sync ever run) needs this file's own
  fallback path additions below. Every path here is computed relative
  to THIS FILE's own location (`debug.getinfo`, the same zero-hardcoded/
  zero-cwd-assumption technique `yoga_ffi.lua`'s `this_file_dir()`
  already uses), not the current working directory -- found the hard
  way: an earlier version hardcoded `"examples/ink_todo/todo.luax"` and
  `"core/src/?.lua"`, which only worked when invoked from the repo root;
  running it via `moon exec` from this directory (a real, expected way
  to run an "example project") failed on both counts.
--]]

local info = debug.getinfo(1, "S")
local this_dir = (info.source:gsub("^@", "")):match("^(.*)[/\\][^/\\]+$") or "."
local repo_root = this_dir .. "/../.."

-- Fallback only -- see this file's own doc comment above. A no-op
-- (every entry fails to resolve anything) once `moon exec` has already
-- set LUA_PATH correctly via this example's own moonstone.toml.
package.path = repo_root .. "/core/src/?.lua;" .. repo_root .. "/core/src/?/init.lua;"
  .. repo_root .. "/ink/src/?.lua;" .. repo_root .. "/ink/src/?/init.lua;"
  .. repo_root .. "/luax/src/?.lua;" .. repo_root .. "/luax/src/?/init.lua;"
  .. package.path

-- Real terminal UIs need every frame to reach the terminal immediately --
-- see examples/ink_demo/run.lua's identical setvbuf call for why (C
-- stdio switches to fully-buffered, not line-buffered, whenever stdout
-- isn't a tty -- e.g. captured into a file for inspection -- so without
-- this, output can sit unflushed until the process exits).
io.stdout:setvbuf("no")

local hydronium = require("hydronium")
local luax = require("hydronium_luax")
local render = require("hydronium_ink.render")

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then error("Cannot read file " .. path .. ": " .. tostring(err), 2) end
  local content = f:read("*a")
  f:close()
  return content
end

local src = read_file(this_dir .. "/todo.luax")
local compiled = luax.compile(src, {
  filename = "todo.luax",
  runtime = "hydronium",
  sourcemap = true,
})

-- shared_env: `H`/`hydronium` for the real compiled-code global the
-- "hydronium" runtime backend references directly, `__luax` for the
-- spread/fragment-children runtime helpers -- see run_luax.lua's own
-- doc comment for why both are needed. `hydronium` (a real local, not
-- just the `H` global) is also referenced directly inside todo.luax's
-- own source (`hydronium.signal(...)`), so it needs to resolve too.
local shared_env = setmetatable({
  H = hydronium,
  hydronium = hydronium,
  __luax = require("hydronium_luax.runtime"),
}, { __index = _G })

local chunk, load_err = load(compiled.code, "todo.luax", "t", shared_env)
if not chunk then
  error("Failed to load compiled todo.luax: " .. tostring(load_err) .. "\nCode:\n" .. compiled.code)
end

-- todo.luax's own top-level `return function() ... end` -- a real
-- Hydronium component (setup once, returns its own render closure), used
-- directly as the app's root element.
local TodoApp = chunk()

local result = render.render(hydronium.h(TodoApp))
print()
print("render() returned, exitReason = " .. tostring(result.exitReason))
