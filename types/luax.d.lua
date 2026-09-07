---@meta
--[[
  Hydronium LUAX Core Type Definitions & JSX/LuaCATS declarations
--]]

--- Virtual DOM element produced by LUAX elements and fragments
---@class LuaxElement
---@field tag string|function|table
---@field props table<string, any>
---@field children any[]
---@field key any
---@field ref any

--- Valid child nodes in LUAX templates
---@alias LuaxNode LuaxElement | string | number | boolean | nil | LuaxNode[]

--- Base component props dictionary supporting mixed array and hash fields
---@class LuaxProps : { [integer]: any }
---@field key? any
---@field ref? any
---@field children? LuaxNode

--- Functional component type receiving props and returning a LuaxNode
---@alias LuaxComponent<P> fun(props: P): LuaxNode

--- Intrinsic host element descriptor with callable instantiation and host metadata
---@class hydronium.Intrinsic<P, H>
---@field ["$$typeof"] any
---@field tag string
---@field host string
---@overload fun(props?: P, ...: any): LuaxElement

--- ElementType represents an intrinsic descriptor, functional component, or string tag
---@alias hydronium.ElementType<P, H> hydronium.Intrinsic<P, H> | (fun(props: P): LuaxNode) | string

--- Virtual lowering helper for typed element creation
---@generic P, H
---@param tag hydronium.ElementType<P, H>
---@param props? P
---@param ... any
---@return LuaxElement
function __luax_element(tag, props, ...) end

--- Helper for component prop verification in virtual source lowering
---@generic TProps
---@param component fun(props: TProps): any
---@param props TProps
---@return any
function __luax_component(component, props, ...) end

--- Fragment helper referenced by virtual-source LuaLS projection (`<>...</>`)
---@param props table?
---@param ... any
---@return LuaxElement
function __luax_fragment(props, ...) end

--- Runtime merge helper for JSX spread attributes
--- Evaluates left-to-right with later keys overwriting earlier keys
---@param ... table|nil
---@return table
function __luax.spread(...) end

--- Fragment creation helper
---@param props table?
---@param ... any
---@return LuaxElement
function __luax.fragment(props, ...) end

--- Element creation helper
---@param tag any
---@param props table?
---@param ... any
---@return LuaxElement
function __luax.element(tag, props, ...) end
