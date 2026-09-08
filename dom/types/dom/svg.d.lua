---@meta
--[[
  Hydronium SVG Elements & Props Type Definitions
  Generated from WebRef specifications
--]]

--- Base SVG DOM Element representation
---@class SVGElement
---@field tagName string
---@field id string
---@field style table<string, any>

--- Standard SVG attributes shared across SVG elements
---@class SVGAttributes : LuaxProps
---@field id? string
---@field className? string
---@field class? string
---@field style? table<string, any> | string
---@field fill? string
---@field stroke? string
---@field strokeWidth? number | string
---@field transform? string
---@field key? any
---@field ref? any
---@field children? any

---@class SVGSVGElement : SVGElement

--- Props for <svg> element
---@class SVGSVGProps : SVGAttributes
---@field width number | string?
---@field height number | string?
---@field viewBox string?
---@field xmlns string?

---@class SVGPathElement : SVGElement

--- Props for <path> element
---@class SVGPathProps : SVGAttributes
---@field d string?
---@field fill string?
---@field stroke string?
---@field strokeWidth number | string?

---@class SVGCircleElement : SVGElement

--- Props for <circle> element
---@class SVGCircleProps : SVGAttributes
---@field cx number | string?
---@field cy number | string?
---@field r number | string?
---@field fill string?
---@field stroke string?

---@class SVGRectElement : SVGElement

--- Props for <rect> element
---@class SVGRectProps : SVGAttributes
---@field x number | string?
---@field y number | string?
---@field width number | string?
---@field height number | string?
---@field rx number | string?
---@field ry number | string?
---@field fill string?

---@class SVGGElement : SVGElement

--- Props for <g> element
---@class SVGGProps : SVGAttributes
---@field fill string?
---@field stroke string?
---@field transform string?

---@class SVGTextElement : SVGElement

--- Props for <text> element
---@class SVGTextProps : SVGAttributes
---@field x number | string?
---@field y number | string?
---@field fill string?
---@field fontSize number | string?
---@field fontFamily string?
