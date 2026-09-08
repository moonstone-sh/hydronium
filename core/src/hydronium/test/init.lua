--[[
  Hydronium Test Package Entry
  Testing renderer, act() synchronization, mock host, and tree assertions.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local hostModule = require("hydronium.test.host")
local treeModule = require("hydronium.test.tree")
local actModule = require("hydronium.test.act")
local reconcilerModule = require("hydronium.core.reconciler")
local scheduler = require("hydronium.core.scheduler")

local unpack = table.unpack or unpack

local test = {
  createTestHost = hostModule.createTestHost,
  tree = treeModule,
  toJSON = treeModule.toJSON,
  toTreeString = treeModule.toTreeString,
  findByType = treeModule.findByType,
  findAllByType = treeModule.findAllByType,
  findByProp = treeModule.findByProp,
  getTextContent = treeModule.getTextContent,
  act = actModule.act,
}

local function matchNode(node, selector)
  if not node then return false end
  if type(selector) == "string" then
    return (node.type == "element" and node.tag == selector)
  elseif type(selector) == "function" then
    return selector(node) == true
  elseif type(selector) == "table" then
    if selector.tag and node.tag ~= selector.tag then
      return false
    end
    if selector.props then
      for k, v in pairs(selector.props) do
        if not node.props or node.props[k] ~= v then return false end
      end
    else
      for k, v in pairs(selector) do
        if k ~= "tag" and (not node.props or node.props[k] ~= v) then return false end
      end
    end
    return true
  end
  return false
end

--- Render a VNode into a TestHost container.
function test.render(vnode, options)
  local host
  if vnode and type(vnode) == "table" and vnode.getRoot then
    host = vnode
    vnode = nil
  else
    host = options and options.host or hostModule.createTestHost()
  end

  local reconciler = reconcilerModule.Reconciler.new(host)
  local root = host.getRoot()

  local rootHostNode = nil
  local currentVNode = vnode

  if vnode then
    rootHostNode = reconciler:mount(vnode, root)
    scheduler.flush()
  end

  local instance = {
    host = host,
    root = root,
    container = root,
    rootHostNode = rootHostNode,
  }

  function instance.getVNode()
    return currentVNode
  end

  function instance.render(selfOrVNode, maybeVNode)
    local newVNode = (maybeVNode ~= nil) and maybeVNode or selfOrVNode
    if not currentVNode then
      currentVNode = newVNode
      rootHostNode = reconciler:mount(newVNode, root)
      scheduler.flush()
    else
      return instance.update(newVNode)
    end
    return instance
  end

  function instance.unmount()
    if currentVNode then
      reconciler:unmount(currentVNode)
      if rootHostNode then
        host.removeChild(root, rootHostNode)
        rootHostNode = nil
      end
      currentVNode = nil
    end
  end

  function instance.update(selfOrVNode, maybeVNode)
    local newVNode = (maybeVNode ~= nil) and maybeVNode or selfOrVNode
    currentVNode = reconciler:reconcile(root, currentVNode, newVNode)
    scheduler.flush()
    return currentVNode
  end

  function instance.tree()
    if not root.children or #root.children == 0 then
      return nil
    elseif #root.children == 1 then
      return treeModule.toJSON(root.children[1])
    else
      local out = {}
      for i = 1, #root.children do
        table.insert(out, treeModule.toJSON(root.children[i]))
      end
      return out
    end
  end
  instance.toJSON = instance.tree

  function instance.toTreeString(selfOrIndent, maybeIndent)
    local indent = (maybeIndent ~= nil) and maybeIndent or (type(selfOrIndent) == "number" and selfOrIndent or 0)
    return treeModule.toTreeString(root, indent)
  end

  function instance.find(selfOrSelector, maybeSelector)
    local selector = (maybeSelector ~= nil) and maybeSelector or selfOrSelector
    local matches = treeModule.findAll(root, function(n)
      return matchNode(n, selector)
    end)
    return matches[1]
  end

  function instance.findAll(selfOrSelector, maybeSelector)
    local selector = (maybeSelector ~= nil) and maybeSelector or selfOrSelector
    return treeModule.findAll(root, function(n)
      return matchNode(n, selector)
    end)
  end
  instance.find_all = instance.findAll

  function instance.findByType(selfOrTag, maybeTag)
    local tag = (maybeTag ~= nil) and maybeTag or selfOrTag
    return treeModule.findByType(root, tag)
  end

  function instance.findAllByType(selfOrTag, maybeTag)
    local tag = (maybeTag ~= nil) and maybeTag or selfOrTag
    return treeModule.findAllByType(root, tag)
  end

  function instance.findByProp(selfOrProp, propOrVal, maybeVal)
    local prop, val
    if maybeVal ~= nil then
      prop = propOrVal
      val = maybeVal
    else
      prop = selfOrProp
      val = propOrVal
    end
    return treeModule.findByProp(root, prop, val)
  end

  function instance.getTextContent()
    return treeModule.getTextContent(root)
  end
  instance.text = instance.getTextContent

  return instance
end

function test.create_test_root(host)
  return test.render(nil, { host = host })
end
test.createTestRoot = test.create_test_root

local TestRoot = {}
TestRoot.__index = TestRoot
function TestRoot.new(host)
  return test.create_test_root(host)
end
test.TestRoot = TestRoot

return test
