--- Hydronium HTML Utilities for SSR Serialization
local M = {}

-- The `style` prop's normalization (camelCase/kebab-case handling, the
-- unitless-number list, ordering) is SHARED with the browser DOM host
-- rather than implemented twice: `hydronium_dom.host.dom` applies the
-- same declarations through `CSSStyleDeclaration.setProperty`, and the
-- two must agree byte-for-byte or a styled element causes a hydration
-- mismatch. See that module's doc comment for the full rationale.
local style_util = require("hydronium_dom.style")

--- Strict HTML5 Void Elements (area, base, br, col, embed, hr, img, input, link, meta, param, source, track, wbr)
--- Must be serialized as `<tag attrs>` without self-closing slash or end tag.
--- Any children passed to void elements must throw an error.
M.VOID_ELEMENTS = {
  area = true,
  base = true,
  br = true,
  col = true,
  embed = true,
  hr = true,
  img = true,
  input = true,
  link = true,
  meta = true,
  param = true,
  source = true,
  track = true,
  wbr = true,
}

--- HTML Boolean Attributes
--- Truthy renders as ` name`; falsy/nil completely omitted.
M.BOOLEAN_ATTRIBUTES = {
  allowfullscreen = true,
  async = true,
  autofocus = true,
  autoplay = true,
  checked = true,
  controls = true,
  default = true,
  defer = true,
  disabled = true,
  formnovalidate = true,
  hidden = true,
  inert = true,
  ismap = true,
  itemscope = true,
  loop = true,
  multiple = true,
  muted = true,
  nomodule = true,
  novalidate = true,
  open = true,
  playsinline = true,
  readonly = true,
  required = true,
  reversed = true,
  selected = true,
}

--- SVG is case-sensitive XML, unlike HTML5. A handful of real SVG element
--- names use camelCase and MUST keep it -- naively lowercasing them (as
--- HTML tag names normally are) produces an element the SVG spec doesn't
--- recognize (e.g. `<lineargradient>` is not `<linearGradient>`).
--- Keyed by lowercase for case-insensitive lookup regardless of how the
--- caller wrote the tag; not exhaustive of the full SVG spec, but covers
--- the commonly-used camelCase elements.
M.SVG_TAG_CASING = {
  lineargradient = "linearGradient",
  radialgradient = "radialGradient",
  clippath = "clipPath",
  textpath = "textPath",
  foreignobject = "foreignObject",
  animatemotion = "animateMotion",
  animatetransform = "animateTransform",
  fegaussianblur = "feGaussianBlur",
  fecolormatrix = "feColorMatrix",
  feblend = "feBlend",
  fecomposite = "feComposite",
  feflood = "feFlood",
  femerge = "feMerge",
  femergenode = "feMergeNode",
  feoffset = "feOffset",
  feturbulence = "feTurbulence",
  fedisplacementmap = "feDisplacementMap",
  feimage = "feImage",
  fetile = "feTile",
  fedropshadow = "feDropShadow",
  feconvolvematrix = "feConvolveMatrix",
  fediffuselighting = "feDiffuseLighting",
  fespecularlighting = "feSpecularLighting",
  fepointlight = "fePointLight",
  fespotlight = "feSpotLight",
  fedistantlight = "feDistantLight",
  fefuncr = "feFuncR",
  fefuncg = "feFuncG",
  fefuncb = "feFuncB",
  fefunca = "feFuncA",
  fecomponenttransfer = "feComponentTransfer",
}

--- SVG elements whose *attribute* names also need SVG-specific casing (see
--- SVG_ATTRIBUTE_ALIASES below) rather than being passed through as-is the
--- way ordinary/custom HTML attributes are. Keyed by lowercase tag name.
--- Deliberately broad (covers standard shape/container/gradient/filter
--- elements) but not a full SVG spec enumeration.
M.SVG_TAGS = {}
for _, name in ipairs({
  "svg", "path", "circle", "rect", "line", "polyline", "polygon", "g", "text",
  "tspan", "defs", "use", "symbol", "mask", "pattern", "stop", "image",
  "ellipse", "marker", "switch", "view", "desc", "title", "metadata",
  "animate", "set", "mpath", "filter",
}) do
  M.SVG_TAGS[name] = true
end
for lower_name, cased_name in pairs(M.SVG_TAG_CASING) do
  M.SVG_TAGS[lower_name] = true
  M.SVG_TAGS[cased_name] = true
end

--- Common SVG presentation attributes that are camelCase as authored
--- (matching the DOM property name, same convention as `strokeWidth` etc.
--- in JSX) but must serialize as kebab-case in the actual SVG/XML output.
--- Keyed by lowercase for case-insensitive lookup. Not exhaustive.
M.SVG_ATTRIBUTE_ALIASES = {
  stopcolor = "stop-color",
  stopopacity = "stop-opacity",
  strokewidth = "stroke-width",
  strokedasharray = "stroke-dasharray",
  strokedashoffset = "stroke-dashoffset",
  strokelinecap = "stroke-linecap",
  strokelinejoin = "stroke-linejoin",
  strokemiterlimit = "stroke-miterlimit",
  strokeopacity = "stroke-opacity",
  fillopacity = "fill-opacity",
  fillrule = "fill-rule",
  cliprule = "clip-rule",
  fontfamily = "font-family",
  fontsize = "font-size",
  fontweight = "font-weight",
  fontstyle = "font-style",
  textanchor = "text-anchor",
  gradientunits = "gradientUnits", -- already correct casing; listed for clarity
  gradienttransform = "gradientTransform",
  patternunits = "patternUnits",
  patterncontenunits = "patternContentUnits",
  markerwidth = "markerWidth",
  markerheight = "markerHeight",
  markerunits = "markerUnits",
  preserveaspectratio = "preserveAspectRatio",
  spreadmethod = "spreadMethod",
}

--- CSS Properties that remain unitless when numbers are provided.
--- Re-exported from `hydronium_dom.style` so the SSR serializer and the
--- browser DOM host cannot drift apart on which properties take "px".
M.UNITLESS_NUMBER_PROPS = style_util.UNITLESS_NUMBER_PROPS

--- HTML escaping: escapes '&' first, then '<', '>', '"', and '\''
--- @param str string|any Input string or value
--- @return string Escaped HTML string
function M.escape_html(str)
  if str == nil then return "" end
  if type(str) ~= "string" then str = tostring(str) end
  str = str:gsub("&", "&amp;")
  str = str:gsub("<", "&lt;")
  str = str:gsub(">", "&gt;")
  str = str:gsub('"', "&quot;")
  str = str:gsub("'", "&#39;")
  return str
end

--- Sanitizes <script> contents to prevent </script> breakout attacks
--- @param str string Raw script content
--- @return string Sanitized script content
function M.escape_script_content(str)
  if str == nil then return "" end
  if type(str) ~= "string" then str = tostring(str) end
  return (str:gsub("</[sS][cC][rR][iI][pP][tT]", "<\\/script"))
end

--- Sanitizes <style> contents to prevent </style> breakout attacks
--- @param str string Raw style content
--- @return string Sanitized style content
function M.escape_style_content(str)
  if str == nil then return "" end
  if type(str) ~= "string" then str = tostring(str) end
  return (str:gsub("</[sS][tT][yY][lL][eE]", "<\\/style"))
end

--- Reject tag names which could otherwise break out of server-generated HTML.
--- Custom elements and namespace-like SVG names remain supported.
function M.is_valid_tag_name(tag)
  return type(tag) == "string" and tag:match("^[A-Za-z][A-Za-z0-9:_%-]*$") ~= nil
end

function M.is_valid_attribute_name(name)
  return type(name) == "string" and name:match("^[A-Za-z_:][A-Za-z0-9:_.%-]*$") ~= nil
end

--- Converts camelCase property names to kebab-case
--- e.g. "backgroundColor" -> "background-color"
--- @param str string CamelCase property name
--- @return string kebab-case property name
--- Re-exported from `hydronium_dom.style` (see the note at the top of
--- this file): the client host derives CSS property names with the very
--- same function, so the two can never disagree.
M.camel_to_kebab = style_util.camel_to_kebab

--- Evaluates reactive values (signals, computeds) if needed
local function evaluate_value(val)
  if type(val) == "function" then
    return val
  elseif type(val) == "table" then
    if val._typeof and (tostring(val._typeof):find("signal") or tostring(val._typeof):find("computed")) then
      if type(val.get) == "function" then
        return evaluate_value(val:get())
      elseif type(val.read) == "function" then
        return evaluate_value(val:read())
      end
    end
    if val._is_signal or val._is_computed then
      if type(val.get) == "function" then
        return evaluate_value(val:get())
      end
    end
    local mt = getmetatable(val)
    if mt and mt.__call and (val._is_signal or val._is_computed) then
      local ok, res = pcall(val)
      if ok then return evaluate_value(res) end
    end
  end
  return val
end

M.evaluate_value = evaluate_value

--- Serializes a CSS style table into a deterministic, escaped CSS string.
--- Properties are sorted alphabetically; non-unitless numbers have "px" appended.
--- @param style table|string CSS style table or string
--- @return string Serialized CSS style string
--- The CSS text itself comes from the shared normalizer -- byte-for-byte
--- the same string `hydronium_dom.host.dom` applies on the client. The
--- ONLY thing this function adds is HTML escaping, which is required here
--- and only here, because this result is embedded inside a quoted HTML
--- attribute rather than handed to a DOM API.
---
--- So the consistency invariant between SSR and client is exact and
--- checkable: `escape_html(style.serialize(s))` is what SSR emits, and
--- `style.serialize(s)` is what the client applies -- i.e. unescaping the
--- SSR attribute yields the client's CSS text. `tests/host/style_spec.lua`
--- asserts precisely that for every shape a style prop can take.
function M.serialize_style(style)
  return M.escape_html(style_util.serialize(style))
end

--- Deterministically serializes an attributes/props table to an HTML attribute string.
--- Attributes are sorted alphabetically (a-z).
--- @param props table VNode props
--- @param tag_lower string? Lowercased tag name of the element these props belong
---   to; when it's a known SVG element (M.SVG_TAGS), camelCase presentation
---   attributes are aliased to their real SVG/XML kebab-case names
---   (M.SVG_ATTRIBUTE_ALIASES) instead of being passed through as-is the way
---   ordinary/custom HTML attributes are.
--- @return string Attribute string starting with a leading space if non-empty
function M.serialize_attributes(props, tag_lower)
  if not props or (type(props) ~= "table" and type(props) ~= "userdata") then
    return ""
  end

  local raw_props = (type(props) == "table" and props._store) or props
  local normalized = {}

  -- Handle class / className alias
  local class_val = evaluate_value(raw_props.class or raw_props.className)
  if class_val ~= nil and class_val ~= false and class_val ~= "" then
    normalized["class"] = class_val
  end

  for k, raw_v in pairs(raw_props) do
    if type(k) ~= "string" then
      error("SSR attributes must use string keys", 2)
    end
    -- Ignore internal framework properties, _store proxy field, and event handlers
    if k ~= "class" and k ~= "className" and k ~= "key" and k ~= "ref"
       and k ~= "children" and k ~= "__source" and k ~= "dangerouslySetInnerHTML"
       and k ~= "unsafe_raw_html" and k ~= "_store" and type(raw_v) ~= "function" then

      if not M.is_valid_attribute_name(k) then
        error("Invalid SSR attribute name: " .. k, 2)
      end

      local v = evaluate_value(raw_v)
      local lower_k = k:lower()
      local is_event = lower_k:sub(1, 2) == "on" and (#k > 2)

      -- SVG attribute name resolution happens before the boolean/aria/data
      -- checks below: an SVG presentation attribute like `strokeWidth` is
      -- not a boolean attribute and not aria-*/data-*, so without this it
      -- would fall to the general-attribute branch and be emitted verbatim
      -- (`strokeWidth="2"`), which real SVG/XML does not recognize.
      local out_key = k
      if tag_lower and M.SVG_TAGS[tag_lower] then
        out_key = M.SVG_ATTRIBUTE_ALIASES[lower_k] or k
      end

      if not is_event then
        if k == "style" then
          local serialized = M.serialize_style(v)
          if serialized ~= "" then
            normalized["style"] = serialized
          end
        elseif M.BOOLEAN_ATTRIBUTES[lower_k] then
          -- HTML boolean attribute: true -> presence, false/nil -> omitted
          if v then
            normalized[lower_k] = true
          end
        elseif k:sub(1, 5) == "aria-" or k:sub(1, 5) == "data-" then
          -- ARIA and data attributes: boolean false must be serialized as "false"
          if v == false then
            normalized[k] = "false"
          elseif v == true then
            normalized[k] = "true"
          elseif v ~= nil then
            normalized[k] = M.escape_html(v)
          end
        else
          -- General attribute (including SVG presentation attributes
          -- resolved to out_key above): boolean false serialized as
          -- "false", true as "true"
          if v == false then
            normalized[out_key] = "false"
          elseif v == true then
            normalized[out_key] = "true"
          elseif v ~= nil then
            normalized[out_key] = M.escape_html(v)
          end
        end
      end
    end
  end

  -- Sort attributes alphabetically for deterministic SSR output
  local sorted_keys = {}
  for k in pairs(normalized) do
    table.insert(sorted_keys, k)
  end
  table.sort(sorted_keys)

  local chunks = {}
  for _, k in ipairs(sorted_keys) do
    local v = normalized[k]
    if v == true then
      table.insert(chunks, " " .. k)
    else
      table.insert(chunks, string.format(' %s="%s"', k, tostring(v)))
    end
  end

  return table.concat(chunks)
end

return M
