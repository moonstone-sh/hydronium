--[[
  hydronium_ballad.plugins.style -- real CSS scoping, merging, and an
  optional bundled reset, for the DOM target. See
  docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 2 for the full design this
  implements. NOT wired into ink/partiture.lua -- hydronium-ink has no
  CSS concept at all (terminal host).

  Scoping is a single-pass, non-full-parser CSS class-selector rewriter:
  it scans real .css text for comments, quoted strings, and
  `:global(...)` spans (all copied through verbatim -- `:global(...)`'s
  own wrapper is stripped but its contents are left UNSCOPED, which is
  the whole point of that escape hatch), and rewrites every other
  `.class-name` occurrence to `hydronium_dom.css.scope_class(path,
  class-name)`'s output -- the exact same pure function
  `hydronium_dom.css.sheet(path).class_name` computes at runtime, so the
  two sides agree with zero build/runtime coordination beyond both
  requiring this one shared module.

  STATED LIMITATION: this is not a real CSS parser. It does not
  understand CSS escape sequences inside class names (e.g. `.foo\:bar`),
  and treats any `.` followed by an identifier character as a class
  selector regardless of surrounding context (so a `.` that is actually
  a decimal point inside an unquoted, unusual value would be
  misinterpreted -- real stylesheets essentially never do this outside
  quoted strings, which ARE protected). Good enough for real, ordinary
  component stylesheets; not a general CSS toolchain.
--]]

local graph = require("ballad.graph")
local process = require("ballad.process")
local css_mod = require("hydronium_dom.css")

local M = {}

--- Locates the real, sibling reset.css next to wherever
--- `hydronium_dom.css`'s own `init.lua` actually resolved from --
--- `package.searchpath` (a real LuaJIT/5.2+ stdlib function; this
--- plugin, unlike the hydronium_dom.css module it depends on, only ever
--- runs under ballad's own LuaJIT, so relying on it here is safe) beats
--- guessing a path relative to THIS file's own location, which would be
--- wrong the moment hydronium-ballad and hydronium-dom aren't siblings
--- on disk (e.g. one resolved from the moonstone registry, the other
--- path-linked).
--- @return string|nil
local function find_reset_css()
  local resolved = package.searchpath and package.searchpath("hydronium_dom.css", package.path)
  if not resolved then
    return nil
  end
  return (resolved:gsub("init%.lua$", "reset.css"))
end

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then
    error("hydronium_ballad.plugins.style: cannot read " .. tostring(path) .. ": " .. tostring(err), 0)
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- @param hash string
--- @return string
local function require_real_hash(ctx, hash)
  if hash == "" then
    ctx.fail("hydronium_ballad.plugins.style: b3sum is not available -- ballad's own cache "
      .. "silently degrades without it; this plugin refuses to proceed rather than emit an unhashed bundle URL")
  end
  return hash
end

--- @param c string A single character.
--- @return boolean
local function is_class_ident_char(c)
  return c ~= "" and c:match("[%w_%-]") ~= nil
end

--- Real, single-pass rewrite -- see this file's own top doc comment for
--- exactly what it does and does not understand.
--- @param css_text string
--- @param css_path string Passed straight through to `hydronium_dom.css.scope_class` -- MUST be the same string the corresponding `css.sheet(...)` call at runtime uses.
--- @return string
local function rewrite_classes(css_text, css_path)
  local out = {}
  local i, n = 1, #css_text

  while i <= n do
    local c = css_text:sub(i, i)
    if c == "/" and css_text:sub(i + 1, i + 1) == "*" then
      local close_start = css_text:find("*/", i + 2, true)
      local endpos = close_start and (close_start + 1) or n
      table.insert(out, css_text:sub(i, endpos))
      i = endpos + 1
    elseif c == '"' or c == "'" then
      local quote = c
      local j = i + 1
      while j <= n and css_text:sub(j, j) ~= quote do
        if css_text:sub(j, j) == "\\" then
          j = j + 1
        end
        j = j + 1
      end
      table.insert(out, css_text:sub(i, j))
      i = j + 1
    elseif css_text:sub(i, i + 7):lower() == ":global(" then
      local depth = 1
      local j = i + 8
      while j <= n and depth > 0 do
        local cc = css_text:sub(j, j)
        if cc == "(" then
          depth = depth + 1
        elseif cc == ")" then
          depth = depth - 1
        end
        j = j + 1
      end
      -- Emit only the INNER content -- ":global(.foo)" becomes plain
      -- ".foo", unscoped, in the output CSS. The inner content itself is
      -- NOT recursively class-rewritten (that's the entire point).
      table.insert(out, css_text:sub(i + 8, j - 2))
      i = j
    elseif c == "." and is_class_ident_char(css_text:sub(i + 1, i + 1)) then
      local j = i + 1
      while j <= n and is_class_ident_char(css_text:sub(j, j)) do
        j = j + 1
      end
      local class_name = css_text:sub(i + 1, j - 1)
      table.insert(out, "." .. css_mod.scope_class(css_path, class_name))
      i = j
    else
      table.insert(out, c)
      i = i + 1
    end
  end

  return table.concat(out)
end

--- @class HydroniumBalladStyleBundleOptions
--- @field reset? boolean Default true. Prepends `hydronium_dom/css/reset.css` (real file, not embedded) before any component stylesheets.
--- @field bundle_name? string Default "app". The emitted file is `<out_prefix><bundle_name>-<hash>.css`.
--- @field out_prefix? string Default "assets/".
--- @field hash_length? integer Default 8.

--- Input: `kind = "file"` assets whose `virtual_path` ends `.css`.
--- Output: at most one `hy_style_bundle` asset (none if there is nothing
--- to bundle at all -- `reset = false` and zero stylesheets is a
--- legitimate no-CSS build, not an error).
--- @param ctx PluginCtx
--- @param inputs AssetSet[]
--- @param opts HydroniumBalladStyleBundleOptions
--- @return AssetSet
function M.bundle(ctx, inputs, opts)
  opts = opts or {}
  local include_reset = opts.reset
  if include_reset == nil then
    include_reset = true
  end
  local hash_length = opts.hash_length or 8
  local bundle_name = opts.bundle_name or "app"
  local out_prefix = opts.out_prefix or "assets/"

  -- Real stylesheets are sorted by project-relative virtual_path before
  -- concatenation -- deterministic output is a prerequisite for
  -- content-hashing it (see docs/LUAX_BALLAD_CSS_ASSETS_PLAN.md section 2.3).
  local sheets = {}
  for _, input_set in ipairs(inputs or {}) do
    for _, asset in ipairs(input_set.assets) do
      if asset.virtual_path and asset.virtual_path:match("%.css$") then
        table.insert(sheets, asset)
      end
    end
  end
  table.sort(sheets, function(a, b) return a.virtual_path < b.virtual_path end)

  if #sheets == 0 and not include_reset then
    return graph.AssetSet.new()
  end

  local parts = {}
  if include_reset then
    -- A real path on disk, not embedded as a Lua string constant --
    -- keeps reset.css a genuinely editable, reviewable CSS file.
    local reset_path = find_reset_css()
    if not reset_path then
      ctx.fail("hydronium_ballad.plugins.style.bundle: reset=true but could not locate hydronium_dom/css/reset.css "
        .. "on package.path (via require('hydronium_dom.css')'s own resolved location) -- "
        .. "pass reset=false to opt out, or ensure hydronium-dom is a real dependency")
    end
    table.insert(parts, "/* hydronium_dom/css/reset.css */\n" .. read_file(reset_path))
  end

  for _, asset in ipairs(sheets) do
    local content = asset.content
    if not content and asset.source_path then
      content = read_file(asset.source_path)
    end
    if content then
      local rewritten = rewrite_classes(content, asset.virtual_path)
      table.insert(parts, "/* " .. asset.virtual_path .. " */\n" .. rewritten)
    end
  end

  local body = table.concat(parts, "\n\n")
  local hash = require_real_hash(ctx, process.b3sum_string(body))
  local vpath = out_prefix .. bundle_name .. "-" .. hash:sub(1, hash_length) .. ".css"

  local out = graph.AssetSet.new()
  out:add(ctx.graph:add_asset({
    kind = "hy_style_bundle",
    generated = true,
    virtual_path = vpath,
    content = body,
    metadata = { hydronium = {
      url = "/" .. vpath,
      sheet_count = #sheets,
      reset = include_reset,
    }},
  }))
  return out
end

return {
  name = "hydronium_ballad.plugins.style",
  version = "0.1.0",
  methods = {
    -- cacheable=true: pure content transform, plain-data opts only.
    bundle = { inputs = { "asset_set" }, outputs = { "asset_set" }, cacheable = true, parallel_safe = true },
  },
  bundle = M.bundle,
}
