--[[
  Hydronium Element & VNode Factory
  Strict child normalization, varargs safety with select("#", ...), immutability,
  and VNode construction. Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local suspense = require("hydronium.core.suspense")
local graph = require("hydronium.signals.graph")

local unpack = table.unpack or unpack

local elementModule = {}

--- A bare signal/computed accessor, matched by the same `_typeof`/
--- `_is_signal`/`_is_computed` shape SSR's render_node already
--- special-cases (hydronium_dom/server/init.lua) -- unambiguous, since
--- nothing else in this codebase produces a table with those markers.
local function isReactiveAccessor(v)
  return type(v) == "table" and (v._typeof == symbols.SIGNAL or v._typeof == symbols.COMPUTED
    or v._is_signal or v._is_computed)
end

--- A reactive accessor OR a plain function, passed as a *child*, is a
--- reactive binding -- the reconciler wraps it in a fine-grained effect
--- that patches only that DOM text node directly on change, instead of
--- relying on the enclosing component re-rendering (see reconciler.lua).
--- This is what makes granular updates the default: `{count}` (bare,
--- uncalled) opts a leaf into this; `{count()}` (called, collapsed to a
--- plain value here) does not and behaves exactly as it always has.
--- Plain functions are included here (children only -- see
--- createElement for why reactive PROPS are narrower): a bare function
--- child is never meaningfully anything else in this framework
--- (components are always invoked via `H.h(ComponentFn)`, producing a
--- VNode, never passed bare as a child), and SSR's render_node already
--- treats a function child as "call it for a value"
--- (hydronium_dom/server/init.lua), so this is consistent with an
--- existing convention, not a new one.
---
--- The calling convention is fixed and deliberate: a function child is
--- invoked with ZERO arguments, as a getter, and its return value is
--- rendered through `reactiveText`. It is not a render prop. A render
--- prop that needs arguments must be invoked explicitly by whoever has
--- them -- `{renderRow(item)}`, not `{renderRow}` -- because there is no
--- argument this framework could pass on the author's behalf that would
--- be more meaningful than none, and inventing one would make the two
--- shapes indistinguishable at the call site.
local function isReactiveChildValue(v)
  return type(v) == "function" or isReactiveAccessor(v)
end

--- Event-handler-named props (`onClick`, `onMouseEnter`, ...) are always
--- callbacks, never derived values, even though they're function-valued
--- -- they must never be rerouted into the reactive-binding system.
--- Deliberately duplicated (not shared) from
--- hydronium_dom/host/dom.lua's identical predicate: this module is
--- host-agnostic (also used by the Ink/terminal host and the test
--- renderer) and must not depend on a DOM-specific module for a
--- three-line naming convention.
local function isEventPropKey(key)
  return type(key) == "string" and #key > 2 and key:sub(1, 2) == "on"
    and key:sub(3, 3):match("%u") ~= nil
end

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

--- Renders a reactive child's current value to text.
---
--- `nil`, `false` and `true` collapse to the empty string rather than to
--- the literal words "nil"/"false"/"true". Those are exactly the three
--- values flattenChildren discards outright for a STATIC child, so
--- `{maybeValue}` has to render nothing when the value is absent, the
--- same way `{nil}` already does -- and `{cond and x}` has to render
--- nothing when `cond` is false, which is an entirely ordinary Lua
--- idiom. A reactive child cannot simply be dropped the way a static one
--- is: it owns a real text node that must stay in place so the value can
--- be patched back in when it returns. So "nothing" is spelled as an
--- empty text node.
---
--- Shared with reconciler.lua's binding effect (elementModule.reactiveText)
--- so element creation, SSR and every later update agree on exactly how
--- an absent value renders.
local function reactiveText(value)
  if value == nil or value == false or value == true then
    return ""
  end
  return tostring(value)
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

--- A TEXT VNode whose content comes from a signal/computed accessor or a
--- plain function rather than a static string -- `reactiveGetter` is what
--- the reconciler looks for to set up a fine-grained binding instead of a
--- static text node (see reconciler.lua's Reconciler:mount TEXT branch).
--- `.text` itself is still a real, current value (not merely a lazy
--- placeholder): SSR's render_node reads it directly like any other TEXT
--- VNode, so nothing server-side needs to know this field exists at all.
local function createReactiveTextVNode(getter)
  -- Read untracked: this happens while the ENCLOSING component's render
  -- is still the active tracking observer (element construction runs
  -- synchronously inside graph.runObserver(componentInstance, ...) --
  -- see component.lua's :render()). Reading normally here would make
  -- the component ALSO subscribe to this signal, defeating the entire
  -- point -- the reconciler's own fine-grained effect (created later,
  -- once this vnode actually mounts) is meant to be the only subscriber.
  local initial = graph.untrack(getter)
  local raw = {
    _typeof = symbols.VNODE,
    kind = symbols.TEXT,
    tag = nil,
    props = freezeProps({}),
    children = freezeChildren({}),
    key = nil,
    ref = nil,
    text = reactiveText(initial),
    reactiveGetter = getter,
  }
  return freezeVNode(raw)
end

--- Recursively flattens and normalizes child values.
--- Discards nil, false, true.
--- Converts numbers to strings and wraps as TEXT VNodes.
--- Wraps raw strings as TEXT VNodes.
--- Wraps a bare signal/computed accessor or a plain function as a
--- reactive TEXT VNode (see createReactiveTextVNode) instead of silently
--- dropping it -- a reactive child whose current value is nil/false/true
--- renders as an empty text node, matching the static case (reactiveText).
--- Flattens nested tables into a contiguous 1-indexed array.
local function flattenChildren(item, out)
  if item == nil or item == false or item == true then
    return
  end

  -- The reactive-child test runs first and in ONE place, so
  -- isReactiveChildValue is the single live definition of "this child is
  -- a reactive binding" rather than a doc-comment describing logic
  -- inlined into two separate branches below. Order is safe: a VNode is
  -- a table but never a signal/computed accessor, and the frozen
  -- children proxy is userdata, so neither can match here.
  if isReactiveChildValue(item) then
    table.insert(out, createReactiveTextVNode(item))
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
  -- Resolve the vnode KIND before touching props: what a prop VALUE
  -- means depends on it. A reactive accessor is only ever split out into
  -- a fine-grained binding for an ELEMENT -- the one kind that gets a
  -- real host node and for which the reconciler actually calls
  -- _bindReactiveProps (see reconciler.lua's mount/hydrate ELEMENT
  -- branches). For every other kind the accessor must be passed through
  -- AS the accessor. Kind is a pure function of `tag` -- it never looks
  -- at props or children -- so hoisting it here costs nothing.
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

  local normalizedProps = {}
  local reactiveProps = nil
  local key = nil
  local ref = nil

  if type(props) == "table" then
    for k, v in pairs(props) do
      if k == "key" then
        key = v
      elseif k == "ref" then
        ref = v
      elseif kind == symbols.ELEMENT and k ~= "children" and not isEventPropKey(k) and isReactiveAccessor(v) then
        -- ELEMENT ONLY. A signal/computed accessor on a non-event prop of
        -- a host element is a reactive binding: record it separately
        -- (kept off `props`, which stays a plain, fully-resolved snapshot
        -- for SSR and for anything reading props the old way) so the
        -- reconciler can wire up a fine-grained attribute effect for it,
        -- while the vnode's own `props[k]` still carries today's resolved
        -- value.
        --
        -- Why the `kind == ELEMENT` guard is load-bearing rather than an
        -- optimization: only the ELEMENT branches of the reconciler's
        -- mount/hydrate call _bindReactiveProps, because only an ELEMENT
        -- has a host node and a commitUpdate to patch. Applying the split
        -- to a COMPONENT would resolve `<Child value={count} />` down to a
        -- plain number before the child ever sees it -- the child's
        -- `props.value` would stop being callable, nothing would bind it,
        -- and the parent would not subscribe either (the read here is
        -- untracked), so the value would silently freeze at its
        -- first-render snapshot with no error and no warning. Passing an
        -- accessor DOWN a component tree is the ordinary way to hand a
        -- child something reactive, so it must arrive intact and let the
        -- child decide where to read it.
        --
        -- Deliberately NOT extended to bare plain functions the way
        -- children are (isReactiveChildValue): an arbitrary
        -- function-valued prop is far more often a plain callback
        -- (fallback, onError, a ref function, ...) than a derived-value
        -- getter, and there is no marker to tell them apart -- unlike
        -- children, guessing wrong here would silently call something
        -- that was never meant to be called. A signal or computed
        -- accessor has no such ambiguity.
        reactiveProps = reactiveProps or {}
        reactiveProps[k] = v
        normalizedProps[k] = graph.untrack(v) -- see createReactiveTextVNode's comment on why untracked
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

  -- `ref` is a host-node concept: ELEMENT is the ONLY kind that ever gets
  -- a real host node for the reconciler to bind a ref to. Every ref call
  -- site in reconciler.lua (mount/hydrate/reconcile/unmount) sits inside
  -- an ELEMENT-kind branch, and no path anywhere -- client or server --
  -- reads `vnode.ref` for any other kind.
  --
  -- So `ref` is stripped into `vnode.ref` for ELEMENT and ELEMENT only.
  -- For every other kind it stays an ORDINARY prop, readable as
  -- `props.ref`, exactly like Solid (whose reactivity model this
  -- framework's signal graph already mirrors). A COMPONENT or BOUNDARY
  -- has no single host node -- it may render zero, one, or many, or a
  -- fragment -- so there is nothing to forward a ref to automatically;
  -- the component author reads `props.ref` and assigns it to whichever
  -- inner element (or synthesized imperative handle) they choose.
  --
  -- FRAGMENT, SUSPENSE, ISLAND and SCRIPT are in the same position and
  -- are handled the same way, which is a change: they used to fall into
  -- the ELEMENT path, so `ref` was moved onto `vnode.ref` and then simply
  -- never read by anything -- a genuinely silent drop. Leaving it on
  -- props does not conjure up a host node for them (a fragment still has
  -- no single node to point at, and ISLAND/SCRIPT have no client
  -- reconciler at all in this version), but it does mean the value stays
  -- visible and inspectable to whoever passed it instead of vanishing
  -- into a field no code path consumes.
  local vnodeRef = nil
  if ref ~= nil then
    if kind == symbols.ELEMENT then
      vnodeRef = ref
    else
      normalizedProps.ref = ref
    end
  end

  local raw = {
    _typeof = symbols.VNODE,
    kind = kind,
    tag = resolvedTag,
    props = freezeProps(normalizedProps),
    children = freezeChildren(children),
    key = key,
    ref = vnodeRef,
    text = nil,
    reactiveProps = reactiveProps,
  }

  return freezeVNode(raw)
end

elementModule.h = elementModule.createElement
elementModule.create_element = elementModule.createElement
elementModule.Fragment = symbols.FRAGMENT
elementModule.createTextVNode = createTextVNode
elementModule.flattenChildren = flattenChildren
elementModule.reactiveText = reactiveText
elementModule.isReactiveAccessor = isReactiveAccessor
elementModule.isReactiveChildValue = isReactiveChildValue
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
