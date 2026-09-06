--[[
  Hydronium Virtual DOM Reconciler
  Host-agnostic tree diffing, resilient child reconciliation,
  and duplicate key hardening (Amendment 4).
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local refModule = require("hydronium.core.ref")
local componentModule = require("hydronium.core.component")

local unpack = table.unpack or unpack

local reconcilerModule = {}

local function getChildrenList(vnode)
  local c = vnode and vnode.children
  if not c then return {}, 0 end
  local raw = c._store or c
  local len = c._len or #raw
  return raw, len
end

local Reconciler = {}
Reconciler.__index = Reconciler

function Reconciler.new(host)
  local self = setmetatable({}, Reconciler)
  self.host = host
  return self
end

local function unwrapTag(tag)
  if type(tag) == "table" and (tag["$$typeof"] == symbols.INTRINSIC or tag._typeof == symbols.INTRINSIC) then
    return tag.tag
  end
  return tag
end

function Reconciler:canReuse(oldVNode, newVNode)
  if not oldVNode or not newVNode then
    return false
  end
  return oldVNode.kind == newVNode.kind
    and unwrapTag(oldVNode.tag) == unwrapTag(newVNode.tag)
    and oldVNode.key == newVNode.key
end

function Reconciler:getHostNode(vnode)
  if not vnode then
    return nil
  end
  if vnode.kind == symbols.ELEMENT or vnode.kind == symbols.TEXT then
    return vnode.hostNode
  elseif vnode.kind == symbols.COMPONENT or vnode.kind == symbols.BOUNDARY then
    if vnode.componentInstance and vnode.componentInstance.subTree then
      return self:getHostNode(vnode.componentInstance.subTree)
    end
    return vnode.hostNode
  elseif vnode.kind == symbols.FRAGMENT then
    local raw, len = getChildrenList(vnode)
    if len > 0 then
      for i = 1, len do
        local hn = self:getHostNode(raw[i])
        if hn then return hn end
      end
    end
    return nil
  end
  return vnode.hostNode
end

function Reconciler:getAllHostNodes(vnode, out)
  out = out or {}
  if not vnode then return out end
  if vnode.kind == symbols.ELEMENT or vnode.kind == symbols.TEXT then
    if vnode.hostNode then table.insert(out, vnode.hostNode) end
  elseif vnode.kind == symbols.COMPONENT or vnode.kind == symbols.BOUNDARY then
    if vnode.componentInstance and vnode.componentInstance.subTree then
      self:getAllHostNodes(vnode.componentInstance.subTree, out)
    elseif vnode.hostNode then
      table.insert(out, vnode.hostNode)
    end
  elseif vnode.kind == symbols.FRAGMENT then
    if vnode.children then
      for i = 1, #vnode.children do
        self:getAllHostNodes(vnode.children[i], out)
      end
    end
  end
  return out
end

function Reconciler:mount(vnode, parentHostNode, beforeChild, parentComponent)
  if not vnode or vnode._typeof ~= symbols.VNODE then
    return nil
  end

  local kind = vnode.kind

  if kind == symbols.ELEMENT then
    local hostNode = self.host.createInstance(unwrapTag(vnode.tag), vnode.props)
    vnode.hostNode = hostNode

    if vnode.ref then
      refModule.bindRef(vnode.ref, hostNode)
    end

    local raw, len = getChildrenList(vnode)
    if len > 0 then
      for i = 1, len do
        self:mount(raw[i], hostNode, nil, parentComponent)
      end
    end

    if parentHostNode then
      if beforeChild then
        self.host.insertBefore(parentHostNode, hostNode, beforeChild)
      else
        self.host.appendChild(parentHostNode, hostNode)
      end
    end

    return hostNode

  elseif kind == symbols.TEXT then
    local textNode = self.host.createTextInstance(vnode.text)
    vnode.hostNode = textNode

    if parentHostNode then
      if beforeChild then
        self.host.insertBefore(parentHostNode, textNode, beforeChild)
      else
        self.host.appendChild(parentHostNode, textNode)
      end
    end

    return textNode

  elseif kind == symbols.COMPONENT or kind == symbols.BOUNDARY then
    local compInstance = componentModule.ComponentInstance.new(vnode, parentComponent, self.host)
    vnode.componentInstance = compInstance
    local hostNode = compInstance:mount(parentHostNode, beforeChild, self)
    vnode.hostNode = hostNode
    return hostNode

  elseif kind == symbols.FRAGMENT then
    local firstHostNode = nil
    local raw, len = getChildrenList(vnode)
    if len > 0 then
      for i = 1, len do
        local childHost = self:mount(raw[i], parentHostNode, beforeChild, parentComponent)
        if not firstHostNode and childHost then
          firstHostNode = childHost
        end
      end
    end
    vnode.hostNode = firstHostNode
    return firstHostNode
  end

  return nil
end

--- Reconcile children lists with Amendment 4 duplicate key hardening.
function Reconciler:reconcileChildren(parentHostNode, oldChildren, newChildren, parentComponent)
  local oldList, oldLen = getChildrenList({ children = oldChildren })
  local newList, newLen = getChildrenList({ children = newChildren })

  -- Amendment 4: Duplicate key detection and graceful fallback
  local newKeyCounts = {}
  for i = 1, newLen do
    local c = newList[i]
    if c and c.key ~= nil then
      newKeyCounts[c.key] = (newKeyCounts[c.key] or 0) + 1
    end
  end

  local newKeyOccurrences = {}
  for i = 1, newLen do
    local c = newList[i]
    if c and c.key ~= nil then
      if newKeyCounts[c.key] > 1 then
        local occ = (newKeyOccurrences[c.key] or 0) + 1
        newKeyOccurrences[c.key] = occ
        c._effectiveKey = tostring(c.key) .. ":__dup_" .. occ
      else
        c._effectiveKey = c.key
      end
    else
      if c then c._effectiveKey = nil end
    end
  end

  local oldKeyCounts = {}
  for i = 1, oldLen do
    local c = oldList[i]
    if c and c.key ~= nil then
      oldKeyCounts[c.key] = (oldKeyCounts[c.key] or 0) + 1
    end
  end

  local oldKeyOccurrences = {}
  for i = 1, oldLen do
    local c = oldList[i]
    if c and c.key ~= nil then
      if oldKeyCounts[c.key] > 1 then
        local occ = (oldKeyOccurrences[c.key] or 0) + 1
        oldKeyOccurrences[c.key] = occ
        c._effectiveKey = tostring(c.key) .. ":__dup_" .. occ
      else
        c._effectiveKey = c.key
      end
    else
      if c then c._effectiveKey = nil end
    end
  end

  -- Build old key map and unkeyed queue
  local oldKeyMap = {}
  local oldUnkeyed = {}
  for i = 1, oldLen do
    local oldChild = oldList[i]
    if oldChild._effectiveKey ~= nil then
      oldKeyMap[oldChild._effectiveKey] = oldChild
    else
      table.insert(oldUnkeyed, oldChild)
    end
  end

  local reconciledList = {}
  local unkeyedIdx = 1

  for i = 1, newLen do
    local newChild = newList[i]
    local matchedOld = nil

    if newChild._effectiveKey ~= nil then
      matchedOld = oldKeyMap[newChild._effectiveKey]
      if matchedOld then
        oldKeyMap[newChild._effectiveKey] = nil
      end
    else
      while unkeyedIdx <= #oldUnkeyed do
        local candidate = oldUnkeyed[unkeyedIdx]
        unkeyedIdx = unkeyedIdx + 1
        if candidate then
          matchedOld = candidate
          break
        end
      end
    end

    if matchedOld then
      if self:canReuse(matchedOld, newChild) then
        local reconciled = self:reconcile(parentHostNode, matchedOld, newChild, parentComponent)
        table.insert(reconciledList, reconciled)
      else
        self:unmount(matchedOld)
        local oldHNode = self:getHostNode(matchedOld)
        if oldHNode and parentHostNode then
          self.host.removeChild(parentHostNode, oldHNode)
        end

        self:mount(newChild, parentHostNode, nil, parentComponent)
        table.insert(reconciledList, newChild)
      end
    else
      self:mount(newChild, parentHostNode, nil, parentComponent)
      table.insert(reconciledList, newChild)
    end
  end

  -- Unmount remaining old keyed nodes
  for _, remainingOld in pairs(oldKeyMap) do
    self:unmount(remainingOld)
    local oldHNode = self:getHostNode(remainingOld)
    if oldHNode and parentHostNode then
      self.host.removeChild(parentHostNode, oldHNode)
    end
  end

  -- Unmount remaining old unkeyed nodes
  while unkeyedIdx <= #oldUnkeyed do
    local remainingOld = oldUnkeyed[unkeyedIdx]
    unkeyedIdx = unkeyedIdx + 1
    if remainingOld then
      self:unmount(remainingOld)
      local oldHNode = self:getHostNode(remainingOld)
      if oldHNode and parentHostNode then
        self.host.removeChild(parentHostNode, oldHNode)
      end
    end
  end

  -- Ensure physical sibling order in parent host
  for i = 1, #reconciledList do
    local node = reconciledList[i]
    local hostNodes = self:getAllHostNodes(node)
    for j = 1, #hostNodes do
      local hn = hostNodes[j]
      if hn and parentHostNode then
        self.host.appendChild(parentHostNode, hn)
      end
    end
  end

  return reconciledList
end

function Reconciler:reconcile(parentHostNode, oldVNode, newVNode, parentComponent)
  if oldVNode == newVNode then
    return newVNode
  end

  if not self:canReuse(oldVNode, newVNode) then
    local beforeChild = self:getHostNode(oldVNode)
    local newHostNode = self:mount(newVNode, parentHostNode, beforeChild, parentComponent)
    self:unmount(oldVNode)
    if beforeChild and parentHostNode then
      self.host.removeChild(parentHostNode, beforeChild)
    end
    return newVNode
  end

  local kind = newVNode.kind

  if kind == symbols.ELEMENT then
    newVNode.hostNode = oldVNode.hostNode
    self.host.commitUpdate(oldVNode.hostNode, oldVNode.props, newVNode.props)

    if oldVNode.ref ~= newVNode.ref then
      refModule.unbindRef(oldVNode.ref)
      refModule.bindRef(newVNode.ref, newVNode.hostNode)
    end

    newVNode.children = self:reconcileChildren(oldVNode.hostNode, oldVNode.children, newVNode.children, parentComponent)
    return newVNode

  elseif kind == symbols.TEXT then
    newVNode.hostNode = oldVNode.hostNode
    if oldVNode.text ~= newVNode.text then
      self.host.commitTextUpdate(oldVNode.hostNode, oldVNode.text, newVNode.text)
    end
    return newVNode

  elseif kind == symbols.COMPONENT or kind == symbols.BOUNDARY then
    newVNode.componentInstance = oldVNode.componentInstance
    newVNode.componentInstance.vnode = newVNode
    newVNode.componentInstance:update(newVNode.props, self)
    newVNode.hostNode = newVNode.componentInstance.hostNode
    return newVNode

  elseif kind == symbols.FRAGMENT then
    newVNode.children = self:reconcileChildren(parentHostNode, oldVNode.children, newVNode.children, parentComponent)
    newVNode.hostNode = self:getHostNode(newVNode)
    return newVNode
  end

  return newVNode
end

function Reconciler:unmount(vnode)
  if not vnode or vnode._typeof ~= symbols.VNODE then
    return
  end

  local kind = vnode.kind

  if kind == symbols.ELEMENT then
    if vnode.ref then
      refModule.unbindRef(vnode.ref)
    end
    local raw, len = getChildrenList(vnode)
    for i = 1, len do
      self:unmount(raw[i])
    end

  elseif kind == symbols.COMPONENT or kind == symbols.BOUNDARY then
    if vnode.componentInstance then
      vnode.componentInstance:unmount(self)
      vnode.componentInstance = nil
    end

  elseif kind == symbols.FRAGMENT then
    local raw, len = getChildrenList(vnode)
    for i = 1, len do
      self:unmount(raw[i])
    end
  end
end

reconcilerModule.Reconciler = Reconciler

local defaultReconcilerInstance = nil

function reconcilerModule.setDefaultHost(host)
  defaultReconcilerInstance = Reconciler.new(host)
  return defaultReconcilerInstance
end

function reconcilerModule.getDefaultReconciler()
  return defaultReconcilerInstance
end

function reconcilerModule.mount(vnode, parentHostNode, beforeChild, parentComponent)
  if not defaultReconcilerInstance then
    error("[Hydronium RECONCILER Error]: No host registered. Call reconciler.setDefaultHost(host) or pass host explicitly.", 2)
  end
  return defaultReconcilerInstance:mount(vnode, parentHostNode, beforeChild, parentComponent)
end

function reconcilerModule.reconcile(parentHostNode, oldVNode, newVNode, parentComponent)
  if not defaultReconcilerInstance then
    error("[Hydronium RECONCILER Error]: No host registered. Call reconciler.setDefaultHost(host) or pass host explicitly.", 2)
  end
  return defaultReconcilerInstance:reconcile(parentHostNode, oldVNode, newVNode, parentComponent)
end

function reconcilerModule.unmount(vnode)
  if not defaultReconcilerInstance then
    error("[Hydronium RECONCILER Error]: No host registered. Call reconciler.setDefaultHost(host) or pass host explicitly.", 2)
  end
  return defaultReconcilerInstance:unmount(vnode)
end

function reconcilerModule.getHostNode(vnode)
  if defaultReconcilerInstance then
    return defaultReconcilerInstance:getHostNode(vnode)
  end
  if not vnode then return nil end
  return vnode.hostNode
end

return reconcilerModule
