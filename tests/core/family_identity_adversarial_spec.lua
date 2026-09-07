--[[
  Counter-agent audit Part VI item 18: adversarial edits against
  FamilyID (require() module_id + export key). Distinguishes, for each
  edit kind, whether identity PRESERVES, RESETS SAFELY, or (the one
  outcome that must never happen) MISIDENTIFIES -- silently transfers
  state to an unrelated family.

  FamilyID today is exactly two strings: the require() module id (the
  literal path a real call site passes) and the export key
  (`scan_exports`'s "::default" for a bare function, "::<name>" for a
  table export). Every edit below is judged purely against that
  definition -- no compiler metadata is involved (see
  docs/HMR_COMPONENT_FAMILIES.md's "What this does NOT do").
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local ComponentInstance = require("hydronium.core.component").ComponentInstance
local family = require("hydronium.core.family")
local familyLoader = require("hydronium.core.family_loader")

describe("FamilyID under adversarial source edits (counter-agent audit Part VI)", function()
  it("PRESERVES identity across comments, reformatting, unrelated code, local-variable rename, and declaration reorder -- since none of that touches module_id or export shape", function()
    family.reset()
    familyLoader.reset()
    familyLoader.enable()

    package.preload["scratch.adversarial.counter"] = function()
      -- Deliberately messy: comments, an unrelated local, and the
      -- exported function declared AFTER other declarations -- exactly
      -- the kind of edit family identity must not be sensitive to.
      local _unused_helper = function() return 42 end -- unrelated code, present from the start
      local function Counter(props, scope)
        local count, setCount = scope.refresh_registry:signal(props.initial or 0, {
          kind = "signal", name = "count", block_path = "Counter.setup",
        })
        return function()
          return H.h("button", { onClick = function() setCount(count() + 1) end }, "Count: " .. tostring(count()))
        end
      end
      return Counter
    end

    local Counter = require("scratch.adversarial.counter")
    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)
    local instance = ComponentInstance.new(H.h(Counter, { initial = 5 }), nil, host)
    instance:mount(nil, nil, reconciler)
    instance:render().props.onClick() -- 5 -> 6

    local familyBefore = instance.family
    assert.equal(familyBefore.id, "scratch.adversarial.counter::default")

    -- The "edit": add a leading comment block, reformat, rename the
    -- unrelated local, reorder it after the exported function, and
    -- rename the component's own local variable -- module_id and
    -- export shape (a bare function return) are UNCHANGED.
    package.preload["scratch.adversarial.counter"] = function()
      --[[ freshly added header comment, and totally reformatted below ]]
      local function MyRenamedLocalCounter(props, scope)
        local count, setCount = scope.refresh_registry:signal(
          props.initial or 0, { kind = "signal", name = "count", block_path = "Counter.setup" })
        return function() return H.h("button", { onClick = function() setCount(count() + 1) end },
          "Count: " .. tostring(count())) end
      end
      local _now_declared_after = function() return 42 end
      return MyRenamedLocalCounter
    end

    local results = familyLoader.reload("scratch.adversarial.counter")
    local report = results["scratch.adversarial.counter::default"]
    assert.truthy(report, "the same family id must still receive the update -- identity PRESERVED")
    assert.equal(report.refreshed, 1)
    assert.equal(instance.family, familyBefore, "the Family OBJECT itself must be the same one, not a new family replacing it")
    assert.equal(instance:render().props.children[1].text, "Count: 6", "state must survive -- this is a preserving edit, not a reset")

    instance:unmount(reconciler)
    package.preload["scratch.adversarial.counter"] = nil
    package.loaded["scratch.adversarial.counter"] = nil
    familyLoader.reset()
    family.reset()
  end)

  it("RESETS SAFELY (never misidentifies) when a table-export component is renamed to a different key", function()
    family.reset()
    familyLoader.reset()
    familyLoader.enable()

    package.preload["scratch.adversarial.table_mod"] = function()
      local function Counter(props, scope)
        return function() return H.h("div", nil, "counter") end
      end
      local function Widget(props, scope)
        return function() return H.h("div", nil, "widget") end
      end
      return { Counter = Counter, Widget = Widget }
    end

    local mod = require("scratch.adversarial.table_mod")
    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)
    local instance = ComponentInstance.new(H.h(mod.Counter, {}), nil, host)
    instance:mount(nil, nil, reconciler)

    assert.equal(instance.family.id, "scratch.adversarial.table_mod::Counter")
    local oldFamily = instance.family

    -- The "rename": Counter -> RenamedCounter. A real, common refactor.
    package.preload["scratch.adversarial.table_mod"] = function()
      local function RenamedCounter(props, scope)
        return function() return H.h("div", nil, "counter") end
      end
      local function Widget(props, scope)
        return function() return H.h("div", nil, "widget") end
      end
      return { RenamedCounter = RenamedCounter, Widget = Widget }
    end

    local results = familyLoader.reload("scratch.adversarial.table_mod")

    -- MUST NOT MISIDENTIFY: no family named "...::Counter" received
    -- an update using RenamedCounter's body, and the live instance's
    -- own family reference is untouched -- it simply stops receiving
    -- future updates (a safe, inert reset), rather than silently
    -- being reassigned someone else's definition/state.
    assert.equal(instance.family, oldFamily, "the live instance's family reference must be UNCHANGED by an unrelated rename")
    assert.falsy(results["scratch.adversarial.table_mod::Counter"], "the old key must not receive a phantom update")
    assert.truthy(results["scratch.adversarial.table_mod::RenamedCounter"], "the new key gets its own, separate, empty family (zero instances -- nobody re-required it under the new key)")
    assert.equal(results["scratch.adversarial.table_mod::RenamedCounter"].refreshed, 0, "a fresh family with no live instances refreshes zero -- not an error, just inert")
    assert.equal(instance:render().props.children[1].text, "counter", "the live instance keeps working, unaffected -- a safe reset, not a corruption")

    instance:unmount(reconciler)
    package.preload["scratch.adversarial.table_mod"] = nil
    package.loaded["scratch.adversarial.table_mod"] = nil
    familyLoader.reset()
    family.reset()
  end)

  it("RESETS SAFELY (never transfers state) when a component module is moved to a different require() path", function()
    family.reset()
    familyLoader.reset()
    familyLoader.enable()

    local function makeCounterModule()
      return function()
        local function Counter(props, scope)
          local count, setCount = scope.refresh_registry:signal(props.initial or 0, {
            kind = "signal", name = "count", block_path = "Counter.setup",
          })
          return function()
            return H.h("button", { onClick = function() setCount(count() + 1) end }, "Count: " .. tostring(count()))
          end
        end
        return Counter
      end
    end

    package.preload["scratch.adversarial.old_path.counter"] = makeCounterModule()
    local OldCounter = require("scratch.adversarial.old_path.counter")
    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)
    local instance = ComponentInstance.new(H.h(OldCounter, { initial = 9 }), nil, host)
    instance:mount(nil, nil, reconciler)
    instance:render().props.onClick() -- 9 -> 10

    assert.equal(instance.family.id, "scratch.adversarial.old_path.counter::default")

    -- The "move": identical file content, required from a new path --
    -- exactly what moving the file on disk (with call sites updated to
    -- match) produces.
    package.preload["scratch.adversarial.new_path.counter"] = makeCounterModule()
    local NewCounter = require("scratch.adversarial.new_path.counter")

    assert.truthy(familyLoader.lookup(NewCounter), "the module at the new path must still be discovered")
    assert.equal(familyLoader.lookup(NewCounter).id, "scratch.adversarial.new_path.counter::default")
    assert.truthy(familyLoader.lookup(NewCounter) ~= instance.family, "moving to a new path MUST create a distinct family -- never silently reuse the old one's identity")

    -- The OLD instance is completely unaffected -- no state was
    -- transferred to or from the new path's family (which, having zero
    -- instances, cannot even receive a meaningful refresh yet).
    assert.equal(instance:render().props.children[1].text, "Count: 10")

    instance:unmount(reconciler)
    package.preload["scratch.adversarial.old_path.counter"] = nil
    package.preload["scratch.adversarial.new_path.counter"] = nil
    package.loaded["scratch.adversarial.old_path.counter"] = nil
    package.loaded["scratch.adversarial.new_path.counter"] = nil
    familyLoader.reset()
    family.reset()
  end)
end)
