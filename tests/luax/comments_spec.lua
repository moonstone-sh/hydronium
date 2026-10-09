local h = require("tests.runner")
local compiler = require("hydronium_luax.compiler")

local describe, it = h.describe, h.it
local assert = h.assert

-- Lua allows a comment between any two tokens. The LUAX parser keeps
-- comments as tokens, so every list it parses must step over them.
describe("LUAX parses comments wherever Lua allows them", function()
  local cases = {
    { "a table field", 'local t = {\n  a = 1, -- trailing\n  -- own line\n  b = 2,\n}' },
    { "a block comment in a table", 'local t = {\n  --[[ block\n  comment ]]\n  a = 1,\n}' },
    { "a style table in an attribute", 'local d = {}\nlocal x = <d.p style={{\n  a = 1,\n  -- why b\n  b = 2,\n}}>hi</d.p>' },
    { "a parameter list", 'local function g(a, -- the a\n  b) return a end' },
    { "call arguments", 'local x = f(1, -- first\n  2)' },
    { "after an equals sign", 'local x = -- value\n  1' },
  }
  for _, case in ipairs(cases) do
    it("allows a comment in " .. case[1], function()
      local ok, result = pcall(compiler.compile, case[2], { filename = "x.luax" })
      assert.truthy(ok, tostring(result))
      assert.truthy((loadstring or load)(result.code), result.code)
    end)
  end
end)
