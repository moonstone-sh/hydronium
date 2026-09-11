--[[
  hydronium_router.history.memory -- a complete in-memory History.

  This is NOT a test double. It is the reference implementation of the
  contract in `hydronium_router/history/init.lua` AND the real History
  every non-browser consumer uses directly: Ink/terminal apps, native
  hosts, SSR, and tests. The browser adapter is the special case, not
  this one.

  `current()` reads a REAL Hydronium signal, so an effect or binding that
  calls it re-runs on navigation exactly like any other reactive read --
  there is no polling and no router-specific subscription mechanism.
  Every navigation stores a freshly-built Location table, so the signal's
  default `==` equality always sees a change and always notifies.
--]]

local hydronium = require("hydronium")
local history = require("hydronium_router.history")

local M = {}

--- Create an in-memory history.
---
--- @param opts? table
---   `.initial` string|string[]  initial entry, or a whole stack.
---                               Default "/".
---   `.index` integer            starting position within `.initial`
---                               when it is an array. Default: the last.
---   `.state` any                state for a single-string `.initial`.
--- @return table history  implements hydronium_router.History
function M.create_memory_history(opts)
  opts = opts or {}

  local entries = {}
  local initial = opts.initial or "/"
  if type(initial) == "table" then
    if #initial == 0 then
      error("hydronium_router.history.memory: opts.initial array must not be empty", 2)
    end
    for i = 1, #initial do
      entries[i] = history.to_location(initial[i])
    end
  else
    entries[1] = history.to_location(initial, opts.state)
  end

  local index = opts.index or #entries
  if type(index) ~= "number" or index < 1 or index > #entries or index % 1 ~= 0 then
    error("hydronium_router.history.memory: opts.index " .. tostring(opts.index)
      .. " is out of range 1.." .. #entries, 2)
  end

  local location = hydronium.createSignal(entries[index])
  local disposed = false

  local function assert_live(op)
    if disposed then
      error("hydronium_router.history.memory: cannot " .. op
        .. " after dispose() -- this history has been released", 3)
    end
  end

  local function sync()
    location:set(entries[index])
  end

  local self = {}

  --- Reactive getter: reading it inside an effect subscribes that effect
  --- to navigation.
  --- @return hydronium_router.Location
  function self.current()
    return location:get()
  end

  --- Standard history-stack semantics: pushing after going back
  --- TRUNCATES the forward entries. Without this, back-then-push would
  --- leave a stale forward branch reachable by `forward()`, which no
  --- real history behaves like.
  function self.push(to, state)
    assert_live("push")
    for i = #entries, index + 1, -1 do
      entries[i] = nil
    end
    index = index + 1
    entries[index] = history.to_location(to, state)
    sync()
  end

  function self.replace(to, state)
    assert_live("replace")
    entries[index] = history.to_location(to, state)
    sync()
  end

  --- @return boolean moved  false (and no change) when out of range,
  ---   which is what a real browser's history.go does rather than
  ---   clamping or erroring.
  function self.go(delta)
    assert_live("go")
    delta = delta or 0
    local target = index + delta
    if target < 1 or target > #entries then return false end
    if target == index then return false end
    index = target
    sync()
    return true
  end

  function self.back() return self.go(-1) end
  function self.forward() return self.go(1) end

  function self.can_go_back() return index > 1 end
  function self.can_go_forward() return index < #entries end

  --- Idempotent, per the contract.
  function self.dispose()
    disposed = true
  end

  -- Introspection beyond the contract, for tests and debugging.
  --- @return hydronium_router.Location[] a copy of the entry stack
  function self.entries()
    local out = {}
    for i = 1, #entries do out[i] = entries[i] end
    return out
  end

  --- @return integer current position, 1-based
  function self.index() return index end

  -- Self-check: this module is the reference implementation, so it is
  -- the one that must never drift from the contract it documents.
  return history.validate(self, "memory history")
end

M.create = M.create_memory_history

return M
