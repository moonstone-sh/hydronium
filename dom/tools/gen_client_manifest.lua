--[[
  tools/gen_client_manifest.lua -- derives the real, real client runtime
  module list for `hydronium.client.mount` from the ACTUAL require()
  graph, by wrapping the global `require` and recording every module id
  it resolves while requiring a given set of entry modules -- the same
  established rule this whole codebase already follows for HMR's
  `family_loader` (never hand-maintain a source list the runtime already
  knows) applied here to the client manifest problem instead
  (docs/HMR_DOM_HOST.md's gap list calls this out by name: "no bundler
  exists ... EMBEDDED_MODULES is a hand-pasted blob").

  This is NOT a bundler (see docs/BUNDLING.md for what a real one would
  still need to do -- minification, single-file amalgamation, etc.) --
  it only answers "which real files, by real relative path, does this
  set of entry modules actually transitively require," so
  `hydronium.client.mount` can `fetch()` each one for real instead of a
  hand-pasted JSON blob typed into one verification page.

  Usage:
    lua dom/tools/gen_client_manifest.lua <entry_module_id> [<entry_module_id> ...] > manifest.json

  Run from the hydronium workspace root.  It resolves against the core and
  DOM member source roots and emits paths relative to each served root.
--]]

package.path = "core/src/?.lua;core/src/?/init.lua;dom/src/?.lua;dom/src/?/init.lua;" .. package.path

local function to_relpath(mod_id)
  local p = mod_id:gsub("%.", "/")
  local candidates = {
    { root = "core/src/", path = "core/src/" .. p .. ".lua" },
    { root = "core/src/", path = "core/src/" .. p .. "/init.lua" },
    { root = "dom/src/", path = "dom/src/" .. p .. ".lua" },
    { root = "dom/src/", path = "dom/src/" .. p .. "/init.lua" },
  }
  for _, c in ipairs(candidates) do
    local f = io.open(c.path, "r")
    if f then
      f:close()
      -- The Meteorite example mounts both member source roots under the
      -- client-runtime route, preserving their distinct package namespaces.
      return c.path:gsub("^core/src/", ""):gsub("^dom/src/", "")
    end
  end
  return nil
end

local manifest = {}      -- module_id -> relative path (order-preserving)
local order = {}
local seen = {}

local real_require = require

local function tracing_require(mod_id)
  if not seen[mod_id] then
    seen[mod_id] = true
    local path = to_relpath(mod_id)
    if path then
      manifest[mod_id] = path
      table.insert(order, mod_id)
    end
  end
  return real_require(mod_id)
end

if #arg < 1 then
    io.stderr:write("usage: lua dom/tools/gen_client_manifest.lua <entry_module_id> [...]\n")
  os.exit(1)
end

_G.require = tracing_require
for i = 1, #arg do
  local ok, err = pcall(tracing_require, arg[i])
  if not ok then
    _G.require = real_require
    io.stderr:write(string.format("gen_client_manifest: failed to require '%s': %s\n", arg[i], tostring(err)))
    os.exit(1)
  end
end
_G.require = real_require

-- Minimal, dependency-free JSON object emission (this codebase has zero
-- non-stdlib Lua dependencies anywhere -- a real JSON library would be
-- overkill for "a flat string->string map").
local function json_escape(s)
  return (s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    return string.format('\\u%04x', c:byte())
  end))
end

io.write("{\n")
for i, mod_id in ipairs(order) do
  io.write(string.format('  "%s": "%s"', json_escape(mod_id), json_escape(manifest[mod_id])))
  io.write(i < #order and ",\n" or "\n")
end
io.write("}\n")
