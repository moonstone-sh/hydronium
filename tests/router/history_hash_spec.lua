--[[
  Tests for hydronium_router.history.hash.

  Like tests/router/history_browser_spec.lua, this needs no browser, no
  wasmoon, and no mutation of _G: create_hash_history(bridge) accepts an
  EXPLICIT bridge table. The fake window below is a REAL in-memory stand-in
  for `location.hash` + `hashchange` (it actually stores a hash and fires
  actual change callbacks), not a call-recording mock.

  Unlike the browser fake, this one also models the one genuinely
  browser-specific behavior the adapter depends on: writing the hash
  (`write`) queues its "hashchange" echo rather than firing it
  synchronously -- `fire_pending()` must be called explicitly to deliver
  it, the same way a real event loop tick would. `go` (real
  `history.go()`) fires synchronously here for simplicity, same as the
  browser fake's `go`.
--]]

local h = require("tests.runner")
local describe, it, assert = h.describe, h.it, h.assert

local hydronium = require("hydronium")
local history = require("hydronium_router.history")
local hash_history = require("hydronium_router.history.hash")

local create = hash_history.create_hash_history

--- A real, tiny stand-in for window.location.hash + window.history +
--- "hashchange".
local state_codec = require("hydronium_router.history.state")

local function fake_window(initial_hash)
  local w = {
    hash = initial_hash or "",
    entries = { initial_hash or "" }, -- real session-history hash entries
    index = 1,
    listeners = {},
    unsubscribed = 0,
    pending = {}, -- queued echoes from write(), delivered by fire_pending()
  }

  local function set_hash(new_hash, push)
    w.hash = new_hash
    if push then
      for i = #w.entries, w.index + 1, -1 do w.entries[i] = nil end
      w.index = w.index + 1
      w.entries[w.index] = new_hash
    else
      w.entries[w.index] = new_hash
    end
  end

  w.bridge = {
    read = function() return w.hash end,
    write = function(href, _state)
      set_hash("#" .. href, true)
      -- Real hashchange fires asynchronously; queue it instead of firing now.
      table.insert(w.pending, w.hash)
    end,
    replace = function(href, _state)
      set_hash("#" .. href, false)
      -- replaceState never fires hashchange.
    end,
    go = function(delta)
      local target = w.index + delta
      if target < 1 or target > #w.entries then return end
      w.index = target
      w.hash = w.entries[w.index]
      for _, fn in ipairs(w.listeners) do fn() end
    end,
    on_change = function(fn)
      w.listeners[#w.listeners + 1] = fn
      return function()
        w.unsubscribed = w.unsubscribed + 1
        for i = #w.listeners, 1, -1 do
          if w.listeners[i] == fn then table.remove(w.listeners, i) end
        end
      end
    end,
  }

  --- Delivers every queued write() echo, in order -- simulates the event
  --- loop tick a real "hashchange" would need.
  function w.fire_pending()
    local queued = w.pending
    w.pending = {}
    for _, hash_at_fire in ipairs(queued) do
      w.hash = hash_at_fire
      for _, fn in ipairs(w.listeners) do fn() end
    end
  end

  --- Simulates a genuinely external navigation (hand-edited address bar,
  --- or a browser feature this fake does not otherwise model) -- sets the
  --- hash and fires "hashchange" with no corresponding adapter write.
  function w.external_navigate(new_hash)
    set_hash(new_hash, true)
    for _, fn in ipairs(w.listeners) do fn() end
  end

  return w
end

describe("Router: history.hash", function()

  describe("bridge validation", function()
    it("satisfies the History contract", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      assert.equal(history.validate(hist, "hash history"), hist)
    end)

    it("rejects a bridge missing functions, naming every one", function()
      local ok, err = pcall(create, {})
      assert.falsy(ok)
      err = tostring(err)
      for _, name in ipairs(hash_history.REQUIRED_BRIDGE_FNS) do
        assert.truthy(err:find(name, 1, true), "error should name " .. name .. ": " .. err)
      end
    end)

    it("points at both wiring options in the error", function()
      local ok, err = pcall(create, {})
      assert.falsy(ok)
      err = tostring(err)
      assert.truthy(err:find("__router_hash_", 1, true), err)
      assert.truthy(err:find("hash_history.js", 1, true), err)
    end)

    it("rejects a non-table bridge", function()
      assert.has_error(function() create("nope") end, "bridge must be a table")
    end)

    it("falls back to __router_hash_* globals when no bridge is passed", function()
      assert.is_nil(_G.__router_hash_read, "test precondition: no router hash globals set")
      assert.has_error(function() create() end, "missing required bridge function")
    end)
  end)

  describe("construction", function()
    it("defaults to / when the initial hash is empty", function()
      local hist = create(fake_window("").bridge)
      assert.equal(hist.current().path, "/")
    end)

    it("reads the initial location from the bridge, stripping '#'", function()
      local hist = create(fake_window("#/users/7?tab=a").bridge)
      assert.equal(hist.current().path, "/users/7")
      assert.same(hist.current().query, { tab = "a" })
    end)
  end)

  describe("navigation through the bridge", function()
    it("pushes through the bridge and updates immediately, before the echo fires", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      hist.push("/b", { n = 1 })
      -- Synchronous, matching memory's contract -- no need to fire_pending().
      assert.equal(hist.current().path, "/b")
      assert.same(hist.current().state, { n = 1 })
      assert.equal(w.hash, "#/b")
      assert.equal(#w.entries, 2)
    end)

    it("no-ops when the queued echo of its own write is delivered", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      local runs = 0
      hydronium.createEffect(function()
        hist.current()
        runs = runs + 1
      end)
      hist.push("/b")
      assert.equal(runs, 2)
      w.fire_pending()
      -- The echo matched what the adapter already applied: no extra run.
      assert.equal(runs, 2)
      assert.equal(hist.current().path, "/b")
    end)

    it("replaces through the bridge without growing the stack, and fires no echo", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      hist.push("/b")
      w.fire_pending()
      hist.replace("/c")
      assert.equal(#w.entries, 2)
      assert.equal(hist.current().path, "/c")
      assert.equal(#w.pending, 0, "replaceState must not queue a hashchange echo")
    end)

    it("round-trips nested state through push, replace, back, and forward", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      local pushed = {
        enabled = true,
        count = 3.5,
        labels = { "stage:dev", "sad pepe", "Olá, 世界 👋" },
        nested = { punctuation = [[quotes " slash \\ line
break : ? # & =]], child = { ok = false } },
      }

      hist.push("/b", pushed)
      w.fire_pending()
      assert.same(hist.current().state, pushed)
      assert.falsy(hist.current().state == pushed, "hash state must be a structured copy")

      hist.replace("/c", { replacement = { value = "résumé: ✓" } })
      assert.same(hist.current().state, { replacement = { value = "résumé: ✓" } })

      assert.truthy(hist.back())
      assert.is_nil(hist.current().state, "entry 1 was seeded with nil state")
      assert.truthy(hist.forward())
      assert.same(hist.current().state, { replacement = { value = "résumé: ✓" } })
    end)

    it("parses the query of a pushed href", function()
      local hist = create(fake_window("").bridge)
      hist.push("/search?q=hello+world&t=a&t=b")
      assert.equal(hist.current().path, "/search")
      assert.same(hist.current().query, { q = "hello world", t = { "a", "b" } })
    end)

    it("reconciles an external navigation matching a known entry (physical back button)", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      hist.push("/b")
      w.fire_pending()
      assert.equal(hist.current().path, "/b")

      -- The physical back button: a real browser moves the session-history
      -- index and fires "hashchange" with no bridge.go() call from the
      -- adapter at all -- simulated directly here, bypassing hist.go().
      w.index = 1
      w.hash = w.entries[1]
      for _, fn in ipairs(w.listeners) do fn() end
      assert.equal(hist.current().path, "/a", "should reconcile to the known entry, not append a new one")
      assert.equal(#w.entries, 2, "no new entry should have been appended for a recognized location")
    end)

    it("appends a brand-new entry for an unrecognized external navigation", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      w.external_navigate("#/deep-link")
      assert.equal(hist.current().path, "/deep-link")
      assert.truthy(hist.can_go_back())
      assert.falsy(hist.can_go_forward())
    end)

    it("re-runs a Hydronium effect on navigation", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      local seen = {}
      hydronium.createEffect(function()
        seen[#seen + 1] = hist.current().path
      end)
      hist.push("/b")
      hist.replace("/c")
      assert.same(seen, { "/a", "/b", "/c" })
    end)
  end)

  describe("exact position tracking (unlike history.browser's best-effort)", function()
    it("reports can_go_back / can_go_forward exactly", function()
      local hist = create(fake_window("#/a").bridge)
      assert.falsy(hist.can_go_back())
      assert.falsy(hist.can_go_forward())
      hist.push("/b")
      assert.truthy(hist.can_go_back())
      assert.falsy(hist.can_go_forward())
      hist.back()
      assert.falsy(hist.can_go_back())
      assert.truthy(hist.can_go_forward())
    end)

    it("goes back and forward", function()
      local hist = create(fake_window("#/a").bridge)
      hist.push("/b")
      hist.push("/c")
      assert.truthy(hist.back())
      assert.equal(hist.current().path, "/b")
      assert.truthy(hist.forward())
      assert.equal(hist.current().path, "/c")
    end)

    it("moves by an arbitrary delta", function()
      local hist = create(fake_window("#/a").bridge)
      hist.push("/b")
      hist.push("/c")
      hist.push("/d")
      assert.truthy(hist.go(-3))
      assert.equal(hist.current().path, "/a")
      assert.truthy(hist.go(2))
      assert.equal(hist.current().path, "/c")
    end)

    it("no-ops out-of-range moves rather than clamping or erroring", function()
      local hist = create(fake_window("#/a").bridge)
      assert.falsy(hist.back())
      assert.falsy(hist.forward())
      assert.falsy(hist.go(99))
      assert.falsy(hist.go(0))
      assert.equal(hist.current().path, "/a")
    end)

    it("drops the forward branch when pushing after going back", function()
      local hist = create(fake_window("#/a").bridge)
      hist.push("/b")
      hist.push("/c")
      hist.back()
      assert.truthy(hist.can_go_forward())
      hist.push("/d")
      assert.equal(hist.current().path, "/d")
      assert.falsy(hist.can_go_forward())
    end)
  end)

  describe("dispose", function()
    it("unsubscribes from hashchange exactly once", function()
      local w = fake_window("#/a")
      local hist = create(w.bridge)
      assert.equal(#w.listeners, 1)
      hist.dispose()
      hist.dispose()
      assert.equal(w.unsubscribed, 1)
      assert.equal(#w.listeners, 0)
    end)

    it("makes further navigation a loud error", function()
      local hist = create(fake_window("#/a").bridge)
      hist.dispose()
      assert.has_error(function() hist.push("/b") end, "after dispose")
      assert.has_error(function() hist.replace("/b") end, "after dispose")
      assert.has_error(function() hist.go(1) end, "after dispose")
    end)

    it("still allows reading the last location", function()
      local hist = create(fake_window("#/a").bridge)
      hist.dispose()
      assert.equal(hist.current().path, "/a")
    end)

    it("tolerates a bridge whose on_change returns no unsubscribe", function()
      local w = fake_window("#/a")
      w.bridge.on_change = function() return nil end
      local hist = create(w.bridge)
      hist.dispose()
      assert.equal(hist.current().path, "/a")
    end)
  end)

end)
