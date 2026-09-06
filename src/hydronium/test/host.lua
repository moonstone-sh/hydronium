--[[
  Hydronium Test Host Implementation
  In-memory mock host implementing the full Reconciler Host interface
  for unit testing, tree snapshotting, structural assertions, and lifecycle audit log.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local unpack = table.unpack or unpack
local symbols = require("hydronium.core.symbols")

local testHostModule = {}

local nodeIdCounter = 0

local function nextNodeId()
  nodeIdCounter = nodeIdCounter + 1
  return nodeIdCounter
end

function testHostModule.createTestHost()
  local host = {}
  host.log = {}

  local root = {
    id = 0,
    type = "root",
    tag = "ROOT",
    props = {},
    children = {},
    parent = nil,
  }

  local function logOp(op, details)
    details.op = op
    table.insert(host.log, details)
  end

  function host.get_log(self_or_nil)
    return host.log
  end
  host.getLog = host.get_log

  function host.clear_log(self_or_nil)
    host.log = {}
  end
  host.clearLog = host.clear_log

  function host.getRoot(self_or_nil)
    return root
  end

  function host.createInstance(tag_or_self, props_or_tag, maybe_props)
    local tag, props
    if tag_or_self == host then
      tag = props_or_tag
      props = maybe_props
    else
      tag = tag_or_self
      props = props_or_tag
    end

    local copiedProps = {}
    local srcProps = (type(props) == "table" and (props._store or props)) or props
    if type(srcProps) == "table" then
      for k, v in pairs(srcProps) do
        copiedProps[k] = v
      end
    end

    local tag_str
    if type(tag) == "table" and (tag["$$typeof"] == symbols.INTRINSIC or tag._typeof == symbols.INTRINSIC or tag.tag) then
      tag_str = tag.tag or tostring(tag)
    else
      tag_str = tostring(tag)
    end

    local node = {
      id = nextNodeId(),
      type = "element",
      tag = tag_str,
      descriptor = (type(tag) == "table" and tag["$$typeof"] == symbols.INTRINSIC) and tag or nil,
      props = copiedProps,
      children = {},
      parent = nil,
    }

    logOp("create_node", {
      node_id = node.id,
      tag = node.tag,
      props = copiedProps,
    })

    return node
  end

  function host.createTextInstance(text_or_self, maybe_text)
    local text = (text_or_self == host) and maybe_text or text_or_self
    local node = {
      id = nextNodeId(),
      type = "text",
      text = tostring(text or ""),
      parent = nil,
    }

    logOp("create_text_node", {
      node_id = node.id,
      text = node.text,
    })

    return node
  end

  local function detachFromParent(child)
    if child.parent and child.parent.children then
      local siblings = child.parent.children
      for i = 1, #siblings do
        if siblings[i] == child then
          table.remove(siblings, i)
          break
        end
      end
      child.parent = nil
    end
  end

  function host.appendChild(parent_or_self, child_or_parent, maybe_child)
    local parent, child
    if parent_or_self == host then
      parent = child_or_parent
      child = maybe_child
    else
      parent = parent_or_self
      child = child_or_parent
    end

    if not parent or not child then return end
    detachFromParent(child)
    child.parent = parent
    table.insert(parent.children, child)

    logOp("append_child", {
      parent_id = parent.id,
      child_id = child.id,
    })
  end

  function host.insertBefore(parent_or_self, child_or_parent, before_or_child, maybe_before)
    local parent, child, beforeChild
    if parent_or_self == host then
      parent = child_or_parent
      child = before_or_child
      beforeChild = maybe_before
    else
      parent = parent_or_self
      child = child_or_parent
      beforeChild = before_or_child
    end

    if not parent or not child then return end
    detachFromParent(child)
    child.parent = parent

    local inserted = false
    if beforeChild and parent.children then
      for i = 1, #parent.children do
        if parent.children[i] == beforeChild then
          table.insert(parent.children, i, child)
          inserted = true
          break
        end
      end
    end

    if not inserted then
      table.insert(parent.children, child)
    end

    logOp("insert_before", {
      parent_id = parent.id,
      child_id = child.id,
      before_id = beforeChild and beforeChild.id or nil,
    })
  end

  function host.removeChild(parent_or_self, child_or_parent, maybe_child)
    local parent, child
    if parent_or_self == host then
      parent = child_or_parent
      child = maybe_child
    else
      parent = parent_or_self
      child = child_or_parent
    end

    if not parent or not child then return end
    if parent.children then
      for i = 1, #parent.children do
        if parent.children[i] == child then
          table.remove(parent.children, i)
          child.parent = nil
          break
        end
      end
    end

    logOp("remove_child", {
      parent_id = parent.id,
      child_id = child.id,
    })
  end

  function host.commitUpdate(instance_or_self, old_or_inst, new_or_old, maybe_new)
    local instance, oldProps, newProps
    if instance_or_self == host then
      instance = old_or_inst
      oldProps = new_or_old
      newProps = maybe_new
    else
      instance = instance_or_self
      oldProps = old_or_inst
      newProps = new_or_old
    end

    if not instance then return end
    local updatedProps = {}
    local srcProps = (type(newProps) == "table" and (newProps._store or newProps)) or newProps
    if type(srcProps) == "table" then
      for k, v in pairs(srcProps) do
        updatedProps[k] = v
      end
    end
    instance.props = updatedProps

    logOp("commit_update", {
      node_id = instance.id,
      old_props = oldProps,
      new_props = updatedProps,
    })
  end

  function host.commitTextUpdate(instance_or_self, old_or_inst, new_or_old, maybe_new)
    local instance, oldText, newText
    if instance_or_self == host then
      instance = old_or_inst
      oldText = new_or_old
      newText = maybe_new
    else
      instance = instance_or_self
      oldText = old_or_inst
      newText = new_or_old
    end

    if not instance then return end
    local old_val = instance.text
    instance.text = tostring(newText or "")

    logOp("commit_text_update", {
      node_id = instance.id,
      old_text = old_val,
      new_text = instance.text,
    })
  end

  return host
end

testHostModule.TestHost = {
  new = testHostModule.createTestHost,
}

return testHostModule
