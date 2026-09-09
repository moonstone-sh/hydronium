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

--- `d.lua.mount(<App/>)` / `<d.lua.island>` produce an ISLAND-kind VNode
--- whose `tag` is the (shared singleton) island descriptor -- see
--- hydronium/dom/init.lua. Server-side, ISLAND carries real meaning
--- (SSR comment-marker boundaries, the client plan). Client-side,
--- inside a Lua VM that's already running the ordinary reconciler, a
--- Lua-interpreter island has no cross-language boundary left to
--- cross -- there's nothing left for it to do except mount its own
--- children, exactly like a Fragment. This is what
--- hydronium/dom/init.lua's own doc comment already claims ("a full
--- Lua-hydrated application and a partial Lua island share the exact
--- same client machinery") -- previously false: both mount and hydrate
--- unconditionally `error()`ed on every ISLAND. This makes it true for
--- the one case where it actually can be.
---
--- A "js" island is deliberately NOT given this treatment -- js-island
--- hydration is a completely different code path (bootstrap.js's
--- dynamic `import()` against SSR-produced markers), never this
--- reconciler, so reaching here with a "js" island is still a real
--- "no client reconciler yet" case, unchanged.
local function isTransparentLuaIsland(vnode)
  return vnode ~= nil and vnode.kind == symbols.ISLAND
    and type(vnode.tag) == "table" and vnode.tag.interpreter == "lua"
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
  elseif vnode.kind == symbols.FRAGMENT or isTransparentLuaIsland(vnode) then
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
  elseif vnode.kind == symbols.FRAGMENT or isTransparentLuaIsland(vnode) then
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

  elseif kind == symbols.FRAGMENT or isTransparentLuaIsland(vnode) then
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
  elseif kind == symbols.SUSPENSE or kind == symbols.ISLAND or kind == symbols.SCRIPT then
    -- Client (live-DOM/test-renderer) mounting for these kinds is not
    -- implemented yet -- they exist for SSR (buffered) this version. Erroring
    -- loudly here is deliberate: silently mounting nothing would make an
    -- island's or Suspense's children simply vanish client-side with no
    -- indication why, which the project's diagnostics policy forbids.
    error("Hydronium: " .. tostring(symbols.isSymbol(kind) and kind.name or kind) ..
      " has no client reconciler yet (SSR-only in this version) -- see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md", 2)
  end

  return nil
end

--- Claim existing host nodes for `vnode` instead of creating new ones --
--- the general hydration path every Hydronium host (real DOM, or any
--- future host that has a real pre-existing tree to claim) shares, in
--- place of a per-demo hand bridge. `domNode` is the next live host
--- node to try to claim (nil once the host runs out); `boundaryNode`,
--- if given, is a sentinel this walk must never claim or step past (the
--- closing marker of a partial-island hydration range -- nil for a
--- whole-container hydration, e.g. `d.lua.mount`'s root case).
---
--- On any mismatch (wrong tag, element/text kind mismatch, or the host
--- simply ran out of nodes), reports it via `host.hydrationMismatch`
--- (if the host provides one) and falls back to `self:mount` for that
--- one vnode -- through the SAME six-method Host contract every other
--- mount already goes through, not a second DOM-patching mechanism.
--- @return hostNode, nextDomNode
function Reconciler:hydrate(vnode, parentHostNode, domNode, boundaryNode, parentComponent)
  if not vnode or vnode._typeof ~= symbols.VNODE then
    return nil, domNode
  end

  local host = self.host
  local kind = vnode.kind

  local function reportMismatch(reason)
    if host.hydrationMismatch then
      host.hydrationMismatch({ reason = reason, vnode = vnode, domNode = domNode })
    end
  end

  local function fallbackMount(consumedNode)
    local newHostNode = self:mount(vnode, parentHostNode, consumedNode, parentComponent)
    local afterConsumed = nil
    if consumedNode then
      afterConsumed = host.nextSibling(consumedNode)
      host.removeChild(parentHostNode, consumedNode)
    end
    return newHostNode, afterConsumed
  end

  if kind == symbols.ELEMENT then
    local tag = unwrapTag(vnode.tag)
    if not domNode or domNode == boundaryNode or not host.isElementNode(domNode) or host.tagOf(domNode) ~= tag then
      reportMismatch("element_mismatch")
      return fallbackMount(domNode)
    end

    vnode.hostNode = domNode
    if host.hydrateProps then
      host.hydrateProps(domNode, vnode.props)
    end
    if vnode.ref then
      refModule.bindRef(vnode.ref, domNode)
    end

    local raw, len = getChildrenList(vnode)
    local childCursor = host.firstChild(domNode)
    for i = 1, len do
      local _, nextCursor = self:hydrate(raw[i], domNode, childCursor, nil, parentComponent)
      childCursor = nextCursor
    end
    -- Real children left over past what the vnode tree accounted for
    -- were never part of this render -- a genuine hydration mismatch,
    -- not a simulated one -- so they're removed rather than left as
    -- orphaned live nodes no vnode will ever again reference.
    while childCursor do
      local after = host.nextSibling(childCursor)
      reportMismatch("extra_child")
      host.removeChild(domNode, childCursor)
      childCursor = after
    end

    return domNode, host.nextSibling(domNode)

  elseif kind == symbols.TEXT then
    if not domNode or domNode == boundaryNode or not host.isTextNode(domNode) then
      reportMismatch("text_mismatch")
      return fallbackMount(domNode)
    end
    vnode.hostNode = domNode
    return domNode, host.nextSibling(domNode)

  elseif kind == symbols.COMPONENT or kind == symbols.BOUNDARY then
    local compInstance = componentModule.ComponentInstance.new(vnode, parentComponent, host)
    vnode.componentInstance = compInstance
    local hostNode, nextCursor = compInstance:hydrate(parentHostNode, domNode, boundaryNode, self)
    vnode.hostNode = hostNode
    return hostNode, nextCursor

  elseif kind == symbols.FRAGMENT or isTransparentLuaIsland(vnode) then
    local firstHostNode = nil
    local raw, len = getChildrenList(vnode)
    local cursor = domNode

    -- Real SSR output wraps EVERY island's content (including a
    -- root-mounted app via d.lua.mount, which is a root-sized island --
    -- see this file's own comment on that above) in real HTML comment
    -- marker nodes: <!--hy:i:ID:interpreter-->...<!--hy:/i:ID--> (see
    -- hydronium_dom.server's island rendering). Those exist purely for
    -- CLIENT-SIDE DISCOVERY -- irrelevant here, since Lua hydration
    -- already has the full vnode tree and never needs to "discover"
    -- where an island starts/ends from raw markup at all. FOUND LIVE (a
    -- real Playwright SSR-to-hydrate proof, not reasoned about): without
    -- skipping these, the very first real child's hydrate call sees the
    -- OPENING marker itself as `domNode`, fails `host.isElementNode`,
    -- and silently falls back to a full remount of that child -- which
    -- then orphans the real pre-existing element AND the closing marker
    -- as "extra" siblings, both removed. Net effect: hydration APPEARED
    -- to work (the page still rendered and updated correctly after a
    -- click) while actually having thrown away and rebuilt the entire
    -- DOM subtree every time -- for every real page, since d.lua.mount
    -- is the only documented root-mount API and it is always
    -- island-wrapped. `host.isCommentNode` is optional (mirrors
    -- `host.hydrationMismatch`'s own pattern) so a host that never
    -- provides it degrades to the old (broken-for-real-SSR-output, but
    -- unchanged) behavior rather than erroring. `cursor ~= boundaryNode`
    -- guards a bounded partial-island hydration whose own boundary
    -- sentinel might itself be a comment node -- never skip past that.
    local function skipCommentMarkers(node)
      if not host.isCommentNode then
        return node
      end
      while node and node ~= boundaryNode and host.isCommentNode(node) do
        node = host.nextSibling(node)
      end
      return node
    end

    cursor = skipCommentMarkers(cursor)
    for i = 1, len do
      local childHost, nextCursor = self:hydrate(raw[i], parentHostNode, cursor, boundaryNode, parentComponent)
      if not firstHostNode and childHost then firstHostNode = childHost end
      cursor = nextCursor
    end
    cursor = skipCommentMarkers(cursor)

    vnode.hostNode = firstHostNode
    return firstHostNode, cursor
  end

  -- SUSPENSE/ISLAND/SCRIPT: hydration cannot do more than self:mount()
  -- already refuses to do -- same explicit, loud boundary.
  error("Hydronium: " .. tostring(symbols.isSymbol(kind) and kind.name or kind) ..
    " has no client hydration path yet (SSR-only in this version) -- see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md", 2)
end

--- Hydrate an entire container's existing children against `vnode` --
--- the `d.lua.mount` root case, or any boundary-free "claim everything
--- already in this host node" hydration. Any real children left over
--- once `vnode` is fully consumed are removed (reported as a mismatch
--- first) rather than left live with nothing referencing them.
--- @return hostNode
function Reconciler:hydrateRoot(vnode, containerHostNode, parentComponent)
  local host = self.host
  local cursor = host.firstChild(containerHostNode)
  local hostNode, nextCursor = self:hydrate(vnode, containerHostNode, cursor, nil, parentComponent)
  while nextCursor do
    local after = host.nextSibling(nextCursor)
    if host.hydrationMismatch then
      host.hydrationMismatch({ reason = "extra_root_child", domNode = nextCursor })
    end
    host.removeChild(containerHostNode, nextCursor)
    nextCursor = after
  end
  return hostNode
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

  elseif kind == symbols.FRAGMENT or isTransparentLuaIsland(newVNode) then
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

  elseif kind == symbols.FRAGMENT or isTransparentLuaIsland(vnode) then
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
