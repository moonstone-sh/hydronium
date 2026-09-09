--[[
  hydronium.host.dom -- the general real-browser DOM Host adapter for
  `hydronium.core.reconciler`.

  Built to close the gap the HMR-generalization counter-audit surfaced:
  before this module, NOTHING implemented the Reconciler's actual Host
  contract (createInstance/createTextInstance/appendChild/insertBefore/
  removeChild/commitUpdate/commitTextUpdate, plus the newer hydration
  helpers firstChild/nextSibling/isElementNode/isTextNode/tagOf/
  hydrationMismatch -- see core/reconciler.lua) against a real DOM.
  `hydronium.interpreter.lua`'s `hy_find_island`/`hy_query_button`/
  `hy_set_text`/`hy_on_click` bridge is NOT this -- it is a hand-written,
  button-only, non-reconciler bridge, kept exactly as it was (see that
  module's own doc comment for why it was never meant to be extended).
  This module is the general path: any `d.<tag>` intrinsic, any tree
  shape, through the ordinary Reconciler/ComponentInstance/Family
  machinery every other Hydronium host already uses (TestHost included).

  Host bridge contract -- fifteen functions, either passed explicitly as
  a table to `createDomHost(bridge)` or (if omitted) read from plain Lua
  globals named `__dom_<snake_case name below>` (e.g. `create_element`
  reads global `__dom_create_element`) -- the way every real browser page
  in this repo wires it today via wasmoon's `lua.global.set`. The
  explicit-table form exists specifically so native tests can inject a
  fake bridge instead of mutating real globals (see
  `tests/host/dom_spec.lua`) -- both forms produce the exact same host;
  the module doesn't know or care which one supplied it:

    create_element(tag: string) -> element handle
    create_text(text: string) -> text-node handle
    set_text(handle, text: string)                 -- text nodes only
    append_child(parent, child)
    insert_before(parent, child, before)
    remove_child(parent, child)
    set_attr(handle, key: string, value)            -- non-event prop
    remove_attr(handle, key: string)
    set_listener(handle, event_name: string, fn)     -- REPLACES any
      previously-registered listener for that event_name on that handle,
      exactly like hydronium.interpreter.lua's hy_on_click extension --
      this is what lets ordinary reconciliation (not RefreshRegistry, not
      any HMR-specific code) replace a component's onClick behavior
      across a refresh: see commitUpdate below.
    remove_listener(handle, event_name: string)
    first_child(node) -> node | nil
    next_sibling(node) -> node | nil
    is_element(node) -> boolean
    is_text(node) -> boolean
    tag_of(node) -> string | nil                     -- lowercase tag name

  One more, OPTIONAL (unlike the fifteen above, `createDomHost` does not
  require this one to be present): `hydration_mismatch(reason: string)`
  -- lets the host bridge surface a hydration mismatch to devtools/console
  rather than only an in-VM Lua table nothing else reads.

  All handles are opaque to this module, exactly like the interpreter
  bridge's handles -- never inspected, only passed back to the bridge
  functions above.

  `createDomHost` validates the bridge eagerly and errors with a clear,
  named list of what's missing rather than the cryptic
  "attempt to call a nil value (global '__dom_create_element')" a bare
  missing global previously produced with zero indication of what was
  even supposed to supply it.
--]]

local M = {}

local REQUIRED_BRIDGE_FNS = {
  "create_element", "create_text", "set_text", "append_child", "insert_before",
  "remove_child", "set_attr", "remove_attr", "set_listener", "remove_listener",
  "first_child", "next_sibling", "is_element", "is_text", "tag_of",
}

local function default_bridge()
  return {
    create_element = _G.__dom_create_element,
    create_text = _G.__dom_create_text,
    set_text = _G.__dom_set_text,
    append_child = _G.__dom_append_child,
    insert_before = _G.__dom_insert_before,
    remove_child = _G.__dom_remove_child,
    set_attr = _G.__dom_set_attr,
    remove_attr = _G.__dom_remove_attr,
    set_listener = _G.__dom_set_listener,
    remove_listener = _G.__dom_remove_listener,
    first_child = _G.__dom_first_child,
    next_sibling = _G.__dom_next_sibling,
    is_element = _G.__dom_is_element,
    is_text = _G.__dom_is_text,
    tag_of = _G.__dom_tag_of,
    hydration_mismatch = _G.__dom_hydration_mismatch,
    is_comment = _G.__dom_is_comment,
  }
end

-- Props this module never forwards to the DOM as an attribute or event
-- listener -- structural VNode bookkeeping the reconciler itself
-- already consumed, not something a real DOM node has any use for.
local NON_DOM_PROPS = { children = true, key = true, ref = true }

local function isEventPropName(key)
  return type(key) == "string" and #key > 2 and key:sub(1, 2) == "on"
    and key:sub(3, 3):match("%u") ~= nil
end

local function eventNameFor(propKey)
  -- "onClick" -> "click", "onMouseEnter" -> "mouseenter" (DOM addEventListener
  -- event names are lowercase; the host bridge's __dom_set_listener is
  -- expected to call addEventListener with this string directly).
  return propKey:sub(3):lower()
end

local function rawProps(props)
  if type(props) ~= "table" then return {} end
  return props._store or props
end

local function applyProp(bridge, handle, key, value)
  if NON_DOM_PROPS[key] then return end
  if isEventPropName(key) then
    if type(value) == "function" then
      bridge.set_listener(handle, eventNameFor(key), value)
    else
      bridge.remove_listener(handle, eventNameFor(key))
    end
    return
  end
  if value == nil or value == false then
    bridge.remove_attr(handle, key)
  else
    bridge.set_attr(handle, key, value)
  end
end

local function removeProp(bridge, handle, key, oldValue)
  if NON_DOM_PROPS[key] then return end
  if isEventPropName(key) then
    bridge.remove_listener(handle, eventNameFor(key))
  else
    bridge.remove_attr(handle, key)
  end
end

--- Creates the general real-DOM Host implementing the full Reconciler
--- contract (mount + update) plus the hydration helper methods
--- Reconciler:hydrate()/hydrateRoot() require. One instance per page --
--- there is no per-root state here beyond the bridge table itself,
--- matching TestHost's own shape.
--- @param bridge? table Explicit bridge table (see module doc comment).
---   Omit to read the `__dom_*` globals instead (the real-browser-page
---   default).
function M.createDomHost(bridge)
  bridge = bridge or default_bridge()

  local missing = {}
  for _, name in ipairs(REQUIRED_BRIDGE_FNS) do
    if type(bridge[name]) ~= "function" then
      table.insert(missing, name)
    end
  end
  if #missing > 0 then
    error(
      "hydronium.host.dom.createDomHost: missing required DOM bridge function(s): " ..
      table.concat(missing, ", ") ..
      " -- either pass a bridge table (createDomHost({ create_element = ..., ... })), " ..
      "or set the corresponding __dom_<name> globals before calling createDomHost() with no argument. " ..
      "See this module's own doc comment for the full contract.",
      2
    )
  end

  local host = {}

  function host.createInstance(tag, props)
    local handle = bridge.create_element(tag)
    local src = rawProps(props)
    for k, v in pairs(src) do
      applyProp(bridge, handle, k, v)
    end
    return handle
  end

  function host.createTextInstance(text)
    return bridge.create_text(tostring(text or ""))
  end

  function host.appendChild(parent, child)
    if not parent or not child then return end
    bridge.append_child(parent, child)
  end

  function host.insertBefore(parent, child, before)
    if not parent or not child then return end
    if before then
      bridge.insert_before(parent, child, before)
    else
      bridge.append_child(parent, child)
    end
  end

  function host.removeChild(parent, child)
    if not parent or not child then return end
    bridge.remove_child(parent, child)
  end

  --- Ordinary prop diff -- this is the ENTIRE mechanism by which an
  --- edited onClick handler takes effect across an HMR refresh (mission
  --- Part III item 9): ComponentInstance:refresh() reruns setup and
  --- calls the normal :update() -> reconciler:reconcile() ->
  --- commitUpdate() path, same as any other prop change. RefreshRegistry
  --- never touches a DOM listener; this diff does, and only this diff.
  function host.commitUpdate(handle, oldProps, newProps)
    local oldSrc = rawProps(oldProps)
    local newSrc = rawProps(newProps)

    for k, oldV in pairs(oldSrc) do
      if newSrc[k] == nil then
        removeProp(bridge, handle, k, oldV)
      end
    end
    for k, newV in pairs(newSrc) do
      -- Always re-apply (not just on inequality): a function-valued prop
      -- (a new closure each render, e.g. `onClick = function() ... end`)
      -- is never `==` to the previous one even when "the same" logically
      -- -- set_listener's REPLACE semantics make re-applying it
      -- unconditionally both correct and cheap (a browser addEventListener
      -- call, not a DOM mutation).
      applyProp(bridge, handle, k, newV)
    end
  end

  function host.commitTextUpdate(handle, oldText, newText)
    bridge.set_text(handle, tostring(newText or ""))
  end

  --- Hydration-time prop application: real SSR HTML carries attributes
  --- but never JS event listeners, so a claimed node still needs every
  --- `onX` prop wired up (exactly what createInstance already does for
  --- a freshly-mounted node -- reused verbatim, not a second
  --- implementation) even though the node itself isn't being created.
  function host.hydrateProps(handle, props)
    local src = rawProps(props)
    for k, v in pairs(src) do
      applyProp(bridge, handle, k, v)
    end
  end

  -- Hydration helpers (Reconciler:hydrate/hydrateRoot) -- generalizes
  -- hydronium.interpreter.lua's `hy_find_island`/`hy_query_button`
  -- marker-and-button-only claiming into "walk whatever the real DOM
  -- tree actually contains, structurally."
  function host.firstChild(node)
    return bridge.first_child(node)
  end

  function host.nextSibling(node)
    return bridge.next_sibling(node)
  end

  function host.isElementNode(node)
    return bridge.is_element(node) == true
  end

  function host.isTextNode(node)
    return bridge.is_text(node) == true
  end

  function host.tagOf(node)
    return bridge.tag_of(node)
  end

  -- Optional (mirrors hydrationMismatch's own pattern below): lets
  -- Reconciler:hydrate's transparent-island branch skip real SSR-emitted
  -- HTML comment island markers (<!--hy:i:...-->/<!--hy:/i:...-->)
  -- instead of misreading one as a real content mismatch -- see that
  -- branch's own doc comment (core/reconciler.lua) for the real bug this
  -- closes, found via a live SSR-to-hydrate Playwright proof. A bridge
  -- that doesn't provide `is_comment` degrades to the pre-fix behavior.
  if bridge.is_comment then
    function host.isCommentNode(node)
      return bridge.is_comment(node) == true
    end
  end

  host.mismatchLog = {}
  function host.hydrationMismatch(details)
    table.insert(host.mismatchLog, details.reason)
    if bridge.hydration_mismatch then
      -- Optional: let the host bridge surface this to devtools/console
      -- rather than only an in-VM Lua table nothing else reads.
      bridge.hydration_mismatch(details.reason)
    end
  end

  return host
end

return M
