--[[
  Hydronium Test Tree Inspection Utilities
  Tree snapshotting, traversal, search, and text extraction for TestHost trees.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local unpack = table.unpack or unpack

local treeModule = {}

function treeModule.toJSON(node)
  if not node then return nil end

  if node.type == "text" then
    return {
      type = "text",
      text = node.text,
    }
  elseif node.type == "element" or node.type == "root" then
    local childrenJSON = {}
    if node.children then
      for i = 1, #node.children do
        table.insert(childrenJSON, treeModule.toJSON(node.children[i]))
      end
    end

    local propsCopy = {}
    if node.props then
      for k, v in pairs(node.props) do
        if k ~= "children" then
          propsCopy[k] = v
        end
      end
    end

    return {
      type = node.type,
      tag = node.tag,
      props = propsCopy,
      children = childrenJSON,
    }
  end

  return nil
end

function treeModule.toTreeString(node, indentLevel)
  indentLevel = indentLevel or 0
  local indent = string.rep("  ", indentLevel)

  if not node then
    return indent .. "(nil)"
  end

  if node.type == "text" then
    return indent .. string.format('"%s"', node.text)
  end

  local propStrs = {}
  if node.props then
    for k, v in pairs(node.props) do
      if k ~= "children" and type(v) ~= "function" and type(v) ~= "table" then
        table.insert(propStrs, string.format('%s="%s"', tostring(k), tostring(v)))
      end
    end
  end
  table.sort(propStrs)
  local propsPart = #propStrs > 0 and (" " .. table.concat(propStrs, " ")) or ""

  if not node.children or #node.children == 0 then
    return indent .. string.format("<%s%s />", node.tag, propsPart)
  end

  local lines = {
    indent .. string.format("<%s%s>", node.tag, propsPart),
  }

  for i = 1, #node.children do
    table.insert(lines, treeModule.toTreeString(node.children[i], indentLevel + 1))
  end

  table.insert(lines, indent .. string.format("</%s>", node.tag))
  return table.concat(lines, "\n")
end

function treeModule.findAll(root, predicate)
  local results = {}
  local function walk(n)
    if not n then return end
    if predicate(n) then
      table.insert(results, n)
    end
    if n.children then
      for i = 1, #n.children do
        walk(n.children[i])
      end
    end
  end
  walk(root)
  return results
end

function treeModule.findByType(root, tag)
  local target_tag = (type(tag) == "table" and tag.tag) or tag
  local matches = treeModule.findAll(root, function(n)
    return n.type == "element" and (n.tag == target_tag or n.tag == tag)
  end)
  return matches[1]
end

function treeModule.findAllByType(root, tag)
  local target_tag = (type(tag) == "table" and tag.tag) or tag
  return treeModule.findAll(root, function(n)
    return n.type == "element" and (n.tag == target_tag or n.tag == tag)
  end)
end

function treeModule.findByProp(root, propName, propValue)
  local matches = treeModule.findAll(root, function(n)
    return n.props and n.props[propName] == propValue
  end)
  return matches[1]
end

function treeModule.getTextContent(node)
  if not node then return "" end
  if node.type == "text" then
    return node.text or ""
  end

  local out = {}
  if node.children then
    for i = 1, #node.children do
      table.insert(out, treeModule.getTextContent(node.children[i]))
    end
  end
  return table.concat(out)
end

return treeModule
