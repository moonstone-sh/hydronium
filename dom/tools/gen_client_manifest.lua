--[[
  tools/gen_client_manifest.lua -- derives the real, real client runtime
  module list for `hydronium.client.mount` from the static literal
  require() graph of a given set of entry modules. It follows every local
  `require("module.id")` deterministically without executing application
  code -- so the manifest neither runs host-only initialization nor misses
  nested imports because a loader captured require before instrumentation.
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

package.path = "core/src/?.lua;core/src/?/init.lua;dom/src/?.lua;dom/src/?/init.lua;router/src/?.lua;router/src/?/init.lua;" .. package.path

local function source_path(mod_id)
  local p = mod_id:gsub("%.", "/")
  local candidates = {
    "core/src/" .. p .. ".lua",
    "core/src/" .. p .. "/init.lua",
    "dom/src/" .. p .. ".lua",
    "dom/src/" .. p .. "/init.lua",
    "router/src/" .. p .. ".lua",
    "router/src/" .. p .. "/init.lua",
  }
  for _, candidate in ipairs(candidates) do
    local f = io.open(candidate, "r")
    if f then
      f:close()
      return candidate
    end
  end
  return nil
end

local function to_relpath(source)
  -- The Meteorite example mounts all three member source roots under the
  -- client-runtime route, preserving their distinct package namespaces.
  return source:gsub("^core/src/", ""):gsub("^dom/src/", ""):gsub("^router/src/", "")
end

local function literal_requires(source)
  local ids, seen = {}, {}
  for id in source:gmatch("require%s*%(%s*['\"]([%w_.%-]+)['\"]%s*%)") do
    if not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  return ids
end

local manifest = {}      -- module_id -> relative path (order-preserving)
local order = {}
local seen = {}

if #arg < 1 then
    io.stderr:write("usage: lua dom/tools/gen_client_manifest.lua <entry_module_id> [...]\n")
  os.exit(1)
end

local pending = {}
for i = 1, #arg do pending[#pending + 1] = arg[i] end
local next_pending = 1
while next_pending <= #pending do
  local mod_id = pending[next_pending]
  next_pending = next_pending + 1
  if not seen[mod_id] then
    seen[mod_id] = true
    local source = source_path(mod_id)
    if source then
      manifest[mod_id] = to_relpath(source)
      order[#order + 1] = mod_id
      local f = assert(io.open(source, "r"))
      local contents = f:read("*a")
      f:close()
      for _, dependency in ipairs(literal_requires(contents)) do
        pending[#pending + 1] = dependency
      end
    end
  end
end

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
