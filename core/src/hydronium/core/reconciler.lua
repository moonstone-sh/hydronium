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
local effectModule = require("hydronium.signals.effect")
local scopeModule = require("hydronium.core.scope")
local scheduler = require("hydronium.core.scheduler")
-- For reactiveText only: the single definition of how a reactive value
-- renders as text, shared with element.lua's own vnode construction so a
-- binding's updates can never disagree with its initial mount. Safe to
-- require here -- element.lua does not depend on the reconciler.
local elementModule = require("hydronium.core.element")

local unpack = table.unpack or unpack

local reconcilerModule = {}

--- Frozen props tables (element.lua's freezeProps) expose their real
--- keys through `_store`, plus a `__pairs` metamethod for iteration --
--- but `__pairs` is a Lua 5.2-only, since-deprecated feature LuaJIT
--- never honors, so `pairs()` on the proxy directly would silently
--- iterate nothing but the `_store` field itself. Every other call site
--- in this codebase that iterates a props table unwraps `_store` first
--- (hydronium_dom/host/dom.lua's `rawProps`, hydronium.test.host) --
--- this mirrors that same established convention.
local function rawProps(props)
  if type(props) ~= "table" then
    return {}
  end
  return props._store or props
end

--- Creates a fine-grained binding Effect owned by `scope`, remembering
--- which scope-cleanup entry it produced so `disposeBindingEffect` can
--- take that entry back out again.
---
--- Why the bookkeeping is necessary: Effect.new unconditionally appends a
--- `function() self:dispose() end` closure to the active scope's
--- `cleanups` list, and nothing ever removes it -- disposing the effect
--- only flips its own `isDisposed` flag, leaving a now-inert closure on
--- the list forever. That is harmless for the framework's usual effects,
--- which live exactly as long as their scope, but a binding effect is
--- rebuilt whenever its getter identity changes -- and a getter written
--- as an inline closure (`{function() return v() end}`, a documented and
--- supported form) is a *different* function object on every single
--- render. Without removal, one component re-rendering N times leaves N
--- dead cleanups pinned on a scope that is still very much alive:
--- unbounded memory growth plus an ever-slower teardown, on an entirely
--- ordinary code path. Measured before this fix: 1 cleanup after mount,
--- 101 after 100 re-renders.
---
--- Effect.new defers that closure BEFORE running the effect body, so it
--- is always the first entry appended -- index `before + 1` -- even if
--- the body itself registers further cleanups on the same scope.
local function createBindingEffect(scope, fn)
  if not scope then
    -- No owning component (e.g. a root-level element): the effect has no
    -- scope to be deferred onto, so there is nothing to track either.
    return effectModule.createEffect(fn)
  end

  local before = #scope.cleanups
  local eff = scopeModule.runWithScope(scope, function()
    return effectModule.createEffect(fn)
  end)

  local entry = scope.cleanups[before + 1]
  if entry then
    eff._bindingScope = scope
    eff._bindingScopeCleanup = entry
  end
  return eff
end

--- Disposes a binding effect created by `createBindingEffect` AND removes
--- the scope cleanup entry it left behind (see above). Removal is by
--- identity rather than by remembered index, because an earlier removal
--- shifts every later index.
local function disposeBindingEffect(eff)
  if not eff then
    return
  end
  eff:dispose()

  local scope = eff._bindingScope
  local entry = eff._bindingScopeCleanup
  eff._bindingScope = nil
  eff._bindingScopeCleanup = nil
  -- A disposed scope has already emptied and run its cleanups list;
  -- there is nothing to remove and nothing that could still fire.
  if not scope or not entry or scope.isDisposed then
    return
  end
  local cleanups = scope.cleanups
  for i = #cleanups, 1, -1 do
    if cleanups[i] == entry then
      table.remove(cleanups, i)
      return
    end
  end
end

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

--- Fine-grained DOM bindings (mandatory, not opt-in -- see element.lua's
--- isReactiveAccessor/isReactiveChildValue): a TEXT vnode whose content
--- came from a bare signal/computed accessor or plain function child, or
--- an ELEMENT vnode with one or more reactive-accessor prop values, gets
--- an Effect that patches only that text node / that one attribute
--- directly on change -- bypassing the owning component's re-render and
--- subtree diff entirely. Untouched by anything else in this file:
--- structural changes (conditionals, list shape) still go through the
--- ordinary reconcile/reconcileChildren path below exactly as before.
---
--- SSR is a no-op here (scheduler.isSSR() gate), matching the exact
--- convention hydronium.signals.effect.Effect.new already uses for every
--- other effect in the framework -- the vnode's own already-resolved
--- `.text` / `.props[k]` (computed once at element-creation time) is
--- what SSR renders, unchanged.
---
--- "Last committed value" is tracked as a closure-local upvalue, NOT a
--- vnode field: a vnode is a fresh, disposable snapshot produced by
--- every render pass, but the DOM node and its live binding effect
--- persist across many such snapshots (see Reconciler:reconcile's TEXT/
--- ELEMENT branches, which transfer `_bindingEffect`/
--- `_reactivePropEffects` onto the newest vnode rather than recreating
--- them when the same getter is still bound to the same position).
function Reconciler:_bindReactiveText(vnode, textNode, parentComponent)
  if scheduler.isSSR() then
    return
  end
  local host = self.host
  local getter = vnode.reactiveGetter
  local lastText = vnode.text
  local scope = parentComponent and parentComponent.scope

  vnode._bindingEffect = createBindingEffect(scope, function()
    -- elementModule.reactiveText, not a bare tostring(): a getter whose
    -- current value is nil/false/true must render as nothing, exactly as
    -- the equivalent static child does, rather than as the literal words
    -- "nil"/"false"/"true". The same function produced this vnode's
    -- initial `.text`, so mount and every later update agree.
    local newText = elementModule.reactiveText(getter())
    if newText ~= lastText then
      host.commitTextUpdate(textNode, lastText, newText)
      lastText = newText
    end
  end)
end

--- Builds the reactive-prop effects for `vnode`, all sharing ONE mutable
--- "current full props" snapshot table. Sharing matters:
--- host.commitUpdate's documented contract (every real Host, including
--- hydronium.core.test's, and the type declaration in types/hydronium.d.lua)
--- is that `newProps` is the COMPLETE current prop set, not a per-key
--- delta -- the real DOM host happens to tolerate a delta because it
--- applies attributes one at a time, but hydronium.core.test's host
--- does `instance.props = newProps` wholesale, so a delta would silently
--- erase every other prop. If two reactive props on the same element
--- each kept their own private snapshot, whichever one's effect fired
--- last would stomp the other's most recent value back to whatever it
--- was when its effect was created -- sharing one table is what keeps
--- every commitUpdate call complete and consistent.
function Reconciler:_bindReactiveProps(vnode, hostNode, parentComponent)
  if not vnode.reactiveProps or scheduler.isSSR() then
    return
  end
  local host = self.host
  local scope = parentComponent and parentComponent.scope
  local current = {}
  for pk, pv in pairs(rawProps(vnode.props)) do
    current[pk] = pv
  end

  local effects = {}
  for k, getter in pairs(vnode.reactiveProps) do
    effects[k] = createBindingEffect(scope, function()
      local newVal = getter()
      if newVal ~= current[k] then
        local old = {}
        for pk, pv in pairs(current) do old[pk] = pv end
        current[k] = newVal
        host.commitUpdate(hostNode, old, current)
      end
    end)
  end

  vnode._reactivePropEffects = effects
  vnode._reactivePropsCurrent = current
end

--- Reconcile-time counterpart to _bindReactiveProps. The common case (the
--- exact same set of keys still bound to the exact same getter identities
--- -- e.g. a re-render triggered by something unrelated to this element)
--- keeps the running effects and their shared snapshot untouched, only
--- refreshing the snapshot's non-reactive-key values from this render's
--- freshly-resolved `newVNode.props` (which the plain commitUpdate call
--- just above this one in Reconciler:reconcile already applied) so the
--- shared snapshot never drifts from what the DOM actually shows. Any
--- actual change to which keys/getters are reactive disposes the old
--- effects and rebuilds fresh, seeded directly from `newVNode.props`
--- (already the fully-resolved current snapshot -- see element.lua's
--- createElement, which resolves every reactive prop's value via
--- graph.untrack(v) at element-creation time) -- simpler and always
--- correct, and rare enough not to be worth partial-reuse complexity.
function Reconciler:_reconcileReactiveProps(oldVNode, newVNode, hostNode, parentComponent)
  if scheduler.isSSR() then
    return
  end
  local oldReactive = oldVNode.reactiveProps
  local newReactive = newVNode.reactiveProps
  local oldEffects = oldVNode._reactivePropEffects

  if not oldReactive and not newReactive then
    return
  end

  local sameBindingSet = oldReactive ~= nil and newReactive ~= nil
  if sameBindingSet then
    for k, getter in pairs(newReactive) do
      if oldReactive[k] ~= getter then sameBindingSet = false break end
    end
    if sameBindingSet then
      for k in pairs(oldReactive) do
        if newReactive[k] == nil then sameBindingSet = false break end
      end
    end
  end

  if sameBindingSet and oldEffects then
    local current = oldVNode._reactivePropsCurrent
    -- REBUILD the shared snapshot, don't merge into it. Merging only ever
    -- added and overwrote keys, so a prop that disappeared between
    -- renders stayed in the snapshot after the ordinary re-render had
    -- correctly removed it from the DOM -- and the next time ANY reactive
    -- prop on this element fired, its effect called
    -- commitUpdate(old, current) with that dead key still present and
    -- resurrected it. Rebuilding from `newVNode.props`, which is this
    -- render's complete resolved prop set (element.lua resolves every
    -- reactive prop via graph.untrack at creation time, so reactive and
    -- static keys alike are current), makes removals propagate.
    --
    -- Cleared in place rather than replaced: the running effects captured
    -- THIS table as an upvalue, so handing the vnode a different table
    -- would leave them writing to one nobody reads.
    for pk in pairs(current) do
      current[pk] = nil
    end
    for pk, pv in pairs(rawProps(newVNode.props)) do
      current[pk] = pv
    end
    newVNode._reactivePropEffects = oldEffects
    newVNode._reactivePropsCurrent = current
    return
  end

  if oldEffects then
    for _, eff in pairs(oldEffects) do
      disposeBindingEffect(eff)
    end
  end
  self:_bindReactiveProps(newVNode, hostNode, parentComponent)
end

--- Disposes every reactive binding attached to `vnode` (its own text
--- binding, if any, and any per-prop bindings) -- called from
--- Reconciler:unmount and from the reconcile paths below whenever a
--- vnode's bindings are being replaced rather than carried forward.
function Reconciler:_disposeBindings(vnode)
  if vnode._bindingEffect then
    disposeBindingEffect(vnode._bindingEffect)
    vnode._bindingEffect = nil
  end
  if vnode._reactivePropEffects then
    for _, eff in pairs(vnode._reactivePropEffects) do
      disposeBindingEffect(eff)
    end
    vnode._reactivePropEffects = nil
  end
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
    self:_bindReactiveProps(vnode, hostNode, parentComponent)

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
    if vnode.reactiveGetter then
      self:_bindReactiveText(vnode, textNode, parentComponent)
    end

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
    self:_bindReactiveProps(vnode, domNode, parentComponent)
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
    if vnode.reactiveGetter then
      self:_bindReactiveText(vnode, domNode, parentComponent)
    end
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
    self:_reconcileReactiveProps(oldVNode, newVNode, oldVNode.hostNode, parentComponent)

    if oldVNode.ref ~= newVNode.ref then
      refModule.unbindRef(oldVNode.ref)
      refModule.bindRef(newVNode.ref, newVNode.hostNode)
    end

    newVNode.children = self:reconcileChildren(oldVNode.hostNode, oldVNode.children, newVNode.children, parentComponent)
    return newVNode

  elseif kind == symbols.TEXT then
    newVNode.hostNode = oldVNode.hostNode
    local carried = oldVNode._bindingEffect
    if newVNode.reactiveGetter and oldVNode.reactiveGetter == newVNode.reactiveGetter
      and carried and not carried.isDisposed then
      -- Same binding, still LIVE: the running effect already owns this
      -- text node going forward -- carry it over rather than recreate,
      -- and skip the plain diff below (it would compare this render's
      -- freshly-evaluated snapshot against a now-stale `oldVNode.text`;
      -- the effect's own closure-local last-value, not this vnode field,
      -- is what's actually kept current -- see _bindReactiveText).
      --
      -- The `isDisposed` check is what makes this safe, and it is not
      -- theoretical. ComponentInstance:refresh (HMR) disposes the old
      -- scope BEFORE calling update()/reconcile, which kills every
      -- binding effect the scope owned. Getter identity is unchanged
      -- across a refresh for any stable accessor -- the ordinary case,
      -- `{count}` -- so without this check the branch carried a
      -- guaranteed-dead effect onto the new vnode and skipped the plain
      -- commitTextUpdate fallback as well, leaving that text node
      -- permanently frozen at whatever it read before the hot reload:
      -- no error, no subscriber, no way back. Falling through instead
      -- rebinds against the fresh scope refresh has already installed.
      newVNode._bindingEffect = carried
    else
      self:_disposeBindings(oldVNode)
      if oldVNode.text ~= newVNode.text then
        self.host.commitTextUpdate(oldVNode.hostNode, oldVNode.text, newVNode.text)
      end
      if newVNode.reactiveGetter then
        self:_bindReactiveText(newVNode, newVNode.hostNode, parentComponent)
      end
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
    self:_disposeBindings(vnode)
    if vnode.ref then
      refModule.unbindRef(vnode.ref)
    end
    local raw, len = getChildrenList(vnode)
    for i = 1, len do
      self:unmount(raw[i])
    end

  elseif kind == symbols.TEXT then
    self:_disposeBindings(vnode)

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
