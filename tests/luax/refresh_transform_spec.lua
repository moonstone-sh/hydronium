--[[
  M1: automatic HMR refresh descriptors (hydronium_luax.transforms.refresh).

  Three things are proven here, in increasing order of what they cost to
  get wrong:

    (a) the rewrite fires for the recognized shape, and emits EXACTLY the
        descriptor `hydronium.core.refresh`'s RefreshRegistry matches on;
    (b) it is a byte-for-byte no-op for everything else -- compared
        against the same compile with the pass switched off, so this is a
        real equality check and not a hand-maintained expected string;
    (c) the REWRITTEN code, run through the real reactive core, produces a
        component whose state actually survives a real
        family_loader.reload() -- with a control run that differs only in
        whether the pass ran, so preservation is attributable to the pass
        and nothing else.

  (c) is the one that matters: (a) only proves the compiler emitted a
  string we liked.
--]]

local runner = require("tests.runner")
local compiler = require("hydronium_luax.compiler")
local refresh_transform = require("hydronium_luax.transforms.refresh")

local H = require("hydronium")
local ComponentInstance = require("hydronium.core.component").ComponentInstance
local family = require("hydronium.core.family")
local familyLoader = require("hydronium.core.family_loader")

--- Compile twice -- pass on, pass off -- and hand back both.
local function both(src, filename)
  local on = compiler.compile(src, { filename = filename or "views/App.luax" })
  local off = compiler.compile(src, { filename = filename or "views/App.luax", refresh_descriptors = false })
  return on, off
end

describe("LUAX HMR refresh-descriptor transform", function()

  ---------------------------------------------------------------- (a)
  describe("rewrites the recognized component-setup shape", function()
    it("rewrites `local x, setX = hydronium.signal(v)` in a named component setup", function()
      local res = compiler.compile([[
local function Counter(props, scope)
  local count, setCount = hydronium.signal(props.initial or 0)
  return function()
    return d.div({}, count)
  end
end
return Counter
]], { filename = "views/App.luax" })

      assert.equal(res.refresh.rewritten, 1)
      assert.truthy(res.code:find("scope%.refresh_registry:signal%(", 1))
      -- The exact descriptor shape RefreshRegistry keys on.
      assert.truthy(res.code:find('kind = "signal"', 1, false))
      assert.truthy(res.code:find('name = "count"', 1, false))
      assert.truthy(res.code:find('block_path = "views%.App::Counter%.setup"'))
      -- The initial-value expression is carried through untouched.
      assert.truthy(res.code:find("props%.initial or 0"))
      -- The original factory call is gone.
      assert.falsy(res.code:find("hydronium%.signal%("))
    end)

    it("recognizes createSignal, <obj>.signal and <obj>.createSignal alike", function()
      for _, call in ipairs({ "createSignal(0)", "hydronium.signal(0)", "signals.createSignal(0)", "H.createSignal(0)" }) do
        local res = compiler.compile(
          "local function C(props, scope)\n" ..
          "  local count, setCount = " .. call .. "\n" ..
          "  return function() return d.div({}) end\n" ..
          "end", { filename = "views/App.luax" })
        assert.equal(res.refresh.rewritten, 1, "expected rewrite for: " .. call)
      end
    end)

    it("identifies an anonymous `return function(props, scope)` setup by index, not by line", function()
      local res = compiler.compile([[
return function(props, scope)
  local count, setCount = createSignal(0)
  return function() return d.div({}, count) end
end
]], { filename = "src/client/counter.luax" })
      assert.equal(res.refresh.rewritten, 1)
      assert.equal(res.refresh.descriptors[1].block_path, "src.client.counter::#1.setup")
    end)

    it("gives two signals in one setup distinct descriptor names", function()
      local res = compiler.compile([[
local function C(props, scope)
  local count, setCount = createSignal(0)
  local label, setLabel = createSignal("x")
  return function() return d.div({}, count, label) end
end
]], { filename = "views/App.luax" })
      assert.equal(res.refresh.rewritten, 2)
      assert.equal(res.refresh.descriptors[1].name, "count")
      assert.equal(res.refresh.descriptors[2].name, "label")
    end)

    it("disambiguates a shadowed binding name so registry keys stay unique", function()
      -- Legal Lua: two `local count, setCount` in one block. Both would
      -- otherwise hash to the same (kind, name, block_path) key and fight
      -- over one slot in the registry.
      local res = compiler.compile([[
local function C(props, scope)
  local count, setCount = createSignal(1)
  local count, setCount = createSignal(2)
  return function() return d.div({}, count) end
end
]], { filename = "views/App.luax" })
      assert.equal(res.refresh.rewritten, 2)
      assert.equal(res.refresh.descriptors[1].name, "count")
      assert.equal(res.refresh.descriptors[2].name, "count#2")
      assert.not_equal(res.refresh.descriptors[1].name, res.refresh.descriptors[2].name)
    end)

    it("keeps block_path stable when unrelated lines are added above the signal", function()
      -- The whole point of a structural (non-positional) block_path: an
      -- edit that shifts line numbers must NOT change identity, or every
      -- save would look like "old signal vanished, new one appeared" and
      -- silently drop state.
      local before = compiler.compile([[
local function Counter(props, scope)
  local count, setCount = createSignal(0)
  return function() return d.div({}, count) end
end
]], { filename = "views/App.luax" })

      local after = compiler.compile([[
-- a new comment
local helper = function() return 1 end
local function Counter(props, scope)
  local unrelated = helper()
  local count, setCount = createSignal(0)
  return function() return d.div({}, count, unrelated) end
end
]], { filename = "views/App.luax" })

      assert.equal(before.refresh.descriptors[1].block_path, after.refresh.descriptors[1].block_path)
      assert.equal(before.refresh.descriptors[1].name, after.refresh.descriptors[1].name)
    end)
  end)

  ---------------------------------------------------------------- (b)
  describe("is a byte-for-byte no-op outside the recognized shape", function()
    -- Each of these must compile IDENTICALLY with the pass on and off.
    local untouched = {
      ["a module-level signal, outside any component"] = [[
local count, setCount = hydronium.signal(0)
return count
]],
      ["a signal inside the returned render function (runs many times)"] = [[
local function C(props, scope)
  return function()
    local count, setCount = hydronium.signal(0)
    return d.div({}, count)
  end
end
]],
      ["a setup function with no `scope` parameter"] = [[
local function C(props)
  local count, setCount = hydronium.signal(0)
  return function() return d.div({}, count) end
end
]],
      ["a function that never returns a render function"] = [[
local function notAComponent(props, scope)
  local count, setCount = hydronium.signal(0)
  return count
end
]],
      ["a conditionally-declared signal nested in an if"] = [[
local function C(props, scope)
  if props.on then
    local count, setCount = hydronium.signal(0)
  end
  return function() return d.div({}) end
end
]],
      ["a signal inside a nested helper closure"] = [[
local function C(props, scope)
  local make = function()
    local count, setCount = hydronium.signal(0)
    return count
  end
  return function() return d.div({}, make()) end
end
]],
      ["a single-name (non-destructured) signal binding"] = [[
local function C(props, scope)
  local only = hydronium.signal(0)
  return function() return d.div({}, only) end
end
]],
      ["a call with the wrong arity"] = [[
local function C(props, scope)
  local count, setCount = hydronium.signal(0, "extra")
  return function() return d.div({}, count) end
end
]],
      ["an unrelated two-value destructure"] = [[
local function C(props, scope)
  local ok, err = pcall(doThing)
  return function() return d.div({}, ok) end
end
]],
      ["ordinary JSX with no signals at all"] = [[
local function C(props)
  return <div class="x"><span>{props.title}</span></div>
end
]],
    }

    for label, src in pairs(untouched) do
      it("leaves " .. label .. " completely unchanged", function()
        local on, off = both(src)
        assert.equal(on.code, off.code, "pass altered code it should not have touched")
        assert.equal(on.refresh.rewritten, 0)
      end)
    end

    it("emits identical code with the pass disabled even where it WOULD rewrite", function()
      -- Confirms `refresh_descriptors = false` is a real, total opt-out.
      local src = [[
local function C(props, scope)
  local count, setCount = createSignal(0)
  return function() return d.div({}, count) end
end
]]
      local on, off = both(src)
      assert.not_equal(on.code, off.code)
      assert.truthy(on.code:find("refresh_registry"))
      assert.falsy(off.code:find("refresh_registry"))
    end)
  end)

  ---------------------------------------------------------------- (c)
  describe("the rewritten code really preserves state across a hot reload", function()
    -- Source shared by both runs; STEP is the "edit" (+1 becomes +5).
    -- `H` and `hydronium` are file-local requires, not globals: this spec
    -- deliberately leaves _G untouched so it cannot perturb
    -- tests/luax/isolation_spec.lua's global-pollution baseline.
    local SRC = [[
local H = require("hydronium")
local hydronium = H
local function Counter(props, scope)
  local count, setCount = hydronium.signal(props.initial or 0)
  return function()
    return H.h("button", { onClick = function() setCount(count() + STEP) end }, "Count: " .. tostring(count()))
  end
end
return Counter
]]

    --- Compile SRC at the given step, load it, and hand back the module.
    local function build(step, module_id, transform_enabled)
      local src = SRC:gsub("STEP", tostring(step))
      local res = compiler.compile(src, {
        filename = module_id:gsub("%.", "/") .. ".luax",
        refresh_descriptors = transform_enabled,
      })
      -- NB: the runner rebinds the global `assert` to its assertion
      -- table, so load errors are surfaced with `error`, not `assert`.
      local chunk, err = (loadstring or load)(res.code, "@" .. module_id)
      if not chunk then error("compiled .luax failed to load: " .. tostring(err), 0) end
      return chunk()
    end

    --- One full mount -> click -> edit -> reload cycle.
    --- @return string before, string afterReload, string afterClick
    local function cycle(module_id, transform_enabled)
      family.reset()
      familyLoader.reset()
      package.loaded[module_id] = nil

      local step = 1
      package.preload[module_id] = function()
        return build(step, module_id, transform_enabled)
      end

      familyLoader.enable()
      local Counter = require(module_id)

      local host = H.test.createTestHost()
      local reconciler = H.Reconciler.new(host)
      local instance = ComponentInstance.new(H.h(Counter, { initial = 0 }), nil, host)
      instance:mount(nil, nil, reconciler)

      for _ = 1, 3 do instance:render().props.onClick() end
      local before = instance:render().children[1].text

      -- The "edit": +1 becomes +5, then a real reload through the real
      -- family loader (re-requires, re-scans exports, refreshes every
      -- live instance via ComponentInstance:refresh()).
      step = 5
      local results = familyLoader.reload(module_id)
      local refreshed = 0
      for _, r in pairs(results) do refreshed = refreshed + (r.refreshed or 0) end

      local afterReload = instance:render().children[1].text
      instance:render().props.onClick()
      local afterClick = instance:render().children[1].text

      familyLoader.reset()
      package.preload[module_id] = nil
      package.loaded[module_id] = nil
      return before, afterReload, afterClick, refreshed
    end

    it("CONTROL: without the pass, an ordinary component loses its state on reload", function()
      local before, afterReload, afterClick, refreshed = cycle("scratch.m1.control", false)
      assert.equal(before, "Count: 3")
      assert.equal(refreshed, 1, "the reload itself must have happened")
      assert.equal(afterReload, "Count: 0", "state should be LOST without a descriptor")
      assert.equal(afterClick, "Count: 5", "new logic should still be live")
    end)

    it("WITH the pass, that same ordinary component keeps its state across the reload", function()
      local before, afterReload, afterClick, refreshed = cycle("scratch.m1.auto", true)
      assert.equal(before, "Count: 3")
      assert.equal(refreshed, 1)
      assert.equal(afterReload, "Count: 3", "state must SURVIVE the reload")
      assert.equal(afterClick, "Count: 8", "and the new +5 logic must be live (3 + 5)")
    end)

    it("preserves state even when the signal's line number moved in the edit", function()
      -- Guards the structural-identity claim end to end, not just in the
      -- emitted string: shifting the declaration down a line must not
      -- break matching.
      local module_id = "scratch.m1.shifted"
      family.reset(); familyLoader.reset()
      package.loaded[module_id] = nil

      local shifted = false
      package.preload[module_id] = function()
        local src = shifted
          and [[
-- a newly added comment line
local H = require("hydronium")
local hydronium = H
local function Counter(props, scope)
  local unrelated = 1
  local count, setCount = hydronium.signal(props.initial or 0)
  return function()
    return H.h("button", { onClick = function() setCount(count() + 5) end }, "Count: " .. tostring(count()))
  end
end
return Counter
]]
          or [[
local H = require("hydronium")
local hydronium = H
local function Counter(props, scope)
  local count, setCount = hydronium.signal(props.initial or 0)
  return function()
    return H.h("button", { onClick = function() setCount(count() + 1) end }, "Count: " .. tostring(count()))
  end
end
return Counter
]]
        local res = compiler.compile(src, { filename = "views/Shifted.luax" })
        local chunk, err = (loadstring or load)(res.code, "@" .. module_id)
        if not chunk then error("compiled .luax failed to load: " .. tostring(err), 0) end
        return chunk()
      end

      familyLoader.enable()
      local Counter = require(module_id)
      local host = H.test.createTestHost()
      local reconciler = H.Reconciler.new(host)
      local instance = ComponentInstance.new(H.h(Counter, { initial = 0 }), nil, host)
      instance:mount(nil, nil, reconciler)
      for _ = 1, 3 do instance:render().props.onClick() end
      assert.equal(instance:render().children[1].text, "Count: 3")

      shifted = true
      familyLoader.reload(module_id)

      assert.equal(instance:render().children[1].text, "Count: 3", "a line shift must not break identity")
      instance:render().props.onClick()
      assert.equal(instance:render().children[1].text, "Count: 8")

      familyLoader.reset()
      package.preload[module_id] = nil
      package.loaded[module_id] = nil
    end)
  end)

  ---------------------------------------------------------- boundary API
  describe("setup-boundary detection", function()
    local parser = require("hydronium_luax.parser")

    local function first_fn(src)
      local root = parser.parse(src, "t.luax")
      return root.body[1]
    end

    it("accepts a (props, scope) function that returns a function", function()
      assert.truthy(refresh_transform.is_component_setup(
        first_fn("local function C(props, scope) return function() return 1 end end")))
    end)

    it("rejects one that returns a non-function", function()
      assert.falsy(refresh_transform.is_component_setup(
        first_fn("local function C(props, scope) return 1 end")))
    end)

    it("rejects one with no `scope` parameter", function()
      assert.falsy(refresh_transform.is_component_setup(
        first_fn("local function C(props) return function() return 1 end end")))
    end)

    it("derives a dotted module id from the source filename", function()
      assert.equal(refresh_transform.module_id_from_filename("views/App.luax"), "views.App")
      assert.equal(refresh_transform.module_id_from_filename("./src/client/counter.luax"), "src.client.counter")
    end)
  end)
end)
