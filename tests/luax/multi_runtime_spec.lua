-- Multi-Runtime Test Suite for Hydronium LUAX
-- Verifies compiling identical .luax source against Hydronium AND Starship UI runtimes
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local luax = require("hydronium_luax")
local H = require("hydronium")
local Starship = require("tests.fixtures.fixture_runtime")

describe("LUAX: Multi-Runtime Compilation (Zero Coupling)", function()

  local sample_source
  do
    local f = io.open("tests/fixtures/sample_component.luax", "r")
    assert.truthy(f, "Failed to open sample_component.luax")
    sample_source = f:read("*a")
    f:close()
  end

  describe("Compiling Identical Component to Hydronium", function()
    it("compiles and mounts ProfileCard in Hydronium TestHost", function()
      local res = luax.compile(sample_source, {
        filename = "sample_component.luax",
        runtime = "hydronium",
      })

      assert.is_string(res.code)
      assert.truthy(res.code:find("H.h", 1, true))

      -- Execute chunk to get ProfileCard component function
      local env = {
        H = H,
        __luax = require("hydronium_luax.runtime"),
        tostring = tostring,
        pairs = pairs,
        type = type,
        select = select,
      }
      setmetatable(env, { __index = _G })

      local chunk, err = load(res.code, "sample.lua", "t", env)
      assert.truthy(chunk, "Chunk compilation failed: " .. tostring(err))

      local ProfileCard = chunk()
      assert.is_function(ProfileCard)

      -- Create VNode
      local props = {
        id = "card-1",
        username = "Commander Shepard",
        online = true,
        bio = "Spectre & Starship Commander",
        avatarUrl = "https://example.com/shepard.png",
        extraAttrs = { ["data-ship"] = "Normandy" },
      }

      local vnode = ProfileCard(props)
      assert.is_table(vnode)
      assert.equal(vnode.tag, "div")

      -- Render into Hydronium TestRoot
      local root = H.create_test_root()
      root:render(vnode)

      local root_text = root:text()
      assert.truthy(root_text:find("Commander Shepard", 1, true))
      assert.truthy(root_text:find("Online", 1, true))
      assert.truthy(root_text:find("Spectre & Starship Commander", 1, true))
      assert.truthy(root_text:find("Send Message", 1, true))

      -- Query elements
      local btn = root:find({ class = "btn-primary" })
      assert.truthy(btn)
      assert.equal(btn.props.type, "button")

      root:unmount()
    end)
  end)

  describe("Compiling Identical Component to Starship UI", function()
    it("compiles and renders ProfileCard in Starship UI with zero Hydronium coupling", function()
      local res = luax.compile(sample_source, {
        filename = "sample_component.luax",
        runtime = "starship",
      })

      assert.is_string(res.code)
      assert.truthy(res.code:find("Starship.createElement", 1, true))
      assert.falsy(res.code:find("H.h", 1, true))

      -- Execute chunk in Starship environment (no Hydronium required)
      local env = {
        Starship = Starship,
        __luax = require("hydronium_luax.runtime"),
        tostring = tostring,
        pairs = pairs,
        type = type,
        select = select,
      }
      -- Notice: env does NOT contain H! Zero Hydronium references!

      local chunk, err = load(res.code, "sample_starship.lua", "t", env)
      assert.truthy(chunk, "Starship chunk compilation failed: " .. tostring(err))

      local ProfileCard = chunk()
      assert.is_function(ProfileCard)

      local props = {
        id = "card-2",
        username = "Liara T'Soni",
        online = false,
        bio = "Prothean Archaeologist",
        avatarUrl = "https://example.com/liara.png",
        extraAttrs = { ["data-race"] = "Asari" },
      }

      local vnode = ProfileCard(props)
      assert.is_table(vnode)
      assert.truthy(vnode._isStarshipNode)
      assert.equal(vnode.tag, "div")

      -- Render to string using Starship UI's string renderer
      local html = Starship.renderToString(vnode)
      assert.is_string(html)
      assert.truthy(html:find("Liara T'Soni", 1, true))
      assert.truthy(html:find("Offline", 1, true))
      assert.truthy(html:find("Prothean Archaeologist", 1, true))
      assert.truthy(html:find('class="profile-card"', 1, true))
      assert.truthy(html:find('data-race="Asari"', 1, true))
      assert.truthy(html:find('disabled', 1, true))
    end)
  end)

  describe("Cross-Runtime Contract Validation", function()
    it("produces equivalent logical element trees across runtimes", function()
      local src = [[
        return <div class="widget" id="w1">
          <h3>Title</h3>
          <p>Description text</p>
        </div>
      ]]

      local hydro_code = luax.compile(src, { runtime = "hydronium" }).code
      local star_code = luax.compile(src, { runtime = "starship" }).code

      -- Run Hydronium
      local fn_h = load(hydro_code, "h.lua", "t", { H = H })()
      assert.equal(fn_h.tag, "div")
      assert.equal(fn_h.props.id, "w1")
      assert.equal(#fn_h.children, 2)

      -- Run Starship
      local fn_s = load(star_code, "s.lua", "t", { Starship = Starship })()
      assert.equal(fn_s.tag, "div")
      assert.equal(fn_s.props.id, "w1")
      assert.equal(#fn_s.children, 2)
      assert.truthy(fn_s._isStarshipNode)
    end)
  end)

end)
