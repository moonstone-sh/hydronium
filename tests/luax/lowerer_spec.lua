-- Lowerer Test Suite for Hydronium LUAX
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local lowerer = require("hydronium.luax.lowerer")

describe("LUAX: Lowering & Code Generation", function()

  describe("Production vs Development Mode (__source injection)", function()
    it("omits __source metadata in production mode (default)", function()
      local src = 'local btn = <button class="primary">Submit</button>'
      local res = lowerer.lower(src, { development = false })

      assert.is_string(res.code)
      assert.falsy(res.code:find("__source", 1, true))
      assert.truthy(res.code:find('class = "primary"', 1, true))
    end)

    it("injects __source metadata with file, line, and col in development mode", function()
      local src = 'local btn = <button class="primary">Submit</button>'
      local res = lowerer.lower(src, { development = true, filename = "Button.luax" })

      assert.truthy(res.code:find("__source", 1, true))
      assert.truthy(res.code:find('file = "Button.luax"', 1, true))
      assert.truthy(res.code:find("line = 1", 1, true))
    end)
  end)

  describe("Spread Operator Lowering and Merging", function()
    it("lowers static props before and after spread in strict left-to-right order", function()
      local src = '<div id="box1" {...props} class="highlight" {...extra} />'
      local res = lowerer.lower(src)

      assert.truthy(res.code:find("__luax.spread", 1, true))
      local pos_spread = res.code:find("__luax.spread", 1, true)
      local pos_id = res.code:find('id = "box1"', 1, true)
      local pos_props = res.code:find("props", pos_id, true)
      local pos_class = res.code:find('class = "highlight"', pos_props, true)
      local pos_extra = res.code:find("extra", pos_class, true)

      assert.truthy(pos_spread < pos_id)
      assert.truthy(pos_id < pos_props)
      assert.truthy(pos_props < pos_class)
      assert.truthy(pos_class < pos_extra)
    end)

    it("emits clean table literals without spread helper when no spreads exist", function()
      local src = '<span id="label" class="badge">Text</span>'
      local res = lowerer.lower(src)

      assert.falsy(res.code:find("__luax.spread", 1, true))
      assert.truthy(res.code:find('id = "label"', 1, true))
      assert.truthy(res.code:find('class = "badge"', 1, true))
    end)
  end)

  describe("Function Callbacks and Expressions", function()
    it("lowers function callbacks cleanly and preserves closures", function()
      local src = [[
        local clicked = false
        local el = <button onClick={function(e)
          clicked = true
          return "handled:" .. tostring(e)
        end}>
          Click Me
        </button>
        return el, function() return clicked end
      ]]
      local res = lowerer.lower(src, { runtime = "hydronium" })

      assert.truthy(res.code:find("onClick = function", 1, true))

      -- Test that lowered code is syntactically valid Lua
      local H = require("hydronium")
      local env = { H = H, __luax = require("hydronium.luax.runtime"), tostring = tostring }
      setmetatable(env, { __index = _G })
      local chunk, err = load(res.code, "test.lua", "t", env)
      assert.truthy(chunk, "Compilation error in lowered code: " .. tostring(err))

      local el, get_clicked = chunk()
      assert.truthy(el)
      assert.equal(el.tag, "button")
      local cb_res = el.props.onClick("event_obj")
      assert.equal(cb_res, "handled:event_obj")
      assert.truthy(get_clicked())
    end)
  end)

  describe("Component and Dotted Path Lowering", function()
    it("lowers functional components to direct identifier references without quotes", function()
      local src = "local view = <ProfileCard user='Alice' />"
      local res = lowerer.lower(src)

      assert.truthy(res.code:find("ProfileCard,", 1, true))
      assert.falsy(res.code:find('"ProfileCard"', 1, true))
    end)

    it("lowers dotted component paths to member expressions", function()
      local src = "local item = <UI.Layout.Grid.Item span={6} />"
      local res = lowerer.lower(src)

      assert.truthy(res.code:find("UI.Layout.Grid.Item", 1, true))
    end)
  end)

  describe("Fragment Lowering", function()
    it("lowers fragments to runtime fragment calls", function()
      local src = "local f = <> <span>1</span> <span>2</span> </>"
      local res = lowerer.lower(src, { runtime = "hydronium" })

      assert.truthy(res.code:find("Fragment", 1, true))
    end)
  end)

end)
