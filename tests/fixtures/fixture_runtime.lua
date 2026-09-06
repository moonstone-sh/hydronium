-- Independent "Starship UI" Runtime
-- Proves zero Hydronium coupling in LUAX compilation
local Starship = {
  _VERSION = "1.0.0-starship",
  Fragment = { __starship_fragment = true },
}

-- Create a Starship Virtual Node
function Starship.createElement(tag, props, ...)
  local children = {}
  local n = select("#", ...)
  for i = 1, n do
    local child = select(i, ...)
    if child ~= nil and child ~= false then
      if type(child) == "table" and child[1] ~= nil and not child._isStarshipNode then
        -- Flatten arrays of children
        for _, sub in ipairs(child) do
          if sub ~= nil and sub ~= false then
            table.insert(children, sub)
          end
        end
      else
        table.insert(children, child)
      end
    end
  end

  local vnode = {
    _isStarshipNode = true,
    tag = tag,
    props = props or {},
    children = children,
  }

  return vnode
end

Starship.h = Starship.createElement

-- Render Starship VNode tree to a string
function Starship.renderToString(vnode)
  if vnode == nil or vnode == false then
    return ""
  end

  if type(vnode) == "string" or type(vnode) == "number" then
    return tostring(vnode)
  end

  if type(vnode) ~= "table" or not vnode._isStarshipNode then
    return tostring(vnode)
  end

  -- Functional component execution
  if type(vnode.tag) == "function" then
    local props = {}
    for k, v in pairs(vnode.props) do
      props[k] = v
    end
    props.children = vnode.children
    local result = vnode.tag(props)
    return Starship.renderToString(result)
  end

  -- Fragment rendering
  if vnode.tag == Starship.Fragment then
    local parts = {}
    for _, child in ipairs(vnode.children) do
      table.insert(parts, Starship.renderToString(child))
    end
    return table.concat(parts)
  end

  -- Intrinsic element rendering
  local tag_name = tostring(vnode.tag)
  local attr_parts = {}

  for k, v in pairs(vnode.props) do
    if k ~= "children" and k ~= "__source" and type(v) ~= "function" and type(v) ~= "table" then
      if v == true then
        table.insert(attr_parts, " " .. k)
      elseif v ~= false and v ~= nil then
        table.insert(attr_parts, string.format(' %s="%s"', k, tostring(v):gsub('"', '&quot;')))
      end
    end
  end

  table.sort(attr_parts)
  local attrs = table.concat(attr_parts)

  if #vnode.children == 0 then
    return string.format("<%s%s />", tag_name, attrs)
  end

  local child_parts = {}
  for _, child in ipairs(vnode.children) do
    table.insert(child_parts, Starship.renderToString(child))
  end

  return string.format("<%s%s>%s</%s>", tag_name, attrs, table.concat(child_parts), tag_name)
end

return Starship
