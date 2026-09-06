local info = debug.getinfo(1, "S")
local src_path = info and info.source and info.source:gsub("^@", "") or ""
local proj_root = src_path:match("^(.*)/src/hydronium/luax/plugin%.lua$") or src_path:match("^(.*)/src/.*$")
if proj_root and proj_root ~= "" then
  package.path = proj_root .. "/src/?.lua;" .. proj_root .. "/src/?/init.lua;" .. package.path
else
  package.path = "src/?.lua;src/?/init.lua;" .. package.path
end

local compiler = require("hydronium.luax.compiler")
local dom_typing = require("hydronium.luax.dom_typing")

local M = {}

-- Lower an entire source file to virtual Lua code projecting into typed ordinary Lua
-- - <button ...> -> __luax_intrinsic.button({ ... })
-- - <MyComp ...> -> __luax_component(MyComp, { ... })
-- - <> ... </>   -> __luax_fragment(...)
-- Preserves 1:1 line coordinate stability
function M.virtual_lower(source, filename)
  local res = compiler.compile(source, {
    virtual_luals = true,
    filename = filename or "file.luax",
  })
  local virtual_code = res.code

  -- Coordinate stability check / adjustment:
  -- Count lines in original vs virtual to ensure 1:1 line correspondence
  local orig_lines = 1
  for _ in source:gmatch("\n") do
    orig_lines = orig_lines + 1
  end

  local virt_lines = 1
  for _ in virtual_code:gmatch("\n") do
    virt_lines = virt_lines + 1
  end

  if virt_lines < orig_lines then
    virtual_code = virtual_code .. string.rep("\n", orig_lines - virt_lines)
  end

  return virtual_code
end

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

-- LuaLS Hook: OnSetText
function M.OnSetText(uri, text)
  if not uri or not uri:match("%.luax$") then
    return nil
  end

  local virtual_code = M.virtual_lower(text, uri)
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

-- LuaLS Hook: ResolveRequire
function M.ResolveRequire(uri, name)
  if not name or type(name) ~= "string" then return nil end

  local rel_path = name:gsub("%.", "/") .. ".luax"

  -- Check relative to uri
  if uri then
    local base = uri:match("^(.-)/[^/]+$") or ""
    local candidate = base .. "/" .. rel_path
    local path_clean = candidate:gsub("^file://", "")
    local f = io.open(path_clean, "r")
    if f then
      f:close()
      return candidate
    end
  end

  -- Fallback check in cwd and src/
  local f = io.open(rel_path, "r")
  if f then
    f:close()
    return "file://" .. rel_path
  end

  local src_rel = "src/" .. rel_path
  local f2 = io.open(src_rel, "r")
  if f2 then
    f2:close()
    return "file://" .. src_rel
  end

  local tests_rel = "tests/" .. rel_path
  local f3 = io.open(tests_rel, "r")
  if f3 then
    f3:close()
    return "file://" .. tests_rel
  end

  return nil
end

OnSetText = M.OnSetText
ResolveRequire = M.ResolveRequire

return M
