--- Hydronium HTML Utilities for SSR Serialization
local M = {}

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

--- CSS Properties that remain unitless when numbers are provided
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
  strokeopacity = true,
  ["stroke-opacity"] = true,
}

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

--- Converts camelCase property names to kebab-case
--- e.g. "backgroundColor" -> "background-color"
--- @param str string CamelCase property name
--- @return string kebab-case property name
function M.camel_to_kebab(str)
  local s = str:gsub("(%u)", "-%1"):lower()
  if s:sub(1, 1) == "-" then
    s = s:sub(2)
  end
  return s
end

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
function M.serialize_style(style)
  if type(style) == "string" then
    return M.escape_html(style)
  end
  if type(style) ~= "table" then
    return ""
  end

  local raw_style = (type(style) == "table" and style._store) or style
  local keys = {}
  for k in pairs(raw_style) do
    if k ~= "_store" then
      table.insert(keys, k)
    end
  end
  table.sort(keys)

  local parts = {}
  for _, k in ipairs(keys) do
    local v = evaluate_value(raw_style[k])
    if v ~= nil and v ~= false and v ~= "" then
      local kebab = M.camel_to_kebab(k)
      local val_str
      if type(v) == "number" then
        local lower_k = k:lower()
        if M.UNITLESS_NUMBER_PROPS[lower_k] or M.UNITLESS_NUMBER_PROPS[kebab] then
          val_str = tostring(v)
        else
          val_str = tostring(v) .. "px"
        end
      else
        val_str = tostring(v)
      end
      table.insert(parts, kebab .. ": " .. val_str)
    end
  end

  if #parts == 0 then
    return ""
  end

  return M.escape_html(table.concat(parts, "; "))
end

--- Deterministically serializes an attributes/props table to an HTML attribute string.
--- Attributes are sorted alphabetically (a-z).
--- @param props table VNode props
--- @return string Attribute string starting with a leading space if non-empty
function M.serialize_attributes(props)
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
    -- Ignore internal framework properties, _store proxy field, and event handlers
    if k ~= "class" and k ~= "className" and k ~= "key" and k ~= "ref"
       and k ~= "children" and k ~= "__source" and k ~= "dangerouslySetInnerHTML"
       and k ~= "unsafe_raw_html" and k ~= "_store" and type(raw_v) ~= "function" then

      local v = evaluate_value(raw_v)
      local lower_k = k:lower()
      local is_event = lower_k:sub(1, 2) == "on" and (#k > 2)

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
          -- General attribute: boolean false serialized as "false", true as "true"
          if v == false then
            normalized[k] = "false"
          elseif v == true then
            normalized[k] = "true"
          elseif v ~= nil then
            normalized[k] = M.escape_html(v)
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
