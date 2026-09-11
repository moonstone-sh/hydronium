--[[
  hydronium_router.outlet -- renders whatever the router currently matches.

  --- WHY THIS IS A COMPONENT AND NOT A FUNCTION CHILD -------------------

  Hydronium's `element.lua` invokes a function child with ZERO arguments
  and renders its result as TEXT (`reactiveText`). A function child is a
  reactive string binding; it cannot swap in an arbitrary vnode. So the
  obvious-looking

      H.h("div", nil, function() return H.h(CurrentPage) end)

  does not render a page -- it renders the tostring of a vnode table.

  A real component is the mechanism that works, and it needs no new core
  plumbing at all: `ComponentInstance:render()` already runs the render
  closure inside a reactive observer, so a signal read in that closure
  re-runs exactly this component (and only this component) when it
  changes. That is the entire implementation strategy below.

  --- WHY A PARAM CHANGE DOES NOT RE-RENDER THE OUTLET -------------------

  The render closure reads `router.match()` -- the signal holding the
  matcher's STABLE route record -- and, by default, nothing else. Moving
  from "/users/1" to "/users/2" sets that signal to the same record it
  already held, the signal setter's equality short-circuit fires, no
  subscriber is notified, and this component does not re-render. The
  component the Outlet mounted stays mounted, and only the bindings that
  actually read `params.id` update.

  The one deliberate exception is `reuse = "remount"` (D4), where the key
  MUST change with the params. There, and only there, `key_for` reads the
  param signals -- which subscribes the Outlet to them on purpose, since
  the whole point is to re-render with a new key and force the reconciler
  to unmount and remount.
--]]

local H = require("hydronium")
local router_mod = require("hydronium_router.router")

local M = {}

--- Derive the vnode key for a matched route.
---
--- D4: nil by default (stay mounted across param changes; the reconciler's
--- `canReuse` sees `oldVNode.key == newVNode.key` as nil == nil and
--- updates the existing instance in place). A params-derived string when
--- the route opted into `reuse = "remount"`, which makes `canReuse` false
--- on a param change so the old instance is unmounted (running its
--- `onCleanup`s) and a fresh one mounted (re-running setup).
---
--- READS PARAMS ONLY IN THE REMOUNT CASE. Reading them unconditionally
--- would subscribe the Outlet to every param and destroy the stay-mounted
--- default -- the property this module exists to provide.
---
--- Param order comes from `pattern.params` (declaration order), never
--- from `pairs`, so the key is byte-identical across runs.
local function key_for(route, router)
  local reuse = route.meta and route.meta.reuse
  if reuse ~= "remount" then return nil end

  local parts = { route.id }
  local names = route.pattern and route.pattern.params or {}
  for i = 1, #names do
    local name = names[i]
    parts[#parts + 1] = name .. "=" .. tostring(router.params[name])
  end
  if route.pattern and route.pattern.has_wildcard then
    parts[#parts + 1] = "*=" .. tostring(router.params["*"])
  end

  return table.concat(parts, "\1")
end

--- Render a fallback supplied as `props.notFound`.
---
--- Accepts an already-built vnode (returned as-is) or a component --
--- a function or a callable table -- which is instantiated with `H.h`.
--- A component and a "render function" are the same thing here: `H.h(fn)`
--- makes a component vnode whose render body is `fn`, so both spellings
--- produce the same result.
local function render_fallback(fallback, location)
  if fallback == nil then return nil end

  if type(fallback) == "table" and fallback._typeof == H.symbols.VNODE then
    return fallback
  end

  local callable = type(fallback) == "function"
  if not callable and type(fallback) == "table" then
    local mt = getmetatable(fallback)
    callable = mt ~= nil and mt.__call ~= nil
  end

  if callable then
    return H.h(fallback, { location = location })
  end

  error("hydronium_router.Outlet: props.notFound must be a component "
    .. "(a function or callable table) or a vnode, got " .. type(fallback), 0)
end

--- The Outlet component.
---
--- @param props table
---   `.notFound` component|vnode  rendered when nothing matches. Receives
---                                the current Location as `props.location`
---                                when it is a component.
function M.Outlet(props, _scope)
  -- Setup: resolve the router once. `useContext` works here because
  -- `ComponentInstance:render()` pushes the instance's context map before
  -- running the body, for both the setup call and every later render.
  local router = H.useContext(router_mod.RouterContext)

  if router == nil then
    error("hydronium_router.Outlet: no router in context. Wrap the tree in "
      .. "`router.Provider` -- H.h(router.Provider, nil, ...children).", 0)
  end

  -- Returning a function makes this a setup/render component: the closure
  -- below is what re-runs reactively.
  return function(p)
    p = p or props or {}

    local route = router.match()

    if route == nil then
      return render_fallback(p.notFound, router.location())
    end

    local component = route.meta and route.meta.component
    if component == nil then
      error("hydronium_router.Outlet: matched route " .. string.format("%q", tostring(route.id))
        .. " has no component on its meta -- declare it with "
        .. "hydronium_router.route(id, path, component, opts)", 0)
    end

    return H.h(component, { key = key_for(route, router) })
  end
end

setmetatable(M, { __call = function(_, ...) return M.Outlet(...) end })

return M
