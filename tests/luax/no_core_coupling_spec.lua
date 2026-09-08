-- hydronium-luax has no runtime dependency on the core or DOM packages.
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

describe("hydronium_luax package isolation", function()
  it("loads without core or DOM in a fresh process", function()
    local interpreter = os.getenv("LUA") or os.getenv("MOONSTONE_LUA") or "luajit"
    local handle = io.popen(
      interpreter .. " -e '" ..
      "package.path = \"luax/src/?.lua;luax/src/?/init.lua;\" .. package.path; " ..
      "require(\"hydronium_luax\"); " ..
      "print(\"core=\" .. tostring(package.loaded[\"hydronium\"] ~= nil)); " ..
      "print(\"dom=\" .. tostring(package.loaded[\"hydronium_dom\"] ~= nil))' 2>&1"
    )
    local output = handle:read("*a")
    handle:close()
    assert.truthy(output:find("core=false"), output)
    assert.truthy(output:find("dom=false"), output)
  end)

  it("compiles real LUAX without core", function()
    local luax = require("hydronium_luax")
    local result = luax.compile("return <div>hi</div>", {
      filename = "t.luax", runtime = "hydronium", development = false,
    })
    assert.truthy(result and result.code)
    -- The shared suite has already loaded core.  The fresh-process gate above
    -- is the isolation assertion; this one only proves compilation works.
  end)
end)
