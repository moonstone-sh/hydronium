local info = debug.getinfo(1, "S")
local src_path = info and info.source and info.source:gsub("^@", "") or ""
local module_root = src_path:match("^(.*)/hydronium_luax/plugin%.lua$")
if module_root and module_root ~= "" then
  package.path = module_root .. "/?.lua;" .. module_root .. "/?/init.lua;" .. package.path
else
  package.path = "src/?.lua;src/?/init.lua;" .. package.path
end

local compiler = require("hydronium_luax.compiler")
local parser_mod = require("hydronium_luax.parser")
local virtual_source = require("hydronium_luax.luals.virtual_source")

local M = {}

-- Lower an entire source file to virtual Lua code projecting into typed ordinary Lua
-- - <button ...> -> __luax_intrinsic.button({ ... })
-- - <MyComp ...> -> __luax_component(MyComp, { ... })
-- - <> ... </>   -> __luax_fragment(...)
-- Preserves 1:1 line coordinate stability
local function recover_incomplete_source(source)
  local virt = source
  -- 1. Incomplete tag opening with space for attributes: <d.button 
  virt = virt:gsub("<([%a_][%w_]*%.[%w_]+)[ \t]+(\r?\n)", " %1{ }\n")
  virt = virt:gsub("<([%a_][%w_]*%.[%w_]+)[ \t]+(%))", " %1{ }%2")
  virt = virt:gsub("<([%a_][%w_]*%.[%w_]+)[ \t]+$", " %1{ }")
  virt = virt:gsub("<([%a_][%w_]*%.[%w_]+)[ \t]+", " %1{ ")
  -- 2. Incomplete member access: <d. (not followed by another identifier character)
  virt = virt:gsub("<([%a_][%w_]*%.)([ \t\r\n%)])", " %1%2")
  virt = virt:gsub("<([%a_][%w_]*%.)$", " %1")
  -- 3. Replace remaining < before identifier
  virt = virt:gsub("<([%a_][%w_]*)", " %1")
  return virt
end

function M.virtual_lower(source, filename)
  -- Use the byte-aligned, in-place rewriter (virtual_source.transform), not
  -- compiler.compile's virtual_luals mode: the compiler builds a fresh
  -- nested-call AST rewrite (reordering/collapsing children into varargs),
  -- which does NOT preserve line/column correspondence for anything beyond
  -- a single self-closing tag with no children. That mismatch is silently
  -- invisible for completion/hover (which mostly land on short, early-line
  -- spans) but corrupts `textDocument/rename`/`references` results for any
  -- multi-line or nested element, since LuaLS's OnSetText plugin protocol
  -- has no separate source-map layer -- positions in the virtual document
  -- from OnSetText are used verbatim against the original document. See
  -- docs/LUAX_DX_CURRENT_STATE.md for the reproduction and rationale.
  local parse_ok = pcall(parser_mod.parse, source, filename or "file.luax")
  local virtual_code
  if parse_ok then
    virtual_code = virtual_source.transform(source, filename)
  else
    virtual_code = recover_incomplete_source(source)
  end

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

-- Splits the diff into one hunk per contiguous run of changed bytes, rather
-- than a single hunk spanning from the first to the last differing byte.
-- virtual_source.transform is byte-length-preserving (same total length,
-- same line count), so a plain per-byte comparison is a correct diff here --
-- no LCS/alignment needed. This matters a lot in practice: with a single
-- "first diff .. last diff" hunk, everything between the first and last
-- changed byte (which, for a JSX-heavy file, is nearly the entire document)
-- falls *inside* one diff hunk, including every unchanged identifier in
-- between (e.g. every occurrence of a locally-declared `d`). LuaLS's
-- reference/rename position-remapping does not reliably recover individual
-- positions *within* such a hunk -- verified by reproducing the same
-- structure in a plain .lua file (correct, single-character reference
-- ranges) vs. through this plugin's single-hunk diff (garbled, overlapping
-- ranges). Emitting one small hunk per actually-changed run leaves every
-- unchanged span -- including each reference to `d` -- entirely outside any
-- hunk, which resolves it. See docs/LUAX_DX_CURRENT_STATE.md.
local function compute_diff(orig, virt)
  if orig == virt then
    return {}
  end
  if #orig ~= #virt then
    -- Should not happen (virtual_source.transform preserves length), but
    -- fall back to a single-hunk diff rather than erroring.
    local len_orig, len_virt = #orig, #virt
    local s = 1
    while s <= len_orig and s <= len_virt and orig:byte(s) == virt:byte(s) do
      s = s + 1
    end
    local e_orig, e_virt = len_orig, len_virt
    while e_orig >= s and e_virt >= s and orig:byte(e_orig) == virt:byte(e_virt) do
      e_orig = e_orig - 1
      e_virt = e_virt - 1
    end
    return { { start = s, finish = e_orig, text = virt:sub(s, e_virt) } }
  end

  local diffs = {}
  local n = #orig
  local i = 1
  while i <= n do
    if orig:byte(i) ~= virt:byte(i) then
      local j = i
      while j <= n and orig:byte(j) ~= virt:byte(j) do
        j = j + 1
      end
      table.insert(diffs, { start = i, finish = j - 1, text = virt:sub(i, j - 1) })
      i = j
    else
      i = i + 1
    end
  end
  return diffs
end

M.compute_diff = compute_diff

-- LuaLS Hook: OnSetText
function M.OnSetText(uri, text)
  if not uri or not uri:match("%.luax$") then
    return nil
  end

  local virtual_code = M.virtual_lower(text, uri)
  -- See the identical note in luals/init.lua: an empty diff list is the correct
  -- answer for a JSX-free .luax file. Substituting a whole-file identity hunk
  -- changes nothing but claims every byte, which corrupts the merge when any
  -- other OnSetText plugin is composed alongside this one.
  local diffs = compute_diff(text, virtual_code)
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
