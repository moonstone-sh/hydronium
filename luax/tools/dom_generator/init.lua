--[[
  Hydronium Pure Lua WebRef DOM Type Generator
  Reads webref_data.lua and generates:
  - types/dom/events.d.lua
  - types/dom/html.d.lua
  - types/dom/svg.d.lua
  - types/dom/intrinsics.d.lua

  Does NOT generate types/luax.d.lua (that file lives at
  luax/types/luax.d.lua, hand-owned -- see generator.run()'s doc
  comment and docs/LUAX_HOST_TYPE_AUTHORING.md for why).
--]]

local webref = require("tools.dom_generator.webref_data")

local generator = {}

local function write_file(path, content)
  local f, err = io.open(path, "w")
  if not f then
    error("Failed to open file for writing: " .. tostring(path) .. ": " .. tostring(err), 2)
  end
  f:write(content)
  f:close()
end

-- =========================================================================
-- 1. Generate types/dom/events.d.lua
-- =========================================================================
function generator.generate_events()
  local lines = {
    "---@meta",
    "--[[",
    "  Hydronium Synthetic DOM Events Type Definitions",
    "  Generated from WebRef specifications",
    "--]]",
    "",
  }

  for _, ev in ipairs(webref.events) do
    if ev.description then
      table.insert(lines, "--- " .. ev.description)
    end
    local class_decl = "---@class " .. ev.name
    if ev.generic then
      class_decl = class_decl .. "<" .. ev.generic .. ">"
    end
    if ev.parent then
      class_decl = class_decl .. " : " .. ev.parent
    end
    table.insert(lines, class_decl)

    for _, f in ipairs(ev.fields) do
      local doc = f.doc and (" # " .. f.doc) or ""
      table.insert(lines, string.format("---@field %s %s%s", f.name, f.type, doc))
    end
    table.insert(lines, "")
  end

  table.insert(lines, "--- Generic event handler callback type")
  table.insert(lines, "---@alias EventHandler<E> fun(event: E): void")
  table.insert(lines, "")

  return table.concat(lines, "\n")
end

-- =========================================================================
-- 2. Generate types/dom/html.d.lua
-- =========================================================================
function generator.generate_html()
  local lines = {
    "---@meta",
    "--[[",
    "  Hydronium HTML Elements & Props Type Definitions",
    "  Generated from WebRef specifications",
    "--]]",
    "",
    "--- Base HTML DOM Element representation",
    "---@class HTMLElement",
    "---@field tagName string",
    "---@field id string",
    "---@field className string",
    "---@field style table<string, any>",
    "",
  }

  -- Specific element interfaces
  local seen_interfaces = {}
  for _, el in ipairs(webref.html_elements) do
    if el.interface ~= "HTMLElement" and not seen_interfaces[el.interface] then
      seen_interfaces[el.interface] = true
      table.insert(lines, string.format("---@class %s : HTMLElement", el.interface))
      for _, p in ipairs(el.specific_props) do
        table.insert(lines, string.format("---@field %s %s", p.name, p.type))
      end
      table.insert(lines, "")
    end
  end

  -- Common HTML attributes interface
  table.insert(lines, "--- Standard HTML attributes shared across all elements")
  table.insert(lines, "---@class HTMLAttributes : LuaxProps, { [integer]: any }")
  table.insert(lines, "---@field id? string")
  table.insert(lines, "---@field className? string")
  table.insert(lines, "---@field class? string")
  table.insert(lines, "---@field style? table<string, any> | string")
  table.insert(lines, "---@field title? string")
  table.insert(lines, "---@field role? string")
  table.insert(lines, "---@field tabIndex? integer")
  table.insert(lines, "---@field hidden? boolean")
  table.insert(lines, "---@field key? any")
  table.insert(lines, "---@field ref? any")
  table.insert(lines, "---@field children? any")

  -- Event handlers on HTMLAttributes
  for _, h in ipairs(webref.event_handlers) do
    table.insert(lines, string.format("---@field %s? fun(event: %s<HTMLElement>): void", h.prop, h.event))
  end
  table.insert(lines, "")

  -- Element specific prop tables
  for _, el in ipairs(webref.html_elements) do
    table.insert(lines, string.format("--- Props for <%s> element", el.tag))
    table.insert(lines, string.format("---@class %s : HTMLAttributes, { [integer]: any }", el.props_name))
    for _, p in ipairs(el.specific_props) do
      table.insert(lines, string.format("---@field %s %s", p.name, p.type))
    end
    -- Typed event handler overrides with specific element target
    for _, h in ipairs(webref.event_handlers) do
      table.insert(lines, string.format("---@field %s? fun(event: %s<%s>): void", h.prop, h.event, el.interface))
    end
    table.insert(lines, "")
  end

  return table.concat(lines, "\n")
end

-- =========================================================================
-- 3. Generate types/dom/svg.d.lua
-- =========================================================================
function generator.generate_svg()
  local lines = {
    "---@meta",
    "--[[",
    "  Hydronium SVG Elements & Props Type Definitions",
    "  Generated from WebRef specifications",
    "--]]",
    "",
    "--- Base SVG DOM Element representation",
    "---@class SVGElement",
    "---@field tagName string",
    "---@field id string",
    "---@field style table<string, any>",
    "",
    "--- Standard SVG attributes shared across SVG elements",
    "---@class SVGAttributes : LuaxProps",
    "---@field id? string",
    "---@field className? string",
    "---@field class? string",
    "---@field style? table<string, any> | string",
    "---@field fill? string",
    "---@field stroke? string",
    "---@field strokeWidth? number | string",
    "---@field transform? string",
    "---@field key? any",
    "---@field ref? any",
    "---@field children? any",
    "",
  }

  local seen_svg = {}
  for _, el in ipairs(webref.svg_elements) do
    if not seen_svg[el.interface] then
      seen_svg[el.interface] = true
      table.insert(lines, string.format("---@class %s : SVGElement", el.interface))
      table.insert(lines, "")
    end
    table.insert(lines, string.format("--- Props for <%s> element", el.tag))
    table.insert(lines, string.format("---@class %s : SVGAttributes", el.props_name))
    for _, p in ipairs(el.specific_props) do
      table.insert(lines, string.format("---@field %s %s", p.name, p.type))
    end
    table.insert(lines, "")
  end

  return table.concat(lines, "\n")
end

-- =========================================================================
-- 4. Generate types/dom/intrinsics.d.lua
-- =========================================================================
function generator.generate_intrinsics()
  local lines = {
    "---@meta",
    "--[[",
    "  Hydronium LUAX Intrinsics Catalog",
    "  Exposes typed intrinsic factory table and global intrinsic functions",
    "--]]",
    "",
    "---@class LuaxIntrinsics",
  }

  -- HTML tags on LuaxIntrinsics
  for _, el in ipairs(webref.html_elements) do
    table.insert(lines, string.format("---@field %s fun(props?: %s, ...: any): LuaxElement", el.tag, el.props_name))
  end

  -- SVG tags on LuaxIntrinsics
  for _, el in ipairs(webref.svg_elements) do
    table.insert(lines, string.format("---@field %s fun(props?: %s, ...: any): LuaxElement", el.tag, el.props_name))
  end

  table.insert(lines, "")
  table.insert(lines, "local intrinsics = {}")
  table.insert(lines, "return intrinsics")
  table.insert(lines, "")

  return table.concat(lines, "\n")
end

-- Note: this generator no longer writes types/luax.d.lua. That file
-- (luax/types/luax.d.lua) is the host-agnostic core LuaCATS catalog
-- (LuaxElement, hydronium.Intrinsic<P,H>, hydronium.ElementType<P,H>,
-- the __luax_* helpers) every host's own type catalog builds on -- see
-- docs/LUAX_HOST_TYPE_AUTHORING.md. It used to be (re-)generated from a
-- hardcoded string literal here that had no actual dependency on this
-- generator's webref/DOM data (verified: the removed `generate_luax()`
-- never referenced `webref` at all), which was pure incidental coupling
-- -- and had drifted stale enough that re-running it would have silently
-- deleted real, hand-added content (`hydronium.Intrinsic`/
-- `hydronium.ElementType` do not appear anywhere in the version this
-- function used to emit). `luax/types/luax.d.lua` is hand-owned directly
-- from here on; this generator only ever produces DOM's own spec-derived
-- catalog (events/html/svg/intrinsics below).

--- Generates DOM's own spec-derived typing files into target directory.
--- Does NOT touch types/luax.d.lua -- see the doc comment above
--- generate_luax()'s removal, further up this file, for why: it used to
--- write a hardcoded copy that had already drifted stale relative to the
--- real, hand-maintained file (missing hydronium.Intrinsic/
--- hydronium.ElementType entirely), so calling this used to risk
--- silently deleting real content on every re-run.
function generator.run(out_dir)
  out_dir = out_dir or "types"
  local dom_dir = out_dir .. "/dom"

  -- Ensure directory exists
  os.execute("mkdir -p " .. dom_dir)

  write_file(dom_dir .. "/events.d.lua", generator.generate_events())
  write_file(dom_dir .. "/html.d.lua", generator.generate_html())
  write_file(dom_dir .. "/svg.d.lua", generator.generate_svg())
  write_file(dom_dir .. "/intrinsics.d.lua", generator.generate_intrinsics())

  print("Generated DOM types in " .. out_dir)
end

return generator
