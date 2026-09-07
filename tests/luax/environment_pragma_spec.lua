--[[
  Hydronium LUAX Explicit Bare-Tag Environment Pragma
  Verifies `---@luax environment <alias>` gives bare intrinsic tags an
  explicit per-file lexical source instead of resolving through the
  implicit/ambient default environment.
--]]

local runner = require("tests.runner")
local compiler = require("hydronium.luax.compiler")

describe("LUAX Explicit Bare-Tag Environment Pragma", function()
  describe("with `---@luax environment <alias>` declared", function()
    local src = [[
local t = require("hydronium.terminal")
---@luax environment t

return <box><text>Hello</text></box>
]]

    it("aliases bare intrinsic tags to the declared local in virtual_luals (LuaLS) mode", function()
      local res = compiler.compile(src, { virtual_luals = true })
      assert.truthy(res.code:find("t%.box%("), "Expected bare <box> to alias to t.box")
      assert.truthy(res.code:find("t%.text%("), "Expected bare <text> to alias to t.text")
      assert.falsy(res.code:find("d%.box"), "Should not fall back to the default `d` global when a pragma is present")
    end)

    it("records zero bare_tags_without_alias diagnostics", function()
      local res = compiler.compile(src, { virtual_luals = true })
      assert.equal(0, #res.bare_tags_without_alias)
    end)

    it("aliases bare intrinsic tags in real hydronium runtime emission", function()
      local res = compiler.compile(src, { runtime = "hydronium" })
      assert.truthy(res.code:find("H%.h%(t%.box"), "Expected H.h(t.box, ...) in hydronium runtime output")
      assert.truthy(res.code:find("H%.h%(t%.text"), "Expected H.h(t.text, ...) in hydronium runtime output")
    end)

    it("aliases bare intrinsic tags in direct runtime emission", function()
      local res = compiler.compile(src, { runtime = "direct" })
      assert.truthy(res.code:find("t%.box%("), "Expected t.box(...) in direct runtime output")
    end)

    it("does not affect capitalized component tags", function()
      local comp_src = [[
local t = require("hydronium.terminal")
---@luax environment t

return <Widget title="Hi" />
]]
      local res = compiler.compile(comp_src, { virtual_luals = true })
      assert.truthy(res.code:find("__luax_component%s*%(%s*Widget"), "Component tags should still use __luax_component")
    end)
  end)

  describe("without a pragma (implicit default)", function()
    local src = [[return <div><span>Hello</span></div>]]

    it("falls back to the typed `d.<tag>` global in virtual_luals mode", function()
      local res = compiler.compile(src, { virtual_luals = true })
      assert.truthy(res.code:find("d%.div%("), "Expected fallback to d.div")
      assert.truthy(res.code:find("d%.span%("), "Expected fallback to d.span")
    end)

    it("records every bare intrinsic tag in bare_tags_without_alias", function()
      local res = compiler.compile(src, { virtual_luals = true })
      assert.equal(2, #res.bare_tags_without_alias)
      assert.equal("div", res.bare_tags_without_alias[1].tag)
      assert.equal("span", res.bare_tags_without_alias[2].tag)
    end)

    it("preserves prior string-tag runtime emission (no behavior change without the pragma)", function()
      local res = compiler.compile(src, { runtime = "hydronium" })
      assert.truthy(res.code:find('H%.h%("div"'), "Expected unqualified runtime emission to stay string-tag based")
    end)
  end)
end)
