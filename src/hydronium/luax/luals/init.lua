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
local proj_root = src_path:match("^(.*)/src/hydronium/luax/luals/init%.lua$") or src_path:match("^(.*)/src/.*$")
if proj_root and proj_root ~= "" then
  package.path = proj_root .. "/src/?.lua;" .. proj_root .. "/src/?/init.lua;" .. package.path
else
  package.path = "src/?.lua;src/?/init.lua;" .. package.path
end

local plugin_mod = require("hydronium.luax.plugin")
local virtual_source = require("hydronium.luax.luals.virtual_source")

local plugin = {}

local function compute_diff(orig, virt)
  if orig == virt then
    return {}
  end
  local len_orig = #orig
  local len_virt = #virt
  local s = 1
  while s <= len_orig and s <= len_virt and orig:byte(s) == virt:byte(s) do
    s = s + 1
  end
  local e_orig = len_orig
  local e_virt = len_virt
  while e_orig >= s and e_virt >= s and orig:byte(e_orig) == virt:byte(e_virt) do
    e_orig = e_orig - 1
    e_virt = e_virt - 1
  end
  return {
    {
      start = s,
      finish = e_orig,
      text = virt:sub(s, e_virt),
    }
  }
end

--- LuaLS plugin OnSetText lifecycle hook.
--- Triggered whenever a document is opened or modified.
--- @param uri string The file URI (e.g. "file:///workspace/App.luax")
--- @param text string The raw document text
--- @return table? diff Table containing { text = virtual_code } or nil
function plugin.OnSetText(uri, text)
  if not uri or not uri:match("%.luax$") then
    return nil
  end

  local virtual_code = plugin_mod.virtual_lower(text, uri)
  local diffs = compute_diff(text, virtual_code)
  if #diffs == 0 then
    diffs = {
      {
        start = 1,
        finish = #text,
        text = virtual_code,
      }
    }
  end
  diffs.text = virtual_code
  return diffs
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

return plugin
