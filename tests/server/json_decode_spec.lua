--[[
  hydronium_dom.server.json.decode -- added for STEP 1 of
  docs/HYDRONIUM_WEB_VITE_ADAPTER_PLAN.md so the "vite-manifest" asset
  provider can read a real Vite dist/.vite/manifest.json directly. Scoped
  to what that file needs (objects, arrays, strings incl. \uXXXX escapes,
  numbers, true/false/null) -- see the module's own header for why this
  is the one place in dom/ that decodes actual JSON.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local json = require("hydronium_dom.server.json")

describe("hydronium_dom.server.json.decode", function()
  it("decodes primitives", function()
    assert.equal(json.decode("true"), true)
    assert.equal(json.decode("false"), false)
    assert.equal(json.decode("42"), 42)
    assert.equal(json.decode("-3.5"), -3.5)
    assert.equal(json.decode("1e3"), 1000)
    assert.equal(json.decode('"hello"'), "hello")
    assert.equal(json.decode("null"), json.null)
  end)

  it("decodes a flat object with string keys", function()
    local v = json.decode('{"a": 1, "b": "two", "c": true}')
    assert.equal(v.a, 1)
    assert.equal(v.b, "two")
    assert.equal(v.c, true)
  end)

  it("decodes an array as a 1-based Lua array", function()
    local v = json.decode('[1, 2, 3]')
    assert.equal(#v, 3)
    assert.equal(v[1], 1)
    assert.equal(v[2], 2)
    assert.equal(v[3], 3)
  end)

  it("decodes nested objects/arrays -- a real Vite manifest entry shape", function()
    local v = json.decode([[{
      "src/main.js": {
        "file": "assets/main.abc123.js",
        "isEntry": true,
        "css": ["assets/main.def456.css"],
        "imports": ["_shared.js"]
      }
    }]])
    local entry = v["src/main.js"]
    assert.equal(entry.file, "assets/main.abc123.js")
    assert.equal(entry.isEntry, true)
    assert.equal(#entry.css, 1)
    assert.equal(entry.css[1], "assets/main.def456.css")
    assert.equal(entry.imports[1], "_shared.js")
  end)

  it("handles string escapes, including \\u unicode escapes", function()
    assert.equal(json.decode('"a\\nb"'), "a\nb")
    assert.equal(json.decode('"quote:\\""'), 'quote:"')
    assert.equal(json.decode('"\\u0041"'), "A")
  end)

  it("handles whitespace between tokens", function()
    local v = json.decode('  {\n  "a" : [ 1 , 2 ]  }  ')
    assert.equal(v.a[1], 1)
    assert.equal(v.a[2], 2)
  end)

  it("raises on malformed input rather than returning a partial result", function()
    assert.falsy(pcall(json.decode, "{"))
    assert.falsy(pcall(json.decode, '{"a": }'))
    assert.falsy(pcall(json.decode, "[1, 2"))
    assert.falsy(pcall(json.decode, "not json"))
  end)

  it("raises on trailing data after a valid document", function()
    assert.falsy(pcall(json.decode, "{}garbage"))
  end)

  it("requires a string argument", function()
    assert.falsy(pcall(json.decode, nil))
    assert.falsy(pcall(json.decode, {}))
  end)
end)
