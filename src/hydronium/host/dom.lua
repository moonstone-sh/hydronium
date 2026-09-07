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

  Host bridge contract this module requires as plain Lua globals,
  supplied by whatever embeds the Lua VM in a real browser page (wasmoon
  today -- see the family-tree browser proof for the concrete JS side):

    __dom_create_element(tag: string) -> element handle
    __dom_create_text(text: string) -> text-node handle
    __dom_set_text(handle, text: string)                 -- text nodes only
    __dom_append_child(parent, child)
    __dom_insert_before(parent, child, before)
    __dom_remove_child(parent, child)
    __dom_set_attr(handle, key: string, value)            -- non-event prop
    __dom_remove_attr(handle, key: string)
    __dom_set_listener(handle, event_name: string, fn)     -- REPLACES any
      previously-registered listener for that event_name on that handle,
      exactly like hydronium.interpreter.lua's hy_on_click extension --
      this is what lets ordinary reconciliation (not RefreshRegistry, not
      any HMR-specific code) replace a component's onClick behavior
      across a refresh: see commitUpdate below.
    __dom_remove_listener(handle, event_name: string)
    __dom_first_child(node) -> node | nil
    __dom_next_sibling(node) -> node | nil
    __dom_is_element(node) -> boolean
    __dom_is_text(node) -> boolean
    __dom_tag_of(node) -> string | nil                     -- lowercase tag name

  All handles are opaque to this module, exactly like the interpreter
  bridge's handles -- never inspected, only passed back to the host
  functions above.
--]]

local M = {}

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

local function applyProp(handle, key, value)
  if NON_DOM_PROPS[key] then return end
  if isEventPropName(key) then
    if type(value) == "function" then
      __dom_set_listener(handle, eventNameFor(key), value)
    else
      __dom_remove_listener(handle, eventNameFor(key))
    end
    return
  end
  if value == nil or value == false then
    __dom_remove_attr(handle, key)
  else
    __dom_set_attr(handle, key, value)
  end
end

local function removeProp(handle, key, oldValue)
  if NON_DOM_PROPS[key] then return end
  if isEventPropName(key) then
    __dom_remove_listener(handle, eventNameFor(key))
  else
    __dom_remove_attr(handle, key)
  end
end

--- Creates the general real-DOM Host implementing the full Reconciler
--- contract (mount + update) plus the hydration helper methods
--- Reconciler:hydrate()/hydrateRoot() require. One instance per page --
--- there is no per-root state here beyond the host bridge globals
--- themselves, matching TestHost's own shape.
function M.createDomHost()
  local host = {}

  function host.createInstance(tag, props)
    local handle = __dom_create_element(tag)
    local src = rawProps(props)
    for k, v in pairs(src) do
      applyProp(handle, k, v)
    end
    return handle
  end

  function host.createTextInstance(text)
    return __dom_create_text(tostring(text or ""))
  end

  function host.appendChild(parent, child)
    if not parent or not child then return end
    __dom_append_child(parent, child)
  end

  function host.insertBefore(parent, child, before)
    if not parent or not child then return end
    if before then
      __dom_insert_before(parent, child, before)
    else
      __dom_append_child(parent, child)
    end
  end

  function host.removeChild(parent, child)
    if not parent or not child then return end
    __dom_remove_child(parent, child)
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
        removeProp(handle, k, oldV)
      end
    end
    for k, newV in pairs(newSrc) do
      -- Always re-apply (not just on inequality): a function-valued prop
      -- (a new closure each render, e.g. `onClick = function() ... end`)
      -- is never `==` to the previous one even when "the same" logically
      -- -- __dom_set_listener's REPLACE semantics make re-applying it
      -- unconditionally both correct and cheap (a browser addEventListener
      -- call, not a DOM mutation).
      applyProp(handle, k, newV)
    end
  end

  function host.commitTextUpdate(handle, oldText, newText)
    __dom_set_text(handle, tostring(newText or ""))
  end

  --- Hydration-time prop application: real SSR HTML carries attributes
  --- but never JS event listeners, so a claimed node still needs every
  --- `onX` prop wired up (exactly what createInstance already does for
  --- a freshly-mounted node -- reused verbatim, not a second
  --- implementation) even though the node itself isn't being created.
  function host.hydrateProps(handle, props)
    local src = rawProps(props)
    for k, v in pairs(src) do
      applyProp(handle, k, v)
    end
  end

  -- Hydration helpers (Reconciler:hydrate/hydrateRoot) -- generalizes
  -- hydronium.interpreter.lua's `hy_find_island`/`hy_query_button`
  -- marker-and-button-only claiming into "walk whatever the real DOM
  -- tree actually contains, structurally."
  function host.firstChild(node)
    return __dom_first_child(node)
  end

  function host.nextSibling(node)
    return __dom_next_sibling(node)
  end

  function host.isElementNode(node)
    return __dom_is_element(node) == true
  end

  function host.isTextNode(node)
    return __dom_is_text(node) == true
  end

  function host.tagOf(node)
    return __dom_tag_of(node)
  end

  host.mismatchLog = {}
  function host.hydrationMismatch(details)
    table.insert(host.mismatchLog, details.reason)
    if __dom_hydration_mismatch then
      -- Optional: let the host bridge surface this to devtools/console
      -- rather than only an in-VM Lua table nothing else reads.
      __dom_hydration_mismatch(details.reason)
    end
  end

  return host
end

return M
