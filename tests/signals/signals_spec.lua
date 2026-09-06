local h = require("tests.runner")
local signals = require("hydronium.signals")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Signals & Fine-Grained Reactivity", function()

  describe("Signal get/set", function()
    it("initializes with provided value", function()
      local s = signals.signal(10)
      assert.equal(s:get(), 10)
      assert.equal(s(), 10)
    end)

    it("updates value via :set and callable", function()
      local s, set_s = signals.signal("initial")
      s:set("updated")
      assert.equal(s:get(), "updated")

      s("via_call")
      assert.equal(s(), "via_call")

      set_s("via_setter")
      assert.equal(s(), "via_setter")
    end)

    it("supports functional updates", function()
      local count = signals.signal(5)
      count:set(function(prev) return prev * 2 end)
      assert.equal(count:get(), 10)

      count:set(function(prev) return prev + 3 end)
      assert.equal(count:get(), 13)
    end)

    it("supports tuple unpacking", function()
      local get_val, set_val = signals.signal("hello")
      assert.equal(get_val(), "hello")
      set_val("world")
      assert.equal(get_val(), "world")
    end)
  end)

  describe("Equality bypass", function()
    it("skips downstream updates by default when setting identical primitive value", function()
      local s = signals.signal(1)
      local run_count = 0
      signals.effect(function()
        s:get()
        run_count = run_count + 1
      end)
      assert.equal(run_count, 1)

      s:set(1) -- same value
      assert.equal(run_count, 1) -- effect should NOT have re-run
    end)

    it("bypasses equality check when options.equals = false", function()
      local s = signals.signal(1, { equals = false })
      local run_count = 0
      signals.effect(function()
        s:get()
        run_count = run_count + 1
      end)
      assert.equal(run_count, 1)

      s:set(1) -- same value, but equals = false
      assert.equal(run_count, 2) -- effect MUST re-run
    end)

    it("supports custom equality comparator", function()
      local s = signals.signal({ x = 1, y = 2 }, {
        equals = function(a, b)
          return a.x == b.x and a.y == b.y
        end
      })
      local run_count = 0
      signals.effect(function()
        s:get()
        run_count = run_count + 1
      end)
      assert.equal(run_count, 1)

      -- Different table reference, but same x, y
      s:set({ x = 1, y = 2 })
      assert.equal(run_count, 1)

      -- Different x
      s:set({ x = 2, y = 2 })
      assert.equal(run_count, 2)
    end)
  end)

  describe("Computed memoization", function()
    it("memoizes result and only evaluates on read when dirty", function()
      local a = signals.signal(2)
      local b = signals.signal(3)
      local eval_count = 0

      local sum = signals.computed(function()
        eval_count = eval_count + 1
        return a:get() + b:get()
      end)

      -- Not evaluated yet
      assert.equal(eval_count, 0)

      -- First read
      assert.equal(sum:get(), 5)
      assert.equal(eval_count, 1)

      -- Second read without dependency changes -> memoized
      assert.equal(sum:get(), 5)
      assert.equal(eval_count, 1)

      -- Update dependency
      a:set(10)
      -- Computed is marked dirty, but not re-evaluated until read
      assert.equal(eval_count, 1)

      -- Third read -> re-evaluates
      assert.equal(sum:get(), 13)
      assert.equal(eval_count, 2)
    end)

    it("supports chained computed values", function()
      local base = signals.signal(2)
      local doubled = signals.computed(function() return base:get() * 2 end)
      local quadrupled = signals.computed(function() return doubled:get() * 2 end)

      assert.equal(quadrupled:get(), 8)
      base:set(5)
      assert.equal(quadrupled:get(), 20)
    end)
  end)

  describe("Dynamic dependency tracking and pruning", function()
    it("prunes stale dependencies on conditional branches", function()
      local cond = signals.signal(true)
      local left = signals.signal("left_val")
      local right = signals.signal("right_val")
      local eval_count = 0

      local branch = signals.computed(function()
        eval_count = eval_count + 1
        if cond:get() then
          return left:get()
        else
          return right:get()
        end
      end)

      assert.equal(branch:get(), "left_val")
      assert.equal(eval_count, 1)

      -- Modifying right should NOT trigger re-evaluation since branch was left
      right:set("right_mod1")
      assert.equal(branch:get(), "left_val")
      assert.equal(eval_count, 1)

      -- Switch branch to right
      cond:set(false)
      assert.equal(branch:get(), "right_mod1")
      assert.equal(eval_count, 2)

      -- Now left is STALE! Modifying left must NOT trigger re-evaluation of branch
      left:set("left_mod2")
      assert.equal(branch:get(), "right_mod1")
      assert.equal(eval_count, 2)

      -- Modifying right DOES trigger re-evaluation
      right:set("right_mod2")
      assert.equal(branch:get(), "right_mod2")
      assert.equal(eval_count, 3)
    end)
  end)

  describe("Effect execution & cleanup", function()
    it("runs immediately on creation", function()
      local ran = false
      signals.effect(function()
        ran = true
      end)
      assert.truthy(ran)
    end)

    it("executes cleanup before rerun and on dispose", function()
      local count = signals.signal(1)
      local cleanups = {}
      local runs = {}

      local handle = signals.effect(function()
        local current = count:get()
        table.insert(runs, current)
        return function()
          table.insert(cleanups, current)
        end
      end)

      assert.same(runs, { 1 })
      assert.same(cleanups, {})

      -- Rerun effect via signal update
      count:set(2)
      assert.same(runs, { 1, 2 })
      assert.same(cleanups, { 1 }) -- cleanup for run 1 executed before run 2

      count:set(3)
      assert.same(runs, { 1, 2, 3 })
      assert.same(cleanups, { 1, 2 })

      -- Dispose effect
      handle:dispose()
      assert.same(cleanups, { 1, 2, 3 }) -- cleanup for run 3 executed on dispose

      -- After disposal, further updates do not trigger effect
      count:set(4)
      assert.same(runs, { 1, 2, 3 })
      assert.same(cleanups, { 1, 2, 3 })
    end)
  end)

  describe("Transactional nested batching", function()
    it("defers effect notifications until outermost batch completes", function()
      local a = signals.signal(1)
      local b = signals.signal(10)
      local effect_runs = 0

      signals.effect(function()
        a:get()
        b:get()
        effect_runs = effect_runs + 1
      end)
      assert.equal(effect_runs, 1)

      signals.batch(function()
        a:set(2)
        b:set(20)
        -- Inside batch: effect has not run yet
        assert.equal(effect_runs, 1)
      end)

      -- Outermost batch ended: effect runs exactly once
      assert.equal(effect_runs, 2)
    end)

    it("handles deeply nested batches", function()
      local a = signals.signal(1)
      local runs = 0
      signals.effect(function()
        a:get()
        runs = runs + 1
      end)
      assert.equal(runs, 1)

      signals.batch(function()
        signals.batch(function()
          signals.batch(function()
            a:set(100)
          end)
          assert.equal(runs, 1)
        end)
        assert.equal(runs, 1)
      end)

      assert.equal(runs, 2)
    end)

    it("restores batch depth transactionally on error", function()
      local a = signals.signal(1)
      local runs = 0
      signals.effect(function()
        a:get()
        runs = runs + 1
      end)

      assert.has_error(function()
        signals.batch(function()
          a:set(5)
          error("Simulated batch failure")
        end)
      end, "Simulated batch failure")

      -- Subsequent writes outside batch must still work normally (batch depth not stuck)
      a:set(6)
      assert.equal(runs, 2)
    end)
  end)

  describe("Untrack", function()
    it("prevents dependency subscription during execution", function()
      local tracked = signals.signal(1)
      local untracked = signals.signal(100)
      local runs = 0

      signals.effect(function()
        tracked:get()
        signals.untrack(function()
          untracked:get()
        end)
        runs = runs + 1
      end)
      assert.equal(runs, 1)

      -- Changing untracked should NOT trigger effect
      untracked:set(200)
      assert.equal(runs, 1)

      -- Changing tracked SHOULD trigger effect
      tracked:set(2)
      assert.equal(runs, 2)
    end)
  end)

  describe("Cycle detection", function()
    it("detects infinite reactive update loop and throws error", function()
      assert.has_error(function()
        local a = signals.signal(1)
        signals.effect(function()
          local val = a:get()
          a:set(val + 1) -- Immediate re-trigger inside effect
        end)
      end, "Cycle detected")
    end)
  end)

end)
