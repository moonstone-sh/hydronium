local h = require("tests.runner")
local compiler = require("hydronium_luax.compiler")

local describe, it = h.describe, h.it
local assert = h.assert

-- Compiled LUAX starts each statement on its source line, so Lua's error
-- messages, tracebacks and debug.getinfo (Hydronium's development warnings)
-- point at the .luax file's own lines.
describe("LUAX compiled output keeps statements on their source lines", function()
  local source = table.concat({
    'local H = require("hydronium")',          -- 1
    'local d = { p = "p" }',                   -- 2
    '',                                        -- 3
    '---@param props table',                   -- 4
    'local function Card(props)',              -- 5
    '',                                        -- 6
    '  -- a comment',                          -- 7
    '  local broken = props.missing.field',    -- 8
    '  return <d.p>{broken}</d.p>',            -- 9
    'end',                                     -- 10
    '',                                        -- 11
    'return Card',                             -- 12
  }, "\n")

  it("places declarations and statements on their source lines", function()
    local code = compiler.compile(source, { filename = "Card.luax", runtime = "hydronium", h = "H.h" }).code
    local n, at = 0, {}
    for line in (code .. "\n"):gmatch("(.-)\n") do
      n = n + 1
      if line:find("local function Card", 1, true) then at.card = n end
      if line:find("local broken", 1, true) then at.broken = n end
      if line:find("return Card", 1, true) then at.ret = n end
    end
    assert.equal(at.card, 5)
    assert.equal(at.broken, 8)
    assert.equal(at.ret, 12)
  end)

  it("reports a runtime error at the .luax line", function()
    local code = compiler.compile(source, { filename = "Card.luax", runtime = "hydronium", h = "H.h" }).code
    local chunk, load_err = (loadstring or load)(code, "@Card.luax")
    assert.truthy(chunk, tostring(load_err))
    local Card = chunk()
    local ok, err = pcall(Card, {})
    assert.equal(ok, false)
    assert.truthy(tostring(err):find("Card.luax:8:", 1, true), tostring(err))
  end)
end)
