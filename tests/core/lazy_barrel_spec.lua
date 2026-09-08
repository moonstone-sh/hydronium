-- The core barrel is deliberately package-local after the workspace split.
-- DOM/SSR and LUAX are imported explicitly from their own package namespaces.
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

describe("hydronium core barrel package boundary", function()
  it("requiring core does not load DOM or LUAX packages in a fresh process", function()
    local handle = io.popen(
      "lua -e '" ..
      "package.path = \"core/src/?.lua;core/src/?/init.lua;luax/src/?.lua;luax/src/?/init.lua;dom/src/?.lua;dom/src/?/init.lua;\" .. package.path; " ..
      "require(\"hydronium\"); " ..
      "print(\"dom=\" .. tostring(package.loaded[\"hydronium_dom\"] ~= nil)); " ..
      "print(\"luax=\" .. tostring(package.loaded[\"hydronium_luax\"] ~= nil))' 2>&1"
    )
    local output = handle:read("*a")
    handle:close()
    assert.truthy(output:find("dom=false"), output)
    assert.truthy(output:find("luax=false"), output)
  end)

  it("keeps the core API eagerly available", function()
    local H = require("hydronium")
    assert.equal(type(H.core), "table")
    assert.equal(type(H.signals), "table")
    assert.equal(type(H.h), "function")
    assert.equal(type(H.signal), "function")
    assert.equal(type(H.test), "table")
    assert.equal(type(H.Reconciler), "table")
  end)
end)
