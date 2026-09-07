local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local refresh = require("hydronium.core.refresh")

-- Descriptor shorthand matching what a future LUAX compiler pass would
-- attach per `scope:signal(...)`-shaped call site. `block_path` stands
-- in for the compiler's lexical-block identity (see
-- docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md) -- hand-written here since
-- no compiler pass exists yet; this spec proves the matching algorithm
-- itself, independent of how descriptors eventually get attached.
local function d(name, block_path, kind)
  return { kind = kind or "signal", name = name, block_path = block_path or "Counter.setup" }
end

describe("hydronium.core.refresh.RefreshRegistry (HMR resource-identity proof)", function()

  it("preserves state across a pure markup edit (same declarations, different surrounding code)", function()
    local reg = refresh.RefreshRegistry.new()

    reg:begin_generation()
    local count = reg:signal(10, d("count"))
    reg:finish_generation()
    count.set(count.get() + 2) -- simulate two clicks: 10 -> 12

    -- "Edit": rerun setup with the identical declaration (same descriptor)
    -- but pretend the surrounding markup/label changed -- irrelevant to
    -- the registry, which only ever sees the descriptor.
    reg:begin_generation()
    local count2 = reg:signal(999, d("count")) -- initializer literal changed; must NOT reset to 999
    local report = reg:finish_generation()

    assert.equal(count2.get(), 12, "markup edit must preserve the existing value, not the new initializer")
    assert.equal(#report.preserved, 1)
    assert.equal(report.preserved[1], "count")
  end)

  it("preserves state across a comment-insertion / formatter-shaped edit (block_path/name/kind unaffected)", function()
    -- A comment insertion or formatter run changes source position, not
    -- lexical block identity, binding name, or resource kind -- so the
    -- descriptor a real compiler pass would attach is identical across
    -- the edit. Modeled directly: same descriptor, different "generation".
    local reg = refresh.RefreshRegistry.new()
    reg:begin_generation()
    local count = reg:signal(10, d("count"))
    reg:finish_generation()
    count.set(count.get() + 5) -- 15

    reg:begin_generation()
    local count2 = reg:signal(10, d("count"))
    reg:finish_generation()

    assert.equal(count2.get(), 15)
  end)

  it("never cross-wires state when two signals are reordered (the disqualifying failure mode for position-based identity)", function()
    local reg = refresh.RefreshRegistry.new()

    reg:begin_generation()
    local count = reg:signal(0, d("count"))
    local name = reg:signal("", d("name"))
    reg:finish_generation()
    count.set(100)
    name.set("alice")

    -- Reorder: `name` declared first, `count` second. Position-based
    -- identity would have count's NEW position collide with name's OLD
    -- position (see the falsification table in
    -- docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md) -- name-based matching
    -- must not care about order at all.
    reg:begin_generation()
    local name2 = reg:signal("", d("name"))
    local count2 = reg:signal(0, d("count"))
    local report = reg:finish_generation()

    assert.equal(count2.get(), 100, "count must keep its OWN old value after reorder")
    assert.equal(name2.get(), "alice", "name must keep its OWN old value after reorder, not count's")
    assert.equal(#report.preserved, 2)
  end)

  it("preserves surrounding signals and creates the new one when a signal is inserted between two existing ones", function()
    local reg = refresh.RefreshRegistry.new()
    reg:begin_generation()
    local a = reg:signal(1, d("a"))
    local c = reg:signal(3, d("c"))
    reg:finish_generation()
    a.set(11)
    c.set(33)

    reg:begin_generation()
    local a2 = reg:signal(1, d("a"))
    local b2 = reg:signal(2, d("b")) -- newly inserted between a and c
    local c2 = reg:signal(3, d("c"))
    local report = reg:finish_generation()

    assert.equal(a2.get(), 11, "a must be preserved -- unaffected by a new sibling declared after it")
    assert.equal(c2.get(), 33, "c must be preserved despite a new sibling (b) now appearing before it in declaration order")
    assert.equal(b2.get(), 2, "b is genuinely new and must start at its own initializer")
    assert.equal(#report.preserved, 2)
    assert.equal(#report.created, 1)
    assert.equal(report.created[1], "b")
  end)

  it("does NOT reuse state when a declaration's resource kind changes (signal -> a different kind), even with the same name", function()
    local reg = refresh.RefreshRegistry.new()
    reg:begin_generation()
    local state = reg:signal(1, d("state", "Counter.setup", "signal"))
    reg:finish_generation()
    state.set(42)

    reg:begin_generation()
    -- Same name, same block_path, DIFFERENT kind -- simulating `local
    -- state = scope:signal(...)` becoming `local state =
    -- scope:resource(...)`. Kind is part of the match key; this must be
    -- treated as unrelated to the old signal.
    local state2 = reg:signal(1, d("state", "Counter.setup", "resource"))
    local report = reg:finish_generation()

    assert.equal(state2.get(), 1, "a kind change must never inherit the old (incompatible) value")
    assert.equal(#report.preserved, 0)
    assert.equal(#report.created, 1)
  end)

  it("treats a single unmatched old + single unmatched new of the same kind as a probable rename and preserves state", function()
    local reg = refresh.RefreshRegistry.new()
    reg:begin_generation()
    local count = reg:signal(0, d("count"))
    reg:finish_generation()
    count.set(7)

    reg:begin_generation()
    -- Renamed local variable: `count` -> `clicks`. No primary-key match
    -- (name changed), but exactly one leftover on each side of the same
    -- kind -- a confident rename.
    local clicks = reg:signal(0, d("clicks"))
    local report = reg:finish_generation()

    assert.equal(clicks.get(), 7, "a confident single-candidate rename must preserve state")
    assert.equal(#report.renamed, 1)
  end)

  it("resets safely (never cross-wires) when a rename is ambiguous -- more than one unmatched candidate on either side", function()
    local reg = refresh.RefreshRegistry.new()
    reg:begin_generation()
    local x = reg:signal(0, d("x"))
    local y = reg:signal(0, d("y"))
    reg:finish_generation()
    x.set(1)
    y.set(2)

    reg:begin_generation()
    -- Both renamed simultaneously to names that don't match either old
    -- one: two unmatched-old, two unmatched-new, same kind. Ambiguous --
    -- must not guess a pairing.
    local p = reg:signal(0, d("p"))
    local q = reg:signal(0, d("q"))
    local report = reg:finish_generation()

    assert.equal(p.get(), 0, "ambiguous rename must reset rather than risk a wrong pairing")
    assert.equal(q.get(), 0, "ambiguous rename must reset rather than risk a wrong pairing")
    assert.equal(#report.renamed, 0)
    assert.equal(#report.created, 2)
  end)

  it("a genuinely removed declaration is reported as disposed and does not resurface", function()
    local reg = refresh.RefreshRegistry.new()
    reg:begin_generation()
    reg:signal(0, d("count"))
    reg:signal("", d("name"))
    reg:finish_generation()

    reg:begin_generation()
    reg:signal(0, d("count")) -- `name` deleted
    local report = reg:finish_generation()

    assert.equal(#report.disposed, 1)
    assert.equal(report.disposed[1], "name")
  end)

  it("proves the setup-rerun model end to end: the returned render closure reflects NEW logic while state is preserved", function()
    -- This is the fixture that actually matters for a user: state 12,
    -- edit the click handler from +1 to +2, refresh, click once more ->
    -- 14, not 13 and not reset to the initializer.
    local reg = refresh.RefreshRegistry.new()

    local function make_counter_v1(initial)
      reg:begin_generation()
      local count = reg:signal(initial, d("count"))
      reg:finish_generation()
      return {
        get = count.get,
        click = function() count.set(count.get() + 1) end,
      }
    end

    local function make_counter_v2(initial)
      -- "Edited" version: +2 instead of +1. Rerunning setup, not
      -- swapping only a render closure, is exactly why this new
      -- behavior is guaranteed to be the one that runs -- see
      -- docs/HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md's Part 3.
      reg:begin_generation()
      local count = reg:signal(initial, d("count"))
      reg:finish_generation()
      return {
        get = count.get,
        click = function() count.set(count.get() + 2) end,
      }
    end

    local counter_v1 = make_counter_v1(10)
    counter_v1.click()
    counter_v1.click()
    assert.equal(counter_v1.get(), 12)

    -- "Refresh": rerun the (now-edited) setup function against the same
    -- registry. In a real integration this would happen inside the same
    -- component instance; this spec proves the registry mechanics
    -- directly, which is what step 4 (HYDRONIUM_SCHEDULER_HMR_FOUNDATION.md's
    -- "future, real, verifiable work") would wire into a component.
    local counter_v2 = make_counter_v2(10)
    assert.equal(counter_v2.get(), 12, "refresh must preserve the existing count, ignoring the new call's initializer")
    counter_v2.click()
    assert.equal(counter_v2.get(), 14, "the NEW (+2) logic must be what actually runs after refresh, not the old +1")
  end)
end)
