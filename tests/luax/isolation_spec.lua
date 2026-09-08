--[[
  Hydronium LUAX Host Environment Isolation Matrix Test Suite
  Validates 4-Quadrant Isolation Matrix:
  - Quadrant 1: DOM Active (DOM schema registered, intrinsics available, zero global leakage)
  - Quadrant 2: DOM Inactive / Universal (reset to universal schema, zero DOM pollution)
  - Quadrant 3: Starship Active (Starship runtime compilation, zero Hydronium coupling)
  - Quadrant 4: Starship without DOM (independent Starship schema, clean global namespace _G)
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local luax = require("hydronium_luax")
local environment = require("hydronium_luax.environment")
local Starship = require("tests.fixtures.fixture_runtime")
local H = require("hydronium")

local loadstring = loadstring or load

describe("LUAX: 4-Quadrant Host Environment Isolation Matrix", function()

  -- Snapshot _G keys prior to running tests
  local baseline_globals = {}
  for k in pairs(_G) do
    baseline_globals[k] = true
  end

  local function assert_no_new_globals(exemptions)
    exemptions = exemptions or {}
    for k in pairs(_G) do
      if not baseline_globals[k] and not exemptions[k] then
        assert.fail("Detected global namespace pollution: _G[" .. tostring(k) .. "]")
      end
    end
  end

  -- =========================================================================
  -- Quadrant 1: DOM Active
  -- =========================================================================
  describe("Quadrant 1: DOM Active", function()
    local dom_env

    it("registers and activates DOM environment schema", function()
      dom_env = environment.define({
        name = "dom",
        factory = "H.h",
        fragment = "H.Fragment",
        spread = "__luax.spread",
        intrinsics = {
          button = true,
          div = true,
          span = true,
          input = true,
          form = true,
          p = true,
          h1 = true,
        },
      })

      environment.set_current("dom")
      assert.equal(environment.get_current().name, "dom")
      assert.truthy(dom_env:is_intrinsic("button"))
      assert.truthy(dom_env:is_intrinsic("div"))
      assert.truthy(dom_env:is_intrinsic("input"))
      assert.falsy(dom_env:is_intrinsic("CustomCard"))
    end)

    it("compiles DOM JSX elements into H.h factory calls", function()
      local src = [[
        local function View()
          return <div class="card"><button type="submit">Send</button></div>
        end
        return View
      ]]
      local res = luax.compile(src, { env = dom_env })
      assert.truthy(res.code:find("H%.h%(\"div\""), "Expected H.h(\"div\" in compiled output")
      assert.truthy(res.code:find("H%.h%(\"button\""), "Expected H.h(\"button\" in compiled output")
    end)

    it("executes in isolated environment without polluting _G with DOM elements", function()
      local src = "local function Card() return <div><span>Test</span></div> end; return Card"
      local res = luax.compile(src, { env = dom_env })

      local sandbox_env = {
        H = H,
        __luax = require("hydronium_luax.runtime"),
        pairs = pairs,
        type = type,
        tostring = tostring,
      }
      setmetatable(sandbox_env, { __index = _G })

      local chunk, err = loadstring(res.code, "dom_test", "t", sandbox_env)
      assert.truthy(chunk, "Chunk compilation failed: " .. tostring(err))
      local Card = chunk()
      assert.is_function(Card)

      local vnode = Card()
      assert.equal(vnode.tag, "div")

      -- Assert zero global namespace pollution
      assert.is_nil(_G.button, "_G.button must not be leaked")
      assert.is_nil(_G.div, "_G.div must not be leaked")
      assert.is_nil(_G.span, "_G.span must not be leaked")
      assert.is_nil(_G.input, "_G.input must not be leaked")
      assert.is_nil(_G.document, "_G.document must not exist in standard Lua")
      assert.is_nil(_G.window, "_G.window must not exist in standard Lua")
      assert_no_new_globals()
    end)
  end)

  -- =========================================================================
  -- Quadrant 2: DOM Inactive / Universal Reset
  -- =========================================================================
  describe("Quadrant 2: DOM Inactive (Universal Environment)", function()
    it("resets current environment to universal", function()
      local univ_env = environment.set_current("universal")
      assert.equal(environment.get_current().name, "universal")
      assert.equal(univ_env.factory, "__luax.element")
      assert.equal(univ_env.fragment, "__luax.fragment")
      assert.equal(univ_env.spread, "__luax.spread")
    end)

    it("compiles elements into universal __luax calls with zero DOM bias", function()
      local src = [[
        local function UniversalView()
          return <widget id="w1"><item value={42} /></widget>
        end
        return UniversalView
      ]]
      local res = luax.compile(src)
      assert.truthy(res.code:find("__luax%.element"), "Expected __luax.element in universal output")
      assert.falsy(res.code:find("H%.h"), "Universal output must not reference H.h")
      assert.falsy(res.code:find("Starship"), "Universal output must not reference Starship")
    end)

    it("executes cleanly using universal runtime and keeps _G clean", function()
      local src = "local function Generic(props) return <container label={props.title} /> end; return Generic"
      local res = luax.compile(src)

      local sandbox_env = {
        __luax = require("hydronium_luax.runtime"),
        pairs = pairs,
        type = type,
        tostring = tostring,
      }
      setmetatable(sandbox_env, { __index = _G })

      local chunk, err = loadstring(res.code, "univ_test", "t", sandbox_env)
      assert.truthy(chunk, "Chunk compilation failed: " .. tostring(err))
      local Generic = chunk()
      local node = Generic({ title = "Isolated Node" })

      assert.is_table(node)
      assert.equal(node.tag, "container")
      assert.equal(node.props.label, "Isolated Node")

      assert.is_nil(_G.widget)
      assert.is_nil(_G.container)
      assert.is_nil(_G.item)
      assert_no_new_globals()
    end)
  end)

  -- =========================================================================
  -- Quadrant 3: Starship Active (Runtime Target Decoupling)
  -- =========================================================================
  describe("Quadrant 3: Starship Active", function()
    it("compiles components targeting Starship.createElement with zero Hydronium coupling", function()
      local src = [[
        local function StarshipButton(props)
          return (
            <button id={props.id} onClick={props.onClick}>
              <span>{props.label}</span>
            </button>
          )
        end
        return StarshipButton
      ]]

      local res = luax.compile(src, { runtime = "starship" })
      assert.truthy(res.code:find("Starship%.createElement"), "Expected Starship.createElement")
      assert.falsy(res.code:find("H%.h"), "Starship compilation must not contain any H.h references")
      assert.falsy(res.code:find("Hydronium"), "Starship compilation must not contain Hydronium references")
    end)

    it("executes Starship component in an environment with ZERO Hydronium references", function()
      local src = [[
        local function ShipHUD(props)
          return (
            <hud-panel shields={props.shields} active={props.active}>
              <status-indicator label="Sensors" />
            </hud-panel>
          )
        end
        return ShipHUD
      ]]

      local res = luax.compile(src, { runtime = "starship" })

      -- Sandbox WITHOUT Hydronium (H is completely absent)
      local sandbox_env = {
        Starship = Starship,
        __luax = require("hydronium_luax.runtime"),
        pairs = pairs,
        type = type,
        tostring = tostring,
      }

      local chunk, err = loadstring(res.code, "starship_test", "t", sandbox_env)
      assert.truthy(chunk, "Compilation error: " .. tostring(err))
      local ShipHUD = chunk()

      local vnode = ShipHUD({ shields = 100, active = true })
      assert.is_table(vnode)
      assert.equal(vnode.tag, "hud-panel")
      assert.equal(vnode.props.shields, 100)
      assert.equal(vnode.props.active, true)
      assert.is_table(vnode.children)

      assert.is_nil(_G.Starship, "Starship must not be leaked into _G")
      assert.is_nil(_G["hud-panel"])
      assert_no_new_globals()
    end)

    it("supports inline @jsx Starship.createElement pragma override", function()
      local src = [[
        -- @jsx Starship.createElement
        local function PragmaComp()
          return <dialog title="Alert"><span>Message</span></dialog>
        end
        return PragmaComp
      ]]
      local res = luax.compile(src)
      assert.truthy(res.code:find('Starship.createElement("dialog"', 1, true), "Pragma must direct factory to Starship.createElement")
      assert.falsy(res.code:find("H.h", 1, true))
    end)
  end)

  -- =========================================================================
  -- Quadrant 4: Starship without DOM (Isolated Schema)
  -- =========================================================================
  describe("Quadrant 4: Starship without DOM", function()
    local starship_env

    it("registers independent Starship schema with native UI intrinsics", function()
      starship_env = environment.define({
        name = "starship_native",
        factory = "Starship.createElement",
        fragment = "Starship.createElement(Starship.Fragment",
        spread = "Starship.spread or __luax.spread",
        intrinsics = {
          view = true,
          text = true,
          image = true,
          box = true,
          mesh = true,
          canvas = true,
        },
      })

      environment.set_current("starship_native")
      assert.equal(environment.get_current().name, "starship_native")

      -- Starship native tags are intrinsic
      assert.truthy(starship_env:is_intrinsic("view"))
      assert.truthy(starship_env:is_intrinsic("text"))
      assert.truthy(starship_env:is_intrinsic("mesh"))

      -- DOM tags are NOT intrinsic in Starship schema
      assert.falsy(starship_env:is_intrinsic("div"), "div must not be intrinsic in Starship schema")
      assert.falsy(starship_env:is_intrinsic("p"), "p must not be intrinsic in Starship schema")
      assert.falsy(starship_env:is_intrinsic("span"), "span must not be intrinsic in Starship schema")
    end)

    it("compiles Starship native tags as string tag intrinsics and DOM tags as components", function()
      local src = [[
        local function StarshipScene()
          return (
            <view id="root">
              <text value="Starbase" />
              <div id="unrecognized-dom" />
            </view>
          )
        end
        return StarshipScene
      ]]

      local res = luax.compile(src, { env = starship_env })
      -- view and text are emitted as string literals
      assert.truthy(res.code:find("Starship%.createElement%(\"view\""), "view should be string intrinsic")
      assert.truthy(res.code:find("Starship%.createElement%(\"text\""), "text should be string intrinsic")

      -- div is not in starship_env intrinsics, so it's treated as a custom component identifier
      assert.truthy(res.code:find("Starship%.createElement%(div,"), "div should be component identifier")
    end)

    it("maintains complete global namespace cleanliness throughout all matrix transitions", function()
      -- Reset back to universal
      environment.set_current("universal")
      assert.equal(environment.get_current().name, "universal")

      -- Verify that no host elements ever contaminated Lua's global environment table
      local prohibited_globals = {
        "view", "text", "mesh", "image", "box",
        "div", "button", "span", "input", "form", "p",
        "Starship", "document", "window", "navigator"
      }

      for _, name in ipairs(prohibited_globals) do
        assert.is_nil(_G[name], "Prohibited global found in _G: " .. name)
      end

      assert_no_new_globals()
    end)
  end)
end)
