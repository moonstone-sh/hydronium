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

  The embedding provides dom@1 through hydronium.runtime.hosts. mount()
  registers it after module preloading and passes it explicitly to
  createDomHost(bridge). The no-argument form resolves that registry first,
  then supports old __dom_* globals through the compatibility adapter.

  hydronium_dom.host.contract is the shared declaration of required and
  optional functions, the JavaScript provider, effects and cleanup. Explicit
  bridge injection continues to let native tests avoid global mutation.

  set_listener replaces the prior listener for an element/event pair;
  remove_listener removes it. Ordinary reconciliation therefore updates
  event callbacks across HMR without special handling in this host.

  All handles are opaque to this module, exactly like the interpreter
  bridge's handles -- never inspected, only passed back to the bridge
  functions above.

  `createDomHost` validates the bridge eagerly and errors with a clear,
  named list of what's missing rather than the cryptic
  "attempt to call a nil value (global '__dom_create_element')" a bare
  missing global previously produced with zero indication of what was
  even supposed to supply it.
--]]

-- The one and only normalization of a `style` prop into real CSS
-- property names/values, shared verbatim with the SSR serializer
-- (`hydronium_dom.server.html.serialize_style` calls the same functions).
-- Sharing rather than reimplementing is what guarantees a styled element
-- hydrates cleanly: the server and this module cannot compute different
-- CSS for the same input, because there is only one implementation.
-- `hydronium_dom.style` is itself a leaf module with no requires, so this
-- does not compromise loading this host inside a browser Lua VM.
local style_util = require("hydronium_dom.style")

local M = {}

local hosts = require("hydronium.runtime.hosts")
local contract = require("hydronium_dom.host.contract")
local legacy = require("hydronium_dom.host.legacy")

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

--- True when the bridge can address individual CSS properties.
---
--- `set_style_property`/`remove_style_property` are OPTIONAL bridge
--- functions -- the same pattern `is_comment` and `hydration_mismatch`
--- already use -- so every bridge written before style support existed
--- keeps working unchanged instead of failing the required-function
--- check. When they are absent, `applyStyle` falls back to rewriting the
--- whole `style` attribute, which is correct but not surgical.
local function hasStylePropertyFns(bridge)
  return type(bridge.set_style_property) == "function"
    and type(bridge.remove_style_property) == "function"
end

--- Applies a `style` prop, diffing it against the previous one.
---
--- A style prop may be authored two ways, matching what React and Solid
--- both accept:
---
---   * a STRING of raw CSS text -- `style = "color: red; margin: 0"` --
---     which is set as the ordinary `style` HTML attribute verbatim, and
---   * a TABLE of property names to values -- `style = { color = "red" }`
---     or `style = { ["background-color"] = "red" }` (camelCase and
---     kebab-case are both accepted and normalize to the same CSS name).
---
--- The table form is applied per-property through the DOM's
--- `CSSStyleDeclaration` rather than through `setAttribute`. That is the
--- whole reason the table form exists: setting the attribute rewrites the
--- element's entire inline style, clobbering any property some other code
--- path set, whereas `setProperty`/`removeProperty` touch exactly the
--- declarations that actually changed. It is also what makes an update
--- correct -- a property present last render but absent now must be
--- REMOVED, not merely left at its stale value, which is precisely the
--- bug a "regenerate the whole string" approach hides until two sources
--- write to the same element.
---
--- @param oldValue any the previous render's style prop (nil on mount)
--- @param newValue any this render's style prop
local function applyStyle(bridge, handle, oldValue, newValue)
  -- Gone entirely: drop the whole inline style.
  if newValue == nil or newValue == false then
    bridge.remove_attr(handle, "style")
    return
  end

  -- String form: raw CSS text straight onto the attribute. Note this is
  -- the UNESCAPED text -- `set_attr` maps to `setAttribute`, which takes
  -- raw text; only SSR escapes, because only SSR embeds it in markup.
  if type(newValue) == "string" then
    if newValue == "" then
      bridge.remove_attr(handle, "style")
    else
      bridge.set_attr(handle, "style", newValue)
    end
    return
  end

  if type(newValue) ~= "table" then
    -- Anything else (a number, a boolean true) is not a meaningful style.
    bridge.remove_attr(handle, "style")
    return
  end

  if not hasStylePropertyFns(bridge) then
    -- Fallback path: no per-property access, so regenerate wholesale.
    local css = style_util.serialize(newValue)
    if css == "" then
      bridge.remove_attr(handle, "style")
    else
      bridge.set_attr(handle, "style", css)
    end
    return
  end

  local newMap = style_util.to_map(newValue)

  -- Switching FROM a string (or from any non-table) to a table means the
  -- element currently carries an inline style this diff knows nothing
  -- about. Clear it first so stale declarations cannot survive.
  if type(oldValue) ~= "table" then
    if oldValue ~= nil and oldValue ~= false then
      bridge.remove_attr(handle, "style")
    end
    for name, value in pairs(newMap) do
      bridge.set_style_property(handle, name, value)
    end
    return
  end

  local oldMap = style_util.to_map(oldValue)

  -- Removed: present last render, gone now.
  for name in pairs(oldMap) do
    if newMap[name] == nil then
      bridge.remove_style_property(handle, name)
    end
  end
  -- Added or changed. Unchanged properties are skipped -- unlike a
  -- listener, re-setting a CSS property is a real style recalculation, so
  -- the equality check here is worth making.
  for name, value in pairs(newMap) do
    if oldMap[name] ~= value then
      bridge.set_style_property(handle, name, value)
    end
  end
end

--- @param oldValue any previous value, used only by the `style` diff
---   (every other prop type is applied without needing to know it).
local function applyProp(bridge, handle, key, value, oldValue)
  if NON_DOM_PROPS[key] then return end
  if isEventPropName(key) then
    if type(value) == "function" then
      bridge.set_listener(handle, eventNameFor(key), value)
    else
      bridge.remove_listener(handle, eventNameFor(key))
    end
    return
  end
  if key == "style" then
    applyStyle(bridge, handle, oldValue, value)
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
    -- `style` needs no special case: removing the attribute drops every
    -- inline declaration at once, which is exactly what "the style prop
    -- is gone" means.
    bridge.remove_attr(handle, key)
  end
end

--- Creates the general real-DOM Host implementing the full Reconciler
--- contract (mount + update) plus the hydration helper methods
--- Reconciler:hydrate()/hydrateRoot() require. One instance per page --
--- there is no per-root state here beyond the bridge table itself,
--- matching TestHost's own shape.
--- @param bridge? table Explicit bridge table (see module doc comment).
---   Omit to resolve dom@1 from the VM-local registry, with legacy globals
---   as a compatibility fallback.
function M.createDomHost(bridge)
  bridge = bridge or hosts.get("dom", 1) or legacy.read(_G)
  contract.validate(bridge)

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
      --
      -- The previous value is passed through purely for `style`, whose
      -- table form must be DIFFED rather than re-applied: re-applying it
      -- blind would add and update properties but never remove one that
      -- disappeared between renders.
      applyProp(bridge, handle, k, newV, oldSrc[k])
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
