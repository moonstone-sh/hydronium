local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local H = require("hydronium")
local S = require("hydronium_ink.session")
local inspector = require("inspector")

describe("hydronium CLI request field navigation", function()
  it("opens the synthetic story during render without a signal mutation", function()
    local collection = dofile("cli/src/ui/search_bar.stories.lua")
    local copied = {}
    local s = S.create(H.h(function() return collection.render({mode="session"}) end), {
      columns=100, rows=28, writeFn=function() end,
      onClipboardWrite=function(value) copied[#copied+1]=value end,
    })
    assert.truthy(s:frame())
    s:write("\27[A\27[A\rllc") -- /api/contact -> detail -> headers -> body -> copy
    assert.equal(copied[#copied], '{"email":""}')
    s:write("hy") -- headers section, all headers at full length
    local headers = copied[#copied]
    assert.truthy(headers:find("content-type: application/json",1,true))
    assert.truthy(headers:find("x-request-id: contact-422",1,true))
    s:write("jc") -- first individual header value
    assert.equal(copied[#copied], "application/json")
    s:close()
  end)

  it("copies the full raw header and body even when the display is clipped", function()
    local long = string.rep("abc", 120)
    local fields = inspector.detail_entries({kind="request", method="POST", path="/a",
      headers={foo=long}, body=long .. "\\nsecond"})
    assert.equal(fields[7].copy, long)
    assert.equal(inspector.section_copy(fields, "body"), long .. "\\nsecond")
    assert.equal(inspector.section_jump(fields, 1, 1), 6)
    assert.equal(inspector.section_jump(fields, 6, 1), 8)
    assert.equal(inspector.section_jump(fields, 8, -1), 6)
  end)
end)
