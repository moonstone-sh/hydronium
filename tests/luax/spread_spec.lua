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

describe("LUAX spread in compiled output", function()
  local dialects = require("hydronium_luax.dialects")

  local function assert_load(code, env)
    local chunk, err = require("hydronium_luax.compat").load(code, "=compiled", env)
    if not chunk then error(err .. "\n" .. code, 0) end
    return chunk
  end

  -- A browser VM loads hydronium but never hydronium_luax.runtime, so the
  -- compiled component must not depend on the `__luax` global.
  local function load_without_luax_global(code, env_extra)
    local env = setmetatable(env_extra or {}, { __index = function(_, key)
      if key == "__luax" then return nil end
      return _G[key]
    end })
    local chunk = assert_load(code, env)
    return chunk()
  end

  it("takes spread from the hydronium factory's table, not a hidden global", function()
    local code = dialects.compile('local H = require("hydronium")\nreturn function(props) return <div id="a" {...props}>x</div> end\n',
      { filename = "C.luax", runtime = "hydronium" }).code
    assert.truthy(code:find("(H.spread or __luax.spread)(", 1, true), code)
    local C = load_without_luax_global(code)
    local vnode = C({ class = "b" })
    assert.equal(vnode.props.id, "a")
    assert.equal(vnode.props.class, "b")
  end)

  it("calls a pragma's `X.spread or __luax.spread` instead of returning it", function()
    local code = dialects.compile('-- @jsx X.h\nreturn function(props) return <div {...props} /> end\n', { filename = "P.luax" }).code
    local X = { h = function(tag, props) return { tag = tag, props = props } end,
      spread = require("hydronium").spread }
    local P = load_without_luax_global(code, { X = X })
    local node = P({ id = "z" })
    assert.equal(type(node.props), "table")
    assert.equal(node.props.id, "z")
  end)
end)
