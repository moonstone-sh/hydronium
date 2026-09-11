--[[
  hydronium_router.history -- the History interface contract, plus a
  cheap runtime validator every adapter can run against itself.

  A History is the router's only stateful dependency and the only place
  the outside world (a browser, a terminal app, a test) gets to differ.
  Keeping it to nine functions means a new host is a small, obviously
  complete file rather than a reimplementation of routing.

  `hydronium_router.history.memory` is BOTH the reference implementation
  of this contract and the real one used by Ink, native hosts and tests;
  `hydronium_router.history.browser` adapts the real `window.history`
  through an injectable bridge.

  --- LOCATION -----------------------------------------------------------

  @class hydronium_router.Location
  @field href string   the canonical href, e.g. "/users/7?tab=a#top"
  @field path string   normalized path only, e.g. "/users/7"
  @field query table   parsed query (repeated keys become arrays)
  @field hash string|nil  fragment without "#", nil when absent
  @field state any     opaque caller state carried with the entry

  --- HISTORY ------------------------------------------------------------

  @class hydronium_router.History
  @field current fun(): hydronium_router.Location
    A REACTIVE GETTER. It must read a Hydronium signal internally so that
    an effect or binding calling it re-runs on navigation. It is a plain
    function (not a signal accessor table) so `type(h.current)` is
    "function" for every adapter.
  @field push fun(to: string, state?: any)
    Navigate, adding an entry. Must TRUNCATE any forward entries first --
    standard history-stack semantics.
  @field replace fun(to: string, state?: any)
    Navigate, overwriting the current entry.
  @field go fun(delta: integer): boolean
    Move by `delta` entries. Returns false and does nothing when the
    target is out of range (the same no-op a browser performs).
  @field back fun(): boolean       -- go(-1)
  @field forward fun(): boolean    -- go(1)
  @field can_go_back fun(): boolean
  @field can_go_forward fun(): boolean
  @field dispose fun()
    Release any host subscription. Must be idempotent.
--]]

local url = require("hydronium_router.url")

local M = {}

--- Build a canonical Location from an href string.
---
--- Lives here, next to the `@class hydronium_router.Location` it
--- produces, so both adapters construct byte-identical locations from
--- the same input instead of each rolling their own splitting rules.
---
--- @param href string
--- @param state? any
--- @return hydronium_router.Location
function M.to_location(href, state)
  local raw_path, raw_query, hash = url.split(href)
  local path = url.normalize_path(raw_path)

  local canonical = path
  if raw_query and raw_query ~= "" then canonical = canonical .. "?" .. raw_query end
  if hash and hash ~= "" then canonical = canonical .. "#" .. hash end

  return {
    href = canonical,
    path = path,
    query = url.parse_query(raw_query),
    hash = (hash ~= "" ) and hash or nil,
    state = state,
  }
end

--- The nine functions every History adapter must provide.
M.REQUIRED = {
  "current",
  "push",
  "replace",
  "go",
  "back",
  "forward",
  "can_go_back",
  "can_go_forward",
  "dispose",
}

--- Assert that `impl` implements the History contract.
---
--- Deliberately shallow and cheap: it checks presence and basic type,
--- not behavior. That is enough to turn the most common adapter mistake
--- (a forgotten or misspelled method) from a confusing "attempt to call
--- a nil value" at some unrelated navigation site into a named error at
--- construction time, and it costs an adapter one line in its own tests.
---
--- @param impl table
--- @param label? string  name used in the error message
--- @return table impl  returned unchanged, so it can wrap a constructor
function M.validate(impl, label)
  label = label or "history"

  if type(impl) ~= "table" then
    error("hydronium_router.history.validate: " .. label
      .. " must be a table, got " .. type(impl), 2)
  end

  local missing = {}
  for _, name in ipairs(M.REQUIRED) do
    if type(impl[name]) ~= "function" then
      missing[#missing + 1] = name
        .. (impl[name] == nil and "" or (" (is a " .. type(impl[name]) .. ", must be a function)"))
    end
  end

  if #missing > 0 then
    error("hydronium_router.history.validate: " .. label
      .. " does not implement the History contract -- missing or wrong-typed: "
      .. table.concat(missing, ", ")
      .. ". See hydronium_router/history/init.lua for the full contract.", 2)
  end

  return impl
end

return M
