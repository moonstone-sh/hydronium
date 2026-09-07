--[[
  Hydronium HMR Generalization: ComponentFamily + family_loader

  Proves the mission's mandatory item 34 (two mounted instances of the
  same automatically-discovered component family independently preserve
  state across a real module reload) natively, before the much slower
  WASM/browser proof -- exactly the same "prove it in LuaJIT first"
  discipline tests/core/refresh_component_spec.lua and
  src/hydronium/interpreter/lua.lua's hydrate_counter_island_refreshable
  already established for the single-instance case.

  Deliberately NO hand-wired RefreshRegistry, no manual "register this
  component" call, and no hand-picked source list: `Counter` is
  discovered purely by `require("scratch.family_hmr_counter")`, the
  same call site any real component author would write. `package.preload`
  stands in for a real file on disk (avoiding filesystem I/O in a native
  unit test) but the require() call itself, family_loader's require-hook,
  and the reload() path are the real, real, mechanisms -- not mocked.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local H = require("hydronium")
local ComponentInstance = require("hydronium.core.component").ComponentInstance
local family = require("hydronium.core.family")
local familyLoader = require("hydronium.core.family_loader")

describe("HMR generalization: ComponentFamily + family_loader (no hand-wiring)", function()
  it("two mounted instances of an automatically-discovered family independently preserve state across a real module reload", function()
    family.reset()
    familyLoader.reset()
    familyLoader.enable()

    local click_increment = 1
    package.preload["scratch.family_hmr_counter"] = function()
      local increment = click_increment -- captured fresh each (re)require, standing in for "the developer edited this value and saved"
      local function Counter(props, scope)
        local count, setCount = scope.refresh_registry:signal(
          props.initial or 0,
          { kind = "signal", name = "count", block_path = "Counter.setup" }
        )
        return function()
          return H.h("button", {
            onClick = function() setCount(count() + increment) end,
          }, "Count: " .. tostring(count()))
        end
      end
      return Counter
    end

    -- The real call site: no registration, no descriptor list, just a
    -- normal require().
    local Counter = require("scratch.family_hmr_counter")

    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)

    local instanceA = ComponentInstance.new(H.h(Counter, { initial = 10 }), nil, host)
    instanceA:mount(nil, nil, reconciler)
    local instanceB = ComponentInstance.new(H.h(Counter, { initial = 100 }), nil, host)
    instanceB:mount(nil, nil, reconciler)

    assert.truthy(instanceA.family, "instance A must be auto-discovered into a family (no hand registration occurred)")
    assert.truthy(instanceB.family, "instance B must be auto-discovered into a family")
    assert.equal(instanceA.family, instanceB.family, "both instances of the same required export must share exactly one family")
    assert.equal(instanceA.family.id, "scratch.family_hmr_counter::default")

    -- Drive each instance's own state independently via its own render
    -- output's real onClick closure -- not a shared registry, not a
    -- fake DOM event.
    local vA1 = instanceA:render()
    vA1.props.onClick() -- 10 -> 11
    vA1.props.onClick() -- 11 -> 12
    local vB1 = instanceB:render()
    vB1.props.onClick() -- 100 -> 101

    assert.equal(instanceA:render().props.children[1].text, "Count: 12")
    assert.equal(instanceB:render().props.children[1].text, "Count: 101")

    -- Simulate an edit: the click handler's logic changes from +1 to
    -- +2, then the module is reloaded -- the same family_loader.reload()
    -- a real dev-transport "reload" event drives.
    click_increment = 2
    local results = familyLoader.reload("scratch.family_hmr_counter")

    assert.truthy(results["scratch.family_hmr_counter::default"], "reload() must report an update for the family it touched")
    assert.equal(results["scratch.family_hmr_counter::default"].refreshed, 2, "both live instances must have been refreshed")
    assert.equal(results["scratch.family_hmr_counter::default"].failed, 0)
    assert.equal(instanceA.family.generation, 1)

    -- State preserved, independently, immediately after the refresh.
    assert.equal(instanceA:render().props.children[1].text, "Count: 12", "instance A's state must survive the refresh")
    assert.equal(instanceB:render().props.children[1].text, "Count: 101", "instance B's state must survive the refresh, independently of A")

    -- The NEW (+2) logic is what genuinely executes next, in both --
    -- not the old +1, and not a stale closure from before the refresh.
    local vA2 = instanceA:render()
    vA2.props.onClick() -- 12 -> 14
    local vB2 = instanceB:render()
    vB2.props.onClick() -- 101 -> 103

    assert.equal(instanceA:render().props.children[1].text, "Count: 14", "instance A must use the new +2 logic")
    assert.equal(instanceB:render().props.children[1].text, "Count: 103", "instance B must use the new +2 logic, independently of A")

    -- Unmount cleanliness: no stale instance references left in the family.
    instanceA:unmount(reconciler)
    assert.equal(instanceA.family, nil, "unmount must clear the instance's own family reference")
    local remaining = family.get("scratch.family_hmr_counter::default")
    assert.equal(remaining.instance_count, 1, "unmounting one instance must not affect the other's registration")
    instanceB:unmount(reconciler)
    assert.equal(remaining.instance_count, 0)

    package.preload["scratch.family_hmr_counter"] = nil
    package.loaded["scratch.family_hmr_counter"] = nil
    familyLoader.reset()
    family.reset()
  end)

  it("a component never required through family_loader (no .enable() called) gets no family and is unaffected", function()
    familyLoader.reset() -- ensure NOT enabled for this test
    family.reset()

    local function PlainCounter(props, scope)
      return function()
        return H.h("div", nil, "plain")
      end
    end

    local host = H.test.createTestHost()
    local reconciler = H.Reconciler.new(host)
    local instance = ComponentInstance.new(H.h(PlainCounter, {}), nil, host)
    instance:mount(nil, nil, reconciler)

    assert.equal(instance.family, nil, "with family_loader never enabled, no instance should ever acquire a family")
    -- A real, plain begin/finish_generation cycle on an empty registry
    -- must still be harmless -- every existing component, HMR-aware or
    -- not, goes through this same render() path.
    assert.equal(instance:render().props.children[1].text, "plain")

    instance:unmount(reconciler)
  end)
end)
