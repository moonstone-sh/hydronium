--[[
  hydronium_router.history.hash -- a History backed by `location.hash` +
  the `hashchange` event, reached through an injectable bridge.

  Modeled on `history.memory` (own authoritative entry stack, synchronous
  navigation), NOT on `history.browser` (best-effort position tracking
  over the DOM History API's opaque `history.length`). The two histories
  differ in exactly what makes that possible: `browser`'s pushState-based
  entries are NOT self-describing (a `popstate` event carries no url the
  adapter didn't already have, and `history.length` counts entries outside
  this page's own session too), so it can only track its OWN pushes and
  reports "unknown" the moment an external popstate arrives. This adapter,
  by contrast, OWNS the meaning of every entry it navigates to: every
  entry it ever visits was produced by writing `location.hash` itself (via
  `push`) or by moving among entries it already knows (via `go`), so the
  full stack -- and therefore `can_go_back`/`can_go_forward` -- stays
  EXACT, the same guarantee `memory` makes, not `browser`'s approximation.

  BRIDGE CONTRACT -- five functions, either passed explicitly as a table
  to `create_hash_history(bridge)` or (if omitted) read from plain Lua
  globals named `__router_hash_<name>`:

    read() -> string                    -- raw `location.hash`, "#..." or ""
    write(href: string, state_json: string)
                                         -- location.hash = href (pushes a
                                            real session-history entry),
                                            then attaches state via
                                            replaceState
    replace(href: string, state_json: string)
                                         -- replaceState with a rewritten
                                            hash; no new entry
    go(delta: integer)                  -- window.history.go(delta)
    on_change(fn) -> unsubscribe|nil    -- fn is called with no arguments
                                            after a real "hashchange"

  This is the same injectable-table-or-global-fallback shape
  `hydronium_router.history.browser` and `hydronium_dom.host.dom`'s
  `createDomHost` use, and for the same reason: the explicit-table form
  makes this module unit-testable with a fake bridge, with no browser, no
  wasmoon, and no mutation of `_G`.

  `router/client/hash_history.js` is the real browser-side shim
  implementing these five functions against `window.location` and
  `window.addEventListener("hashchange", ...)`.

  --- WHY THE ECHO-SUPPRESSION, NOT A COUNTER ----------------------------

  Unlike `pushState`/`replaceState` (which never fire any event),
  assigning `location.hash` DOES fire a real `hashchange` for the
  navigation it just caused -- queued as a task, not synchronous. Every
  `push`/`replace`/`go` call below already applies its own effect to
  `entries`/`index` synchronously (matching `memory`'s synchronous
  contract: `current()` reflects the new location the instant the call
  returns). The `on_change` handler installed once at construction then
  sees that same change echoed back a tick later; it recognizes its own
  echo by comparing the fired hash against `last_written` (the hash text
  this adapter itself most recently produced) and no-ops when they match.
  Anything else reaching the handler is a real external navigation -- the
  user's physical back/forward buttons, or a hand-edited address bar --
  and is reconciled against the known entry stack, or appended as a new
  entry if the hash matches none of them (e.g. a fresh deep link typed by
  hand after the page has already navigated once).

  --- AN HONEST LIMITATION ------------------------------------------------

  State does not survive a hard reload: entry 1 always seeds with
  `state = nil`, matching a real browser's own behavior for a document
  freshly requested from the network (no in-memory VM ever existed to
  have attached anything). This is not a bridge-widened gap -- pushing
  `location.hash` around a reload is not needed for M1-scope routing
  either, since the hash itself IS part of the URL and survives a reload
  on its own; only opaque caller `state` (not represented in the hash
  text) is lost. Also unhandled: percent-encoding round-trips through
  `location.hash` for characters outside typical path/query bytes (a real
  but narrow gap `history.browser` does not have, because `pushState`
  URLs are not read back through the fragment's own decode rules).
--]]

local hydronium = require("hydronium.core")
local history = require("hydronium_router.history")
local state_codec = require("hydronium_router.history.state")

local M = {}

M.REQUIRED_BRIDGE_FNS = { "read", "write", "replace", "go", "on_change" }

local function default_bridge()
  return {
    read = _G.__router_hash_read,
    write = _G.__router_hash_write,
    replace = _G.__router_hash_replace,
    go = _G.__router_hash_go,
    on_change = _G.__router_hash_on_change,
  }
end

--- Strips a leading "#" and normalizes an empty fragment to "/", so
--- `history.to_location` always receives a real path-shaped href.
--- @param raw string|nil  verbatim `location.hash` text
--- @return string
local function strip_hash_prefix(raw)
  if raw == nil or raw == "" then return "/" end
  if raw:sub(1, 1) == "#" then raw = raw:sub(2) end
  if raw == "" then return "/" end
  return raw
end

--- @param href string  a canonical Location href, e.g. "/users/7?tab=a"
--- @return string  the exact text this adapter expects `bridge.read()` to
---   echo back once the browser applies it (leading "#", matching how
---   `location.hash` always reads back once set to a non-empty value).
local function expected_hash_text(href)
  return "#" .. href
end

--- Create a hash-backed history.
---
--- @param bridge? table  Explicit bridge table (see the module doc
---   comment). Omit to read the `__router_hash_*` globals instead -- the
---   real-browser-page default.
--- @return table history  implements hydronium_router.History
function M.create_hash_history(bridge)
  bridge = bridge or default_bridge()

  if type(bridge) ~= "table" then
    error("hydronium_router.history.hash.create_hash_history: bridge must be a table, got "
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
      "hydronium_router.history.hash.create_hash_history: missing required bridge function(s): "
      .. table.concat(missing, ", ")
      .. " -- either pass a bridge table (create_hash_history({ read = ..., ... })), "
      .. "or set the corresponding __router_hash_<name> globals before calling it with no argument. "
      .. "router/client/hash_history.js installs exactly these five.",
      2
    )
  end

  local entries, index = {}, 1
  entries[1] = history.to_location(strip_hash_prefix(bridge.read()), nil)

  local location = hydronium.createSignal(entries[index])
  local disposed = false
  local last_written = bridge.read()

  local function assert_live(op)
    if disposed then
      error("hydronium_router.history.hash: cannot " .. op
        .. " after dispose() -- this history has been released", 3)
    end
  end

  local function sync()
    location:set(entries[index])
  end

  local self = {}

  --- @return hydronium_router.Location
  function self.current()
    return location:get()
  end

  --- Standard history-stack semantics: pushing after going back TRUNCATES
  --- the forward entries, exactly like `memory.push`.
  function self.push(to, state)
    assert_live("push")
    for i = #entries, index + 1, -1 do
      entries[i] = nil
    end
    index = index + 1
    local encoded = state_codec.encode(state)
    entries[index] = history.to_location(to, state_codec.decode(encoded))
    last_written = expected_hash_text(entries[index].href)
    bridge.write(entries[index].href, encoded)
    sync()
  end

  function self.replace(to, state)
    assert_live("replace")
    local encoded = state_codec.encode(state)
    entries[index] = history.to_location(to, state_codec.decode(encoded))
    last_written = expected_hash_text(entries[index].href)
    bridge.replace(entries[index].href, encoded)
    sync()
  end

  --- @return boolean moved  false (and no change) when out of range --
  ---   the same no-op a browser's `history.go` performs.
  function self.go(delta)
    assert_live("go")
    delta = delta or 0
    local target = index + delta
    if delta == 0 or target < 1 or target > #entries then return false end
    index = target
    last_written = expected_hash_text(entries[index].href)
    bridge.go(delta)
    sync()
    return true
  end

  function self.back() return self.go(-1) end
  function self.forward() return self.go(1) end

  --- EXACT, unlike `history.browser`'s best-effort report -- see this
  --- module's own doc comment for why the full stack is knowable here.
  function self.can_go_back() return index > 1 end
  function self.can_go_forward() return index < #entries end

  --- Idempotent; unsubscribes from "hashchange" on the first call.
  local unsubscribe = bridge.on_change(function()
    if disposed then return end
    local raw = bridge.read()
    local full = (raw ~= nil and raw:sub(1, 1) == "#") and raw or ("#" .. (raw or ""))
    if full == last_written then
      -- The queued echo of our own write/go; already applied above.
      return
    end

    local href = strip_hash_prefix(raw)
    local found = nil
    for i = 1, #entries do
      if entries[i].href == href then
        found = i
        break
      end
    end
    if found then
      index = found
    else
      -- Unrecognized location (a hand-edited address bar, or a deep link
      -- opened in a tab this adapter has been running in all along):
      -- treat it as a fresh navigation, truncating any forward branch,
      -- same as `push` would.
      for i = #entries, index + 1, -1 do
        entries[i] = nil
      end
      index = index + 1
      entries[index] = history.to_location(href, nil)
    end
    last_written = full
    sync()
  end)

  function self.dispose()
    if disposed then return end
    disposed = true
    if type(unsubscribe) == "function" then
      unsubscribe()
    end
  end

  return history.validate(self, "hash history")
end

M.create = M.create_hash_history

return M
