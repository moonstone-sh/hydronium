--[[
  Tests for hydronium_router.history.browser.

  The whole point of `create_browser_history(bridge)` accepting an
  EXPLICIT bridge table -- rather than only reading the `__router_*`
  globals a real page installs -- is that this file needs no browser, no
  wasmoon, and no mutation of `_G`. Same rationale as
  `tests/host/dom_spec.lua` for the `__dom_*` bridge.

  The fake bridge below is a REAL in-memory implementation of the five
  documented functions (it keeps an actual entry stack and fires actual
  popstate callbacks), not a mock that only records calls, so these
  tests assert on resulting state rather than on "was this called".
--]]

local h = require("tests.runner")
local describe, it, assert = h.describe, h.it, h.assert

local hydronium = require("hydronium")
local history = require("hydronium_router.history")
local browser = require("hydronium_router.history.browser")

local create = browser.create_browser_history

--- A real, tiny stand-in for window.history + window.location.
local function fake_window(initial)
  local w = {
    entries = { initial or "/" },
    index = 1,
    listeners = {},
    unsubscribed = 0,
  }

  w.bridge = {
    push_state = function(url, state)
      for i = #w.entries, w.index + 1, -1 do w.entries[i] = nil end
      w.index = w.index + 1
      w.entries[w.index] = url
      w.last_state = state
    end,
    replace_state = function(url, state)
      w.entries[w.index] = url
      w.last_state = state
    end,
    go = function(delta)
      local target = w.index + delta
      if target < 1 or target > #w.entries then return end
      w.index = target
      -- A real browser dispatches popstate asynchronously; firing it
      -- synchronously here is enough to exercise the subscription.
      for _, fn in ipairs(w.listeners) do fn() end
    end,
    location_href = function() return w.entries[w.index] end,
    on_popstate = function(fn)
      w.listeners[#w.listeners + 1] = fn
      return function()
        w.unsubscribed = w.unsubscribed + 1
        for i = #w.listeners, 1, -1 do
          if w.listeners[i] == fn then table.remove(w.listeners, i) end
        end
      end
    end,
  }

  return w
end

describe("Router: history.browser", function()

  describe("bridge validation", function()
    it("satisfies the History contract", function()
      local w = fake_window("/a")
      local hist = create(w.bridge)
      assert.equal(history.validate(hist, "browser history"), hist)
    end)

    it("rejects a bridge missing functions, naming every one", function()
      local ok, err = pcall(create, {})
      assert.falsy(ok)
      err = tostring(err)
      for _, name in ipairs(browser.REQUIRED_BRIDGE_FNS) do
        assert.truthy(err:find(name, 1, true), "error should name " .. name .. ": " .. err)
      end
    end)

    it("points at both wiring options in the error", function()
      local ok, err = pcall(create, {})
      assert.falsy(ok)
      err = tostring(err)
      assert.truthy(err:find("__router_", 1, true), err)
      assert.truthy(err:find("history.js", 1, true), err)
    end)

    it("rejects a non-table bridge", function()
      assert.has_error(function() create("nope") end, "bridge must be a table")
    end)

    --- The no-argument form reads `__router_*` globals. With none set,
    --- it must fail with the same named-function error rather than a
    --- cryptic nil call later.
    it("falls back to __router_* globals when no bridge is passed", function()
      assert.is_nil(_G.__router_push_state, "test precondition: no router globals set")
      assert.has_error(function() create() end, "missing required bridge function")
    end)
  end)

  describe("navigation through the bridge", function()
    it("reads the initial location from the bridge", function()
      local hist = create(fake_window("/users/7?tab=a").bridge)
      assert.equal(hist.current().path, "/users/7")
      assert.same(hist.current().query, { tab = "a" })
    end)

    it("pushes through the bridge and updates immediately", function()
      -- pushState does NOT fire popstate in a real browser, so the
      -- adapter must update the signal itself.
      local w = fake_window("/a")
      local hist = create(w.bridge)
      hist.push("/b", { n = 1 })
      assert.equal(w.entries[w.index], "/b")
      assert.same(w.last_state, { n = 1 })
      assert.equal(hist.current().path, "/b")
    end)

    it("replaces through the bridge without growing the stack", function()
      local w = fake_window("/a")
      local hist = create(w.bridge)
      hist.push("/b")
      hist.replace("/c")
      assert.equal(#w.entries, 2)
      assert.equal(hist.current().path, "/c")
    end)

    it("updates from a popstate the adapter did not initiate", function()
      local w = fake_window("/a")
      local hist = create(w.bridge)
      hist.push("/b")
      -- The user presses the browser back button: the window moves and
      -- fires popstate without going through the adapter's go().
      w.index = 1
      for _, fn in ipairs(w.listeners) do fn() end
      assert.equal(hist.current().path, "/a")
    end)

    it("re-runs a Hydronium effect on navigation", function()
      local w = fake_window("/a")
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

  describe("best-effort position tracking", function()
    --- Exact in history.memory, approximate here: the DOM History API
    --- exposes no position within the stack. The adapter tracks only
    --- what it did itself. These tests pin that documented behaviour.
    it("reports no back available before it has pushed anything", function()
      local hist = create(fake_window("/a").bridge)
      assert.falsy(hist.can_go_back())
      assert.falsy(hist.can_go_forward())
    end)

    it("reports back available after its own push", function()
      local hist = create(fake_window("/a").bridge)
      hist.push("/b")
      assert.truthy(hist.can_go_back())
      assert.falsy(hist.can_go_forward())
    end)

    it("reports forward available after its own back", function()
      local w = fake_window("/a")
      local hist = create(w.bridge)
      hist.push("/b")
      assert.truthy(hist.back())
      assert.equal(hist.current().path, "/a")
      assert.truthy(hist.can_go_forward())
    end)

    it("refuses a move it knows is out of range", function()
      local hist = create(fake_window("/a").bridge)
      assert.falsy(hist.back())
      assert.falsy(hist.forward())
      assert.falsy(hist.go(0))
    end)

    it("drops the forward branch when pushing after going back", function()
      local w = fake_window("/a")
      local hist = create(w.bridge)
      hist.push("/b")
      hist.back()
      hist.push("/c")
      assert.falsy(hist.can_go_forward())
      assert.equal(hist.current().path, "/c")
    end)

    it("treats an external popstate as making forward unknown", function()
      local w = fake_window("/a")
      local hist = create(w.bridge)
      hist.push("/b")
      hist.back()
      assert.truthy(hist.can_go_forward())
      -- An external popstate arrives; position is no longer knowable.
      for _, fn in ipairs(w.listeners) do fn() end
      assert.falsy(hist.can_go_forward())
    end)
  end)

  describe("dispose", function()
    it("unsubscribes from popstate exactly once", function()
      local w = fake_window("/a")
      local hist = create(w.bridge)
      assert.equal(#w.listeners, 1)
      hist.dispose()
      hist.dispose()
      assert.equal(w.unsubscribed, 1)
      assert.equal(#w.listeners, 0)
    end)

    it("makes further navigation a loud error", function()
      local hist = create(fake_window("/a").bridge)
      hist.dispose()
      assert.has_error(function() hist.push("/b") end, "after dispose")
      assert.has_error(function() hist.replace("/b") end, "after dispose")
      assert.has_error(function() hist.go(1) end, "after dispose")
    end)

    it("tolerates a bridge whose on_popstate returns no unsubscribe", function()
      local w = fake_window("/a")
      w.bridge.on_popstate = function() return nil end
      local hist = create(w.bridge)
      hist.dispose()
      assert.equal(hist.current().path, "/a")
    end)
  end)

end)
