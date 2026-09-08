local runner = require("tests.runner")
local compiler = require("hydronium_luax.compiler")
local sourcemap = require("hydronium_luax.compiler.sourcemap")

describe("LUAX Compiler & Lowering", function()
  it("compiles intrinsic tags and attributes to __luax.element", function()
    local src = "local el = <div id=\"main\" className=\"container\">hello</div>"
    local res = compiler.compile(src)

    assert.is_string(res.code)
    assert.truthy(res.code:find('__luax.element%("div"'))
    assert.truthy(res.code:find('id = "main"'))
    assert.truthy(res.code:find('className = "container"'))
    assert.truthy(res.code:find('"hello"'))
  end)

  it("compiles hyphenated attributes with string bracket keys", function()
    local src = "return <button aria-label=\"Close\" data-testid=\"close-btn\" />"
    local res = compiler.compile(src)

    assert.truthy(res.code:find('%["aria%-label"%] = "Close"'))
    assert.truthy(res.code:find('%["data%-testid"%] = "close%-btn"'))
  end)

  it("compiles boolean attribute shorthand to true", function()
    local src = "return <input disabled />"
    local res = compiler.compile(src)

    assert.truthy(res.code:find('disabled = true'))
  end)

  it("compiles dotted components as expressions rather than strings", function()
    local src = "return <UI.Button.Primary color=\"red\">Submit</UI.Button.Primary>"
    local res = compiler.compile(src)

    assert.truthy(res.code:find('__luax.element%(UI%.Button%.Primary'))
  end)

  it("compiles fragments to __luax.fragment", function()
    local src = "return <><span>1</span><span>2</span></>"
    local res = compiler.compile(src)

    assert.truthy(res.code:find('__luax.fragment%(nil'))
    assert.truthy(res.code:find('"span"'))
  end)

  it("lowers spread attributes to __luax.spread in left-to-right evaluation", function()
    local src = "return <div id=\"initial\" {...props} id=\"override\" />"
    local res = compiler.compile(src)

    assert.truthy(res.code:find('__luax.spread%('))
    assert.truthy(res.code:find('id = "initial"'))
    assert.truthy(res.code:find('props'))
    assert.truthy(res.code:find('id = "override"'))
  end)

  it("generates valid SourceMap V3 with VLQ mappings", function()
    local src = "local x = <button onClick={handleClick}>Click</button>"
    local res = compiler.compile(src, { sourcemap = true, filename = "test.luax" })

    assert.is_table(res.sourcemap)
    assert.is_string(res.map_json)
    assert.truthy(res.map_json:find('"version": 3'))
    assert.truthy(res.map_json:find('"sources": %["test.luax"%]'))
    assert.truthy(res.map_json:find('"mappings":'))

    local decoded = sourcemap.decode_mappings(res.sourcemap:encode_mappings())
    assert.truthy(#decoded >= 1)
  end)

  it("compiles <d.button ...> targeting Hydronium runtime to H.h(d.button, { ... })", function()
    local src = "return <d.button id=\"ok\" disabled>Submit</d.button>"
    local res = compiler.compile(src, { runtime = "hydronium" })
    assert.truthy(res.code:find("H%.h%(d%.button,"), "Expected H.h(d.button, ...) in compiled output")
    assert.truthy(res.code:find('id = "ok"'))
  end)

  it("compiles <d.button ...> targeting direct runtime to d.button({ ... })", function()
    local src = "return <d.button id=\"ok\" disabled>Submit</d.button>"
    local res = compiler.compile(src, { runtime = "direct" })
    assert.truthy(res.code:find("d%.button%("), "Expected d.button(...) in compiled direct output")
    assert.truthy(res.code:find('id = "ok"'))
  end)
end)
