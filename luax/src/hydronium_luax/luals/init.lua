--[[
  Hydronium LUAX LuaLS Plugin Entrypoint
  Intercepts .luax files in LuaLS workspace and projects virtual Lua source code.
  Complies with:
  - Amendment 2: 1:1 LSP Coordinate Preservation & Virtual Source
  - Amendment 3: Virtual Type Injection
  - Additional Architectural Directive:
    Lowers JSX into ordinary typed Lua function calls (__luax_intrinsic.button, __luax_component)
    so LuaLS natively performs diagnostics, autocompletion, hover, and parameter type inference.
--]]

local info = debug.getinfo(1, "S")
local src_path = info and info.source and info.source:gsub("^@", "") or ""
local module_root = src_path:match("^(.*)/hydronium_luax/luals/init%.lua$")
if module_root and module_root ~= "" then
  package.path = module_root .. "/?.lua;" .. module_root .. "/?/init.lua;" .. package.path
else
  package.path = "src/?.lua;src/?/init.lua;" .. package.path
end

local plugin_mod = require("hydronium_luax.plugin")
local virtual_source = require("hydronium_luax.luals.virtual_source")

local plugin = {}

-- See hydronium.luax.plugin's compute_diff for why this must be a multi-hunk,
-- per-changed-run diff rather than a single first-diff..last-diff hunk.
local compute_diff = plugin_mod.compute_diff

--- LuaLS plugin OnSetText lifecycle hook.
--- Triggered whenever a document is opened or modified.
--- @param uri string The file URI (e.g. "file:///workspace/App.luax")
--- @param text string The raw document text
--- @return table? diff Table containing { text = virtual_code } or nil
function plugin.OnSetText(uri, text)
  if not uri then return nil end
  -- Markdown component modules: prose blanked, setup/`{expr}`/components kept
  -- as positioned Lua (hydronium_luax.luals.mdx). `.md` only reaches here if
  -- the workspace associates it with Lua; it then types as a component.
  if uri:match("%.mdx?$") then
    return require("hydronium_luax.luals.mdx").project(text, uri)
  end
  if not uri:match("%.luax$") then
    return nil
  end

  local virtual_code = plugin_mod.virtual_lower(text, uri)
  -- Bare attributes, as LuaLS positions (row * 10000 + column, 0-based).
  local bare = {}
  for _, offset in ipairs(virtual_source.bare_attributes) do
    local row, line_start = 0, 1
    for nl in text:sub(1, offset - 1):gmatch("()\n") do row, line_start = row + 1, nl + 1 end
    bare[row * 10000 + (offset - line_start)] = true
  end
  plugin.bare_attributes[uri] = next(bare) and bare or nil
  -- An empty diff list means "this file needs no changes", which is exactly
  -- right for a .luax file containing no JSX at all — its text is already
  -- valid Lua. Do NOT substitute a whole-file {start=1, finish=#text} hunk
  -- here: it is an identity rewrite, so it buys nothing, but its range covers
  -- every byte and therefore collides with every other plugin's diff under
  -- composition. Because LuaLS's string-merger sorts hunks with a non-stable
  -- table.sort keyed only on `start`, such a hunk can sort ahead of another
  -- plugin's insertion at the same offset, driving the merge cursor past
  -- end-of-file and then back — silently duplicating the file (observed as
  -- `Redefined local Cfg`). See LUALS-DESIGN.md §4.1.
  local diffs = compute_diff(text, virtual_code)
  diffs.text = virtual_code
  return diffs
end

plugin.bare_attributes = {}

--- LuaLS plugin OnTransformAst hook: `<d.input disabled />` means
--- `disabled = true`. The byte-preserving lowering leaves `disabled` as a
--- positional entry (a global read: "undefined global"); this turns those
--- entries into fields, so they are typed against the props like any other.
--- Walks the tree itself: LuaLS's guide caches would keep the old nodes.
function plugin.OnTransformAst(uri, ast)
  local bare = plugin.bare_attributes[uri]
  if not bare or not ast then return nil end
  local seen = {}
  local function visit(node)
    if type(node) ~= "table" or seen[node] then return end
    seen[node] = true
    if node.type == "tableexp" and node.value and node.value.type == "getglobal" and bare[node.value.start] then
      local name = node.value
      node.type = "tablefield"
      node.tindex = nil
      node.node = node.parent
      node.field = { type = "field", start = name.start, finish = name.finish, parent = node, [1] = name[1] }
      node.value = { type = "boolean", start = name.finish, finish = name.finish, parent = node, [1] = true }
      node.range = name.finish
      return
    end
    for key, child in pairs(node) do
      if key ~= "parent" and key ~= "node" and type(child) == "table" then visit(child) end
    end
  end
  visit(ast)
  return ast
end

--- LuaLS plugin ResolveRequire hook.
function plugin.ResolveRequire(uri, name)
  return plugin_mod.ResolveRequire(uri, name)
end

--- LuaLS plugin initialization hook.
function plugin.init()
  return {
    name = "hydronium-luax-luals",
    version = "0.1.0",
    description = "Hydronium LUAX Language Server Protocol virtual lowering plugin",
  }
end

plugin.virtual_source = virtual_source

-- Expose to LuaLS plugin environment
OnSetText = plugin.OnSetText
ResolveRequire = plugin.ResolveRequire
OnTransformAst = plugin.OnTransformAst

return plugin
