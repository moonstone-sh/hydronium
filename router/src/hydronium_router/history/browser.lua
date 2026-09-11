--[[
  hydronium_router.history.browser -- a History backed by the real
  `window.history`, reached through an injectable bridge.

  BRIDGE CONTRACT -- five functions, either passed explicitly as a table
  to `create_browser_history(bridge)` or (if omitted) read from plain Lua
  globals named `__router_<name>`:

    push_state(url: string, state: any)
    replace_state(url: string, state: any)
    go(delta: integer)
    location_href() -> string          -- e.g. "/users/7?tab=a#top"
    on_popstate(fn) -> unsubscribe|nil -- fn is called with no arguments
                                          after the browser navigates

  This is the same injectable-table-or-global-fallback shape
  `hydronium_dom.host.dom`'s `createDomHost` uses for its `__dom_*`
  bridge, and for the same reason: the explicit-table form is what makes
  this module unit-testable with a fake bridge, with no browser, no
  wasmoon, and no mutation of `_G`. Both forms produce an identical
  history; this module cannot tell which one supplied it.

  `router/client/history.js` is the real browser-side shim that
  implements the five functions against `window.history` and
  `window.addEventListener("popstate", ...)`.

  --- AN HONEST LIMITATION ------------------------------------------------

  `can_go_back` / `can_go_forward` are EXACT in `history.memory`, which
  owns its whole stack. They cannot be exact here: the DOM History API
  exposes `history.length` but no position within it, and a `popstate`
  event does not say which direction the user moved. So this adapter
  tracks only what it did itself -- entries it pushed, and movement from
  its own `go`/`back`/`forward` calls -- and treats a popstate it did not
  initiate as making forward-travel unknown (reported as false).
  Callers that need exact answers should drive navigation exclusively
  through this object, or use `history.memory`.
--]]

local hydronium = require("hydronium")
local history = require("hydronium_router.history")

local M = {}

M.REQUIRED_BRIDGE_FNS = {
  "push_state", "replace_state", "go", "location_href", "on_popstate",
}

local function default_bridge()
  return {
    push_state = _G.__router_push_state,
    replace_state = _G.__router_replace_state,
    go = _G.__router_go,
    location_href = _G.__router_location_href,
    on_popstate = _G.__router_on_popstate,
  }
end

--- Create a browser-backed history.
---
--- @param bridge? table  Explicit bridge table (see the module doc
---   comment). Omit to read the `__router_*` globals instead -- the
---   real-browser-page default.
--- @return table history  implements hydronium_router.History
function M.create_browser_history(bridge)
  bridge = bridge or default_bridge()

  if type(bridge) ~= "table" then
    error("hydronium_router.history.browser.create_browser_history: bridge must be a table, got "
      .. type(bridge), 2)
  end

  local missing = {}
  for _, name in ipairs(M.REQUIRED_BRIDGE_FNS) do
    if type(bridge[name]) ~= "function" then
      missing[#missing + 1] = name
    end
  end
  if #missing > 0 then
    error(
      "hydronium_router.history.browser.create_browser_history: missing required bridge function(s): "
      .. table.concat(missing, ", ")
      .. " -- either pass a bridge table (create_browser_history({ push_state = ..., ... })), "
      .. "or set the corresponding __router_<name> globals before calling it with no argument. "
      .. "router/client/history.js installs exactly these five.",
      2
    )
  end

  local location = hydronium.createSignal(history.to_location(bridge.location_href()))
  local disposed = false

  -- Best-effort position tracking; see the module doc comment.
  local pushes = 0    -- entries WE created
  local offset = 0    -- our own movement away from the newest, <= 0

  -- Our own `go` causes a popstate too, and the event itself carries no
  -- way to tell it apart from the user pressing Back. Without this
  -- counter the handler below would immediately discard the offset that
  -- `go` had just correctly recorded, so `back()` would always leave
  -- `can_go_forward()` false. Each self-initiated `go` claims the next
  -- popstate; anything left over is genuinely external.
  local pending_self_go = 0

  local function assert_live(op)
    if disposed then
      error("hydronium_router.history.browser: cannot " .. op
        .. " after dispose() -- this history has been released", 3)
    end
  end

  local function sync_from_bridge()
    location:set(history.to_location(bridge.location_href()))
  end

  local unsubscribe = bridge.on_popstate(function()
    if disposed then return end
    if pending_self_go > 0 then
      -- The echo of our own `go`; `offset` is already correct.
      pending_self_go = pending_self_go - 1
    else
      -- A popstate we did not initiate leaves our position unknown; the
      -- safe report is "no known forward entries".
      offset = 0
    end
    sync_from_bridge()
  end)

  local self = {}

  --- @return hydronium_router.Location
  function self.current()
    return location:get()
  end

  --- `pushState` does NOT fire popstate, so the signal is updated here
  --- explicitly rather than waiting for an event that never arrives.
  function self.push(to, state)
    assert_live("push")
    bridge.push_state(to, state)
    pushes = pushes + 1 - offset  -- pushing while back in the stack drops the forward branch
    offset = 0
    location:set(history.to_location(to, state))
  end

  function self.replace(to, state)
    assert_live("replace")
    bridge.replace_state(to, state)
    location:set(history.to_location(to, state))
  end

  --- The browser applies `go` asynchronously and reports the result via
  --- popstate, so this returns whether the move was REQUESTED, not
  --- whether the location has already changed.
  function self.go(delta)
    assert_live("go")
    delta = delta or 0
    if delta == 0 then return false end
    if delta < 0 and not self.can_go_back() then return false end
    if delta > 0 and not self.can_go_forward() then return false end
    offset = offset + delta
    if offset > 0 then offset = 0 end
    pending_self_go = pending_self_go + 1
    bridge.go(delta)
    return true
  end

  function self.back() return self.go(-1) end
  function self.forward() return self.go(1) end

  function self.can_go_back() return (pushes + offset) > 0 end
  function self.can_go_forward() return offset < 0 end

  --- Idempotent; unsubscribes from popstate on the first call.
  function self.dispose()
    if disposed then return end
    disposed = true
    if type(unsubscribe) == "function" then
      unsubscribe()
    end
  end

  return history.validate(self, "browser history")
end

M.create = M.create_browser_history

return M
