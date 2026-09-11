--[[
  Tests for hydronium_router.history.memory and the History contract
  validator in hydronium_router.history.

  `history.memory` is not a test double -- it is the reference
  implementation of the contract AND the real History every non-browser
  consumer uses. So the reactivity assertions below use a real Hydronium
  effect, not a hand-rolled subscription: "an effect that reads
  current() re-runs on navigation" is the actual guarantee components
  will depend on.
--]]

local h = require("tests.runner")
local describe, it, assert = h.describe, h.it, h.assert

local hydronium = require("hydronium")
local history = require("hydronium_router.history")
local memory = require("hydronium_router.history.memory")

local create = memory.create_memory_history

describe("Router: history contract", function()

  it("exposes the nine required function names", function()
    assert.same(history.REQUIRED, {
      "current", "push", "replace", "go", "back", "forward",
      "can_go_back", "can_go_forward", "dispose",
    })
  end)

  it("accepts a complete implementation and returns it unchanged", function()
    local impl = {}
    for _, name in ipairs(history.REQUIRED) do impl[name] = function() end end
    assert.equal(history.validate(impl), impl)
  end)

  it("rejects a missing method, naming it", function()
    local impl = {}
    for _, name in ipairs(history.REQUIRED) do impl[name] = function() end end
    impl.can_go_forward = nil
    assert.has_error(function() history.validate(impl) end, "can_go_forward")
  end)

  it("rejects a wrong-typed method, saying what it is instead", function()
    local impl = {}
    for _, name in ipairs(history.REQUIRED) do impl[name] = function() end end
    impl.push = "nope"
    assert.has_error(function() history.validate(impl) end, "must be a function")
  end)

  it("names every missing method at once, not just the first", function()
    local ok, err = pcall(history.validate, {})
    assert.falsy(ok)
    err = tostring(err)
    for _, name in ipairs(history.REQUIRED) do
      assert.truthy(err:find(name, 1, true), "error should name " .. name .. ": " .. err)
    end
  end)

  it("rejects a non-table", function()
    assert.has_error(function() history.validate(nil) end, "must be a table")
  end)

  it("uses the supplied label in the message", function()
    assert.has_error(function() history.validate({}, "my adapter") end, "my adapter")
  end)

end)

describe("Router: history.to_location", function()

  it("splits an href into path, query, and hash", function()
    local loc = history.to_location("/users/7?tab=a&tab=b#top")
    assert.equal(loc.path, "/users/7")
    assert.same(loc.query, { tab = { "a", "b" } })
    assert.equal(loc.hash, "top")
    assert.equal(loc.href, "/users/7?tab=a&tab=b#top")
  end)

  it("normalizes the path portion", function()
    assert.equal(history.to_location("//a//b/../c/").path, "/a/c")
  end)

  it("gives an empty query table and nil hash when absent", function()
    local loc = history.to_location("/a")
    assert.same(loc.query, {})
    assert.is_nil(loc.hash)
    assert.equal(loc.href, "/a")
  end)

  it("carries opaque state through", function()
    local state = { from = "nav" }
    assert.equal(history.to_location("/a", state).state, state)
  end)

end)

describe("Router: history.memory", function()

  describe("construction", function()
    it("defaults to a single / entry", function()
      local hist = create()
      assert.equal(hist.current().path, "/")
      assert.equal(hist.index(), 1)
      assert.equal(#hist.entries(), 1)
    end)

    it("accepts a single initial href", function()
      assert.equal(create({ initial = "/users/7" }).current().path, "/users/7")
    end)

    it("accepts a whole initial stack, starting at the last entry", function()
      local hist = create({ initial = { "/a", "/b", "/c" } })
      assert.equal(#hist.entries(), 3)
      assert.equal(hist.index(), 3)
      assert.equal(hist.current().path, "/c")
    end)

    it("accepts an explicit starting index within the stack", function()
      local hist = create({ initial = { "/a", "/b", "/c" }, index = 2 })
      assert.equal(hist.current().path, "/b")
      assert.truthy(hist.can_go_back())
      assert.truthy(hist.can_go_forward())
    end)

    it("rejects an empty initial array", function()
      assert.has_error(function() create({ initial = {} }) end, "must not be empty")
    end)

    it("rejects an out-of-range index", function()
      assert.has_error(function() create({ initial = { "/a" }, index = 2 }) end, "out of range")
      assert.has_error(function() create({ initial = { "/a" }, index = 0 }) end, "out of range")
    end)

    --- The reference implementation is the one that must never drift
    --- from the contract it documents. `validate` errors rather than
    --- returning false, and returns the impl unchanged on success.
    it("satisfies the History contract it documents", function()
      local hist = create()
      assert.equal(history.validate(hist, "memory history"), hist)
    end)
  end)

  describe("navigation", function()
    it("pushes a new entry and moves to it", function()
      local hist = create({ initial = "/a" })
      hist.push("/b")
      assert.equal(hist.current().path, "/b")
      assert.equal(hist.index(), 2)
      assert.equal(#hist.entries(), 2)
    end)

    it("replaces the current entry without growing the stack", function()
      local hist = create({ initial = "/a" })
      hist.push("/b")
      hist.replace("/c")
      assert.equal(hist.current().path, "/c")
      assert.equal(#hist.entries(), 2)
      assert.equal(hist.index(), 2)
    end)

    it("goes back and forward", function()
      local hist = create({ initial = "/a" })
      hist.push("/b")
      hist.push("/c")
      assert.truthy(hist.back())
      assert.equal(hist.current().path, "/b")
      assert.truthy(hist.forward())
      assert.equal(hist.current().path, "/c")
    end)

    it("moves by an arbitrary delta", function()
      local hist = create({ initial = { "/a", "/b", "/c", "/d" } })
      assert.truthy(hist.go(-3))
      assert.equal(hist.current().path, "/a")
      assert.truthy(hist.go(2))
      assert.equal(hist.current().path, "/c")
    end)

    --- A real browser's history.go is a NO-OP when out of range; it does
    --- not clamp and it does not throw.
    it("no-ops out-of-range moves rather than clamping or erroring", function()
      local hist = create({ initial = "/a" })
      assert.falsy(hist.back())
      assert.falsy(hist.forward())
      assert.falsy(hist.go(99))
      assert.falsy(hist.go(0))
      assert.equal(hist.current().path, "/a")
      assert.equal(hist.index(), 1)
    end)

    it("reports can_go_back / can_go_forward exactly", function()
      local hist = create({ initial = "/a" })
      assert.falsy(hist.can_go_back())
      assert.falsy(hist.can_go_forward())
      hist.push("/b")
      assert.truthy(hist.can_go_back())
      assert.falsy(hist.can_go_forward())
      hist.back()
      assert.falsy(hist.can_go_back())
      assert.truthy(hist.can_go_forward())
    end)

    it("carries state on push and replace", function()
      local hist = create()
      hist.push("/b", { n = 1 })
      assert.same(hist.current().state, { n = 1 })
      hist.replace("/c", { n = 2 })
      assert.same(hist.current().state, { n = 2 })
    end)

    it("parses the query of a pushed href", function()
      local hist = create()
      hist.push("/search?q=hello+world&t=a&t=b")
      assert.equal(hist.current().path, "/search")
      assert.same(hist.current().query, { q = "hello world", t = { "a", "b" } })
    end)
  end)

  describe("forward truncation", function()
    --- Standard history-stack semantics. Without truncation, a stale
    --- forward branch would stay reachable via forward(), which no real
    --- history behaves like.
    it("drops the forward entries when pushing after going back", function()
      local hist = create({ initial = { "/a", "/b", "/c" } })
      hist.back()                        -- at /b, /c is ahead
      assert.truthy(hist.can_go_forward())
      hist.push("/d")
      assert.equal(hist.current().path, "/d")
      assert.equal(#hist.entries(), 3)   -- /a, /b, /d -- /c is gone
      assert.falsy(hist.can_go_forward())
      assert.falsy(hist.forward())
    end)

    it("drops several forward entries at once", function()
      local hist = create({ initial = { "/a", "/b", "/c", "/d", "/e" } })
      hist.go(-4)
      hist.push("/new")
      assert.equal(#hist.entries(), 2)
      assert.equal(hist.entries()[1].path, "/a")
      assert.equal(hist.entries()[2].path, "/new")
    end)

    it("does NOT truncate on replace", function()
      local hist = create({ initial = { "/a", "/b", "/c" } })
      hist.back()
      hist.replace("/b2")
      assert.equal(#hist.entries(), 3)
      assert.truthy(hist.can_go_forward())
    end)
  end)

  describe("reactivity", function()
    --- The real guarantee: current() reads a Hydronium signal, so an
    --- ordinary effect re-runs on navigation with no router-specific
    --- subscription mechanism.
    it("re-runs an effect that reads current() on push", function()
      local hist = create({ initial = "/a" })
      local seen = {}
      hydronium.createEffect(function()
        seen[#seen + 1] = hist.current().path
      end)
      assert.same(seen, { "/a" })
      hist.push("/b")
      assert.same(seen, { "/a", "/b" })
      hist.push("/c")
      assert.same(seen, { "/a", "/b", "/c" })
    end)

    it("re-runs an effect on replace, back, and forward", function()
      local hist = create({ initial = "/a" })
      hist.push("/b")
      local seen = {}
      hydronium.createEffect(function()
        seen[#seen + 1] = hist.current().path
      end)
      hist.replace("/b2")
      hist.back()
      hist.forward()
      assert.same(seen, { "/b", "/b2", "/a", "/b2" })
    end)

    it("does not re-run an effect on a no-op out-of-range go", function()
      local hist = create({ initial = "/a" })
      local runs = 0
      hydronium.createEffect(function()
        hist.current()
        runs = runs + 1
      end)
      assert.equal(runs, 1)
      hist.go(5)
      hist.back()
      assert.equal(runs, 1)
    end)

    it("exposes current as a plain function, not a signal accessor table", function()
      -- The contract requires type(h.current) == "function" so every
      -- adapter looks the same to validate() and to callers.
      assert.is_function(create().current)
    end)
  end)

  describe("dispose", function()
    it("is idempotent", function()
      local hist = create()
      hist.dispose()
      hist.dispose()
    end)

    it("makes further navigation a loud error rather than a silent no-op", function()
      local hist = create()
      hist.dispose()
      assert.has_error(function() hist.push("/b") end, "after dispose")
      assert.has_error(function() hist.replace("/b") end, "after dispose")
      assert.has_error(function() hist.go(1) end, "after dispose")
    end)

    it("still allows reading the last location", function()
      local hist = create({ initial = "/a" })
      hist.dispose()
      assert.equal(hist.current().path, "/a")
    end)
  end)

  describe("entries introspection", function()
    it("returns a copy, so callers cannot corrupt the stack", function()
      local hist = create({ initial = { "/a", "/b" } })
      local snapshot = hist.entries()
      snapshot[1] = "clobbered"
      assert.equal(hist.entries()[1].path, "/a")
    end)
  end)

end)
