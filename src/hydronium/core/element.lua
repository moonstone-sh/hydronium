--[[
  Hydronium Element & VNode Factory
  Strict child normalization, varargs safety with select("#", ...), immutability,
  and VNode construction. Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local suspense = require("hydronium.core.suspense")

local unpack = table.unpack or unpack

local elementModule = {}

local function freezeProps(t)
  if type(t) ~= "table" then return t end
  local proxy = {}
  local mt = {
    __index = t,
    __newindex = function(_, k, _)
      error("Cannot modify immutable property: " .. tostring(k), 2)
    end,
    __pairs = function() return next, t, nil end,
    __tostring = function() return "ImmutableTable" end,
  }
  proxy._store = t
  return setmetatable(proxy, mt)
end

local function freezeChildren(childrenList)
  if type(childrenList) ~= "table" then return childrenList end
  if newproxy then
    local proxy = newproxy(true)
    local mt = getmetatable(proxy)
    mt.__index = childrenList
    mt.__len = function() return #childrenList end
    mt.__newindex = function(_, k, _)
      error("Cannot modify immutable property: " .. tostring(k), 2)
    end
    return proxy
  else
    local proxy = {}
    local mt = {
      __index = childrenList,
      __len = function() return #childrenList end,
      __newindex = function(_, k, _)
        error("Cannot modify immutable property: " .. tostring(k), 2)
      end,
      __pairs = function() return ipairs(childrenList) end,
      __ipairs = function() return ipairs(childrenList) end,
    }
    return setmetatable(proxy, mt)
  end
end

local function freezeVNode(raw)
  local proxy = {}
  local mt = {
    __index = raw,
    __newindex = function(_, k, v)
      if k == "tag" or k == "key" or k == "ref" or k == "kind" or k == "_is_element" then
        error("Cannot modify immutable VNode property: " .. tostring(k), 2)
      else
        raw[k] = v
      end
    end,
    __pairs = function() return next, raw, nil end,
    __tostring = function()
      return string.format("VNode(%s)", tostring(raw.tag or raw.kind or "VNode"))
    end,
  }
  return setmetatable(proxy, mt)
end

local function createTextVNode(text)
  local raw = {
    _typeof = symbols.VNODE,
    kind = symbols.TEXT,
    tag = nil,
    props = freezeProps({}),
    children = freezeChildren({}),
    key = nil,
    ref = nil,
    text = tostring(text),
  }
  return freezeVNode(raw)
end

--- Recursively flattens and normalizes child values.
--- Discards nil, false, true.
--- Converts numbers to strings and wraps as TEXT VNodes.
--- Wraps raw strings as TEXT VNodes.
--- Flattens nested tables into a contiguous 1-indexed array.
local function flattenChildren(item, out)
  if item == nil or item == false or item == true then
    return
  end

  local itemType = type(item)

  if itemType == "number" then
    table.insert(out, createTextVNode(tostring(item)))
  elseif itemType == "string" then
    table.insert(out, createTextVNode(item))
  elseif itemType == "userdata" then
    local len = #item
    for i = 1, len do
      flattenChildren(item[i], out)
    end
  elseif itemType == "table" then
    if item._typeof == symbols.VNODE then
      table.insert(out, item)
    else
      local len = #item
      if len > 0 then
        for i = 1, len do
          flattenChildren(item[i], out)
        end
      else
        for k, v in pairs(item) do
          if type(k) == "number" then
            flattenChildren(v, out)
          end
        end
      end
    end
  end
end

--- Create a Virtual DOM element (VNode).
--- Complies with Amendment 1: handles child normalization safely using select("#", ...).
function elementModule.createElement(tag, props, ...)
  local normalizedProps = {}
  local key = nil
  local ref = nil

  if type(props) == "table" then
    for k, v in pairs(props) do
      if k == "key" then
        key = v
      elseif k == "ref" then
        ref = v
      else
        normalizedProps[k] = v
      end
    end
  end

  local children = {}
  local varargCount = select("#", ...)

  if varargCount > 0 then
    for i = 1, varargCount do
      local child = select(i, ...)
      flattenChildren(child, children)
    end
  elseif props and props.children ~= nil then
    flattenChildren(props.children, children)
  end

  normalizedProps.children = freezeChildren(children)

  local resolvedTag = tag
  if type(tag) == "table" and (tag["$$typeof"] == symbols.INTRINSIC or tag._typeof == symbols.INTRINSIC) then
    resolvedTag = tag.tag
  end

  local kind
  local is_island_descriptor = type(tag) == "table" and tag["$$typeof"] == symbols.ISLAND_DESCRIPTOR
  local is_script_descriptor = type(tag) == "table" and tag["$$typeof"] == symbols.SCRIPT_DESCRIPTOR
  if is_island_descriptor then
    -- Unlike INTRINSIC, keep the full descriptor as the resolved tag: the
    -- server renderer needs its interpreter/module/mode/root metadata,
    -- not just a bare string like intrinsic HTML tags unwrap to.
    resolvedTag = tag
    kind = symbols.ISLAND
  elseif is_script_descriptor then
    resolvedTag = tag
    kind = symbols.SCRIPT
  elseif resolvedTag == symbols.FRAGMENT then
    kind = symbols.FRAGMENT
  elseif resolvedTag == errors.ErrorBoundary then
    kind = symbols.BOUNDARY
  elseif resolvedTag == suspense.Suspense then
    kind = symbols.SUSPENSE
  elseif type(resolvedTag) == "function" or (type(resolvedTag) == "table" and (resolvedTag.__context or (getmetatable(resolvedTag) and getmetatable(resolvedTag).__call))) then
    kind = symbols.COMPONENT
  elseif type(resolvedTag) == "string" then
    kind = symbols.ELEMENT
  else
    kind = symbols.ELEMENT
  end

  local raw = {
    _typeof = symbols.VNODE,
    kind = kind,
    tag = resolvedTag,
    props = freezeProps(normalizedProps),
    children = freezeChildren(children),
    key = key,
    ref = ref,
    text = nil,
  }

  return freezeVNode(raw)
end

elementModule.h = elementModule.createElement
elementModule.create_element = elementModule.createElement
elementModule.Fragment = symbols.FRAGMENT
elementModule.createTextVNode = createTextVNode
elementModule.flattenChildren = flattenChildren
elementModule.freezeTable = freezeProps

function elementModule.isElement(val)
  return type(val) == "table" and val._typeof == symbols.VNODE
end
elementModule.is_element = elementModule.isElement

function elementModule.isFragment(val)
  return val == symbols.FRAGMENT or (type(val) == "table" and val.kind == symbols.FRAGMENT)
end
elementModule.is_fragment = elementModule.isFragment

return elementModule
