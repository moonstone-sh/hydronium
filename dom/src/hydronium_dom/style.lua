--[[
  hydronium_dom.style -- the single, shared normalization of a `style`
  prop into real CSS property names and values.

  WHY THIS MODULE EXISTS (and why it is a leaf with no requires):

  A `style` prop has to be turned into CSS in two completely different
  places that must agree byte-for-byte:

    * SSR (`hydronium_dom.server.html.serialize_style`), which builds an
      inline `style="..."` attribute string, and
    * the browser DOM host (`hydronium_dom.host.dom`), which applies each
      property individually through `CSSStyleDeclaration.setProperty` so
      that a re-render can add/update/remove ONE property without
      clobbering unrelated properties some other code path may have set.

  If those two derived their CSS independently, any divergence (a
  different camelCase rule, a different unitless-number list, a different
  ordering) would surface as a hydration mismatch: the server would emit
  one string, the client would compute another for the same input, and
  the reconciler would see a difference that no application code caused.
  That class of bug is notoriously hard to diagnose, so this module makes
  agreement structural rather than a convention two files each promise to
  follow -- there is exactly one implementation and both callers use it.

  `hydronium_dom.host.dom` is deliberately dependency-free so it can be
  loaded inside a browser Lua VM (wasmoon) without dragging the SSR
  serializer's HTML tables along, which is why this normalization lives
  here rather than in `server/html.lua`. This module requires nothing.

  KEY CASE: both camelCase and kebab-case are accepted.

  `camel_to_kebab` is a no-op on a name that has no uppercase letters, so
  `{ backgroundColor = "red" }` (React's spelling) and
  `{ ["background-color"] = "red" }` (Solid's spelling, and real CSS's
  own spelling) both normalize to `background-color`. Accepting both is
  strictly better than picking one: `setProperty` takes kebab-case
  natively, and the SSR serializer has shipped the camelCase conversion
  since before this module existed, with tests covering it.
--]]

local M = {}

--- CSS properties whose numeric values are unitless -- every OTHER
--- numeric value gets "px" appended, matching what React/Preact/Solid do
--- so that `{ width = 200 }` means 200px rather than an invalid
--- declaration. Both spellings of each name are listed so a lookup works
--- whether the caller normalized first or not.
M.UNITLESS_NUMBER_PROPS = {
  animationiterationcount = true,
  ["animation-iteration-count"] = true,
  borderimageoutset = true,
  ["border-image-outset"] = true,
  borderimageslice = true,
  ["border-image-slice"] = true,
  borderimagewidth = true,
  ["border-image-width"] = true,
  boxflex = true,
  ["box-flex"] = true,
  boxflexgroup = true,
  ["box-flex-group"] = true,
  boxordinalgroup = true,
  ["box-ordinal-group"] = true,
  columncount = true,
  ["column-count"] = true,
  columns = true,
  flex = true,
  flexgrow = true,
  ["flex-grow"] = true,
  flexpositive = true,
  ["flex-positive"] = true,
  flexshrink = true,
  ["flex-shrink"] = true,
  flexnegative = true,
  ["flex-negative"] = true,
  flexorder = true,
  ["flex-order"] = true,
  gridarea = true,
  ["grid-area"] = true,
  gridrow = true,
  ["grid-row"] = true,
  gridrowend = true,
  ["grid-row-end"] = true,
  gridrowspan = true,
  ["grid-row-span"] = true,
  gridrowstart = true,
  ["grid-row-start"] = true,
  gridcolumn = true,
  ["grid-column"] = true,
  gridcolumnend = true,
  ["grid-column-end"] = true,
  gridcolumnspan = true,
  ["grid-column-span"] = true,
  gridcolumnstart = true,
  ["grid-column-start"] = true,
  fontweight = true,
  ["font-weight"] = true,
  lineclamp = true,
  ["line-clamp"] = true,
  lineheight = true,
  ["line-height"] = true,
  opacity = true,
  order = true,
  orphans = true,
  tabsize = true,
  ["tab-size"] = true,
  widows = true,
  zindex = true,
  ["z-index"] = true,
  zoom = true,
  fillopacity = true,
  ["fill-opacity"] = true,
  floodopacity = true,
  ["flood-opacity"] = true,
  stopopacity = true,
  ["stop-opacity"] = true,
  strokedasharray = true,
  ["stroke-dasharray"] = true,
  strokedashoffset = true,
  ["stroke-dashoffset"] = true,
  strokemiterlimit = true,
  ["stroke-miterlimit"] = true,
  strokeopacity = true,
  ["stroke-opacity"] = true,
  strokewidth = true,
  ["stroke-width"] = true,
}

--- "backgroundColor" -> "background-color"; "background-color" ->
--- "background-color" (unchanged, since there is no uppercase to split
--- on). Leading "-" is trimmed so a vendor-prefixed camelCase name like
--- "WebkitTransform" becomes "webkit-transform" rather than
--- "-webkit-transform" -- preserved from the original SSR implementation
--- this was extracted from, so its behavior does not change.
--- @param str string
--- @return string
function M.camel_to_kebab(str)
  local s = str:gsub("(%u)", "-%1"):lower()
  if s:sub(1, 1) == "-" then
    s = s:sub(2)
  end
  return s
end

--- Unwraps a reactive value (signal/computed) to its current value.
--- Mirrors the SSR serializer's own `evaluate_value` so a signal used as
--- a style value behaves identically on both sides.
--- @param val any
--- @return any
function M.evaluate_value(val)
  if type(val) == "function" then
    return val
  elseif type(val) == "table" then
    if val._typeof and (tostring(val._typeof):find("signal") or tostring(val._typeof):find("computed")) then
      if type(val.get) == "function" then
        return M.evaluate_value(val:get())
      elseif type(val.read) == "function" then
        return M.evaluate_value(val:read())
      end
    end
    if val._is_signal or val._is_computed then
      if type(val.get) == "function" then
        return M.evaluate_value(val:get())
      end
    end
    local mt = getmetatable(val)
    if mt and mt.__call and (val._is_signal or val._is_computed) then
      local ok, res = pcall(val)
      if ok then return M.evaluate_value(res) end
    end
  end
  return val
end

--- Converts one already-normalized property's value to its CSS text.
--- @param kebab string kebab-case property name (used for the unitless lookup)
--- @param original_key string the key as authored (also consulted, so a
---   camelCase name matches the camelCase spellings in the unitless table)
--- @param v any the evaluated value
--- @return string
function M.value_to_css(kebab, original_key, v)
  if type(v) == "number" then
    if M.UNITLESS_NUMBER_PROPS[original_key:lower()] or M.UNITLESS_NUMBER_PROPS[kebab] then
      return tostring(v)
    end
    return tostring(v) .. "px"
  end
  return tostring(v)
end

--- Normalizes a style table into a deterministic, sorted list of real CSS
--- declarations.
---
--- Sorting is not cosmetic: it is what makes SSR output byte-stable
--- across runs (Lua's `pairs` order is not defined), which snapshot-style
--- SSR assertions and hydration comparisons both depend on.
---
--- A value of nil, false or "" drops the property entirely -- that is the
--- authoring spelling for "this property is not set", and it is what the
--- host's update path keys off to decide a property must be REMOVED.
---
--- @param style table a style table (may be a props proxy carrying `_store`)
--- @return table list of `{ name = <kebab>, value = <css text> }`, sorted by name
function M.normalize(style)
  local raw = (type(style) == "table" and style._store) or style
  if type(raw) ~= "table" then return {} end

  local keys = {}
  for k in pairs(raw) do
    if k ~= "_store" and type(k) == "string" then
      table.insert(keys, k)
    end
  end
  table.sort(keys)

  local out = {}
  for _, k in ipairs(keys) do
    local v = M.evaluate_value(raw[k])
    if v ~= nil and v ~= false and v ~= "" then
      local kebab = M.camel_to_kebab(k)
      table.insert(out, { name = kebab, value = M.value_to_css(kebab, k, v) })
    end
  end
  return out
end

--- Serializes a style prop to raw (UNESCAPED) CSS text.
---
--- A string style prop is passed through verbatim -- an author who wrote
--- raw CSS text gets exactly that CSS text.
---
--- The result is deliberately not HTML-escaped: this is real CSS, correct
--- for `CSSStyleDeclaration.cssText` and for `setAttribute` (which takes
--- raw text). The SSR path escapes this result itself, because only there
--- is the string being embedded inside an HTML attribute. That split is
--- the reason SSR and client agree: they share this CSS text, and escaping
--- is applied only by the one caller that needs it.
---
--- @param style table|string|nil
--- @return string
function M.serialize(style)
  if type(style) == "string" then
    return style
  end
  if type(style) ~= "table" then
    return ""
  end
  local decls = M.normalize(style)
  if #decls == 0 then return "" end
  local parts = {}
  for i = 1, #decls do
    parts[i] = decls[i].name .. ": " .. decls[i].value
  end
  return table.concat(parts, "; ")
end

--- Normalizes a style prop to a `{ [kebab-name] = css value }` map, for
--- diffing one render's style against the next.
--- @param style table|string|nil
--- @return table
function M.to_map(style)
  local map = {}
  if type(style) ~= "table" then return map end
  for _, d in ipairs(M.normalize(style)) do
    map[d.name] = d.value
  end
  return map
end

return M
