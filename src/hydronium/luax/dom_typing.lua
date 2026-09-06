-- DOM typing definitions for LuaLS / EmmyLua
-- Provides typed intrinsics, event hierarchy, and contextual callback typing
local M = {}

M.DOM_DEFINITIONS = [[
---@meta Hydronium LUAX DOM Typings

---@class SyntheticEvent<T>
---@field target T
---@field currentTarget T
---@field preventDefault fun()
---@field stopPropagation fun()
---@field isDefaultPrevented fun(): boolean
---@field isPropagationStopped fun(): boolean

---@class SyntheticMouseEvent<T> : SyntheticEvent<T>
---@field clientX number
---@field clientY number
---@field pageX number
---@field pageY number
---@field screenX number
---@field screenY number
---@field button number
---@field altKey boolean
---@field ctrlKey boolean
---@field metaKey boolean
---@field shiftKey boolean

---@class SyntheticKeyboardEvent<T> : SyntheticEvent<T>
---@field key string
---@field code string
---@field altKey boolean
---@field ctrlKey boolean
---@field metaKey boolean
---@field shiftKey boolean
---@field repeat boolean

---@class SyntheticFocusEvent<T> : SyntheticEvent<T>
---@field relatedTarget? any

---@class SyntheticChangeEvent<T> : SyntheticEvent<T>
---@field value string

--- Host DOM element types
---@class HTMLElement
---@field id string
---@field className string

---@class HTMLButtonElement : HTMLElement
---@field disabled boolean
---@field type string

---@class HTMLInputElement : HTMLElement
---@field value string
---@field checked boolean
---@field type string
---@field placeholder string

---@class HTMLDivElement : HTMLElement
---@class HTMLSpanElement : HTMLElement
---@class HTMLAnchorElement : HTMLElement
---@field href string
---@field target string

--- Prop definitions
---@class HTMLAttributes
---@field id? string
---@field class? string
---@field className? string
---@field style? string|table<string, any>
---@field key? string|number
---@field ref? any
---@field children? any

---@class HTMLButtonProps : HTMLAttributes
---@field type? "button"|"submit"|"reset"
---@field disabled? boolean
---@field onClick? fun(event: SyntheticMouseEvent<HTMLButtonElement>)

---@class HTMLInputProps : HTMLAttributes
---@field type? "text"|"password"|"checkbox"|"radio"|"number"|"submit"|"email"
---@field value? string|number
---@field checked? boolean
---@field placeholder? string
---@field disabled? boolean
---@field onChange? fun(event: SyntheticChangeEvent<HTMLInputElement>)
---@field onInput? fun(event: SyntheticChangeEvent<HTMLInputElement>)
---@field onFocus? fun(event: SyntheticFocusEvent<HTMLInputElement>)
---@field onBlur? fun(event: SyntheticFocusEvent<HTMLInputElement>)

---@class HTMLDivProps : HTMLAttributes
---@field onClick? fun(event: SyntheticMouseEvent<HTMLDivElement>)

---@class HTMLSpanProps : HTMLAttributes
---@field onClick? fun(event: SyntheticMouseEvent<HTMLSpanElement>)

---@class HTMLAnchorProps : HTMLAttributes
---@field href? string
---@field target? string
---@field onClick? fun(event: SyntheticMouseEvent<HTMLAnchorElement>)

--- Catalog of intrinsic elements for LuaLS virtual lowering
---@class __luax_intrinsic_catalog
---@field button fun(props?: HTMLButtonProps, ...: any): any
---@field input fun(props?: HTMLInputProps, ...: any): any
---@field div fun(props?: HTMLDivProps, ...: any): any
---@field span fun(props?: HTMLSpanProps, ...: any): any
---@field a fun(props?: HTMLAnchorProps, ...: any): any
---@field p fun(props?: HTMLAttributes, ...: any): any
---@field h1 fun(props?: HTMLAttributes, ...: any): any
---@field h2 fun(props?: HTMLAttributes, ...: any): any
---@field h3 fun(props?: HTMLAttributes, ...: any): any
---@field ul fun(props?: HTMLAttributes, ...: any): any
---@field ol fun(props?: HTMLAttributes, ...: any): any
---@field li fun(props?: HTMLAttributes, ...: any): any
---@field form fun(props?: HTMLAttributes, ...: any): any
---@field label fun(props?: HTMLAttributes, ...: any): any

---@type __luax_intrinsic_catalog
__luax_intrinsic = {}

--- Helper for virtual lowering of custom components
---@generic T, P
---@param comp fun(props: P): T
---@param props P
---@return T
function __luax_component(comp, props, ...)
  return comp(props)
end

--- Helper for virtual lowering of fragments
---@param ... any
---@return any
function __luax_fragment(...)
  return ...
end
]]

function M.get_dom_definitions()
  return M.DOM_DEFINITIONS
end

-- Generate a standalone .d.lua file
function M.write_definitions_file(path)
  local f = io.open(path, "w")
  if not f then
    error("Could not write DOM definitions to: " .. tostring(path))
  end
  f:write(M.DOM_DEFINITIONS)
  f:close()
  return true
end

return M
