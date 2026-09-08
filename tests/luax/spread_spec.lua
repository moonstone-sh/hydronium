local runner = require("tests.runner")
local runtime = require("hydronium_luax.runtime")

describe("LUAX Spread Operator Runtime", function()
  it("merges tables left-to-right with later keys overwriting earlier keys", function()
    local t1 = { id = "initial", class = "box" }
    local props = { id = "middle", title = "hover text" }
    local t2 = { id = "override", disabled = true }

    local result = runtime.spread(t1, props, t2)

    assert.equal(result.id, "override")
    assert.equal(result.class, "box")
    assert.equal(result.title, "hover text")
    assert.equal(result.disabled, true)
  end)

  it("handles nil and false guards safely", function()
    local base = { count = 10 }
    local cond = false
    local dynamic = cond and { count = 20 } or nil

    local result = runtime.spread(base, dynamic, false, nil, { extra = "yes" })

    assert.equal(result.count, 10)
    assert.equal(result.extra, "yes")
  end)

  it("returns an empty table when called with no arguments", function()
    local result = runtime.spread()
    assert.is_table(result)
    assert.equal(next(result), nil)
  end)

  it("creates a new table and does not mutate source tables", function()
    local t1 = { a = 1 }
    local t2 = { b = 2 }

    local result = runtime.spread(t1, t2)
    result.a = 999

    assert.equal(t1.a, 1)
    assert.equal(result.a, 999)
  end)
end)
