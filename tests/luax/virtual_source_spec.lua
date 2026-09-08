local runner = require("tests.runner")
local virtual_source = require("hydronium_luax.luals.virtual_source")
local luals_plugin = require("hydronium_luax.luals")
local loadstring = loadstring or load

describe("LUAX Virtual Source & LuaLS Lowering", function()
  it("preserves exact line count between .luax and virtual source", function()
    local src = [[
local function ButtonComponent(props)
  local count, setCount = Hydronium.createSignal(0)
  return (
    <button
      onClick={function(ev)
        setCount(count() + 1)
      end}
    >
      Click me
    </button>
  )
end
]]
    local virtual_code = virtual_source.transform(src)

    -- Count lines in both
    local function count_lines(s)
      local count = 1
      for _ in s:gmatch("\n") do count = count + 1 end
      return count
    end

    assert.equal(count_lines(virtual_code), count_lines(src), "Line count mismatch in virtual source")
  end)

  it("preserves 1:1 byte and column offsets for embedded expressions", function()
    local src = "local x = <button onClick={function(ev) return ev.clientX end} />"
    local virtual_code = virtual_source.transform(src)

    -- Find byte position of 'function(ev)' in src
    local orig_s, orig_e = src:find("function%(ev%) return ev.clientX end")
    assert.truthy(orig_s)

    -- Find byte position in virtual_code
    local virt_s, virt_e = virtual_code:find("function%(ev%) return ev.clientX end")
    assert.truthy(virt_s)

    assert.equal(virt_s, orig_s, "Embedded expression start column shifted in virtual source!")
    assert.equal(virt_e, orig_e, "Embedded expression end column shifted in virtual source!")
  end)

  it("injects typed intrinsic lowering into virtual source", function()
    local src = "local btn = <button onClick={handleClick} />"
    local virtual_code = virtual_source.transform(src)

    -- Should contain typed call to button
    assert.truthy(virtual_code:find("button"))
    assert.truthy(virtual_code:find("handleClick"))
  end)

  it("intercepts .luax files in LuaLS OnSetText hook", function()
    local luax_uri = "file:///workspace/App.luax"
    local lua_uri = "file:///workspace/util.lua"

    local luax_res = luals_plugin.OnSetText(luax_uri, "return <div />")
    assert.is_table(luax_res)
    assert.is_string(luax_res.text)

    local lua_res = luals_plugin.OnSetText(lua_uri, "return 123")
    assert.is_nil(lua_res, "Non-luax file should not be intercepted")
  end)

  it("does not produce leading comma {, syntax errors on elements with children", function()
    local src = "<button>Click me</button>"
    local virtual_code = virtual_source.transform(src)
    assert.falsy(virtual_code:find("{,"), "Virtual source must not contain leading comma '{,'")
    local chunk, err = loadstring("local button = function(t) end; " .. virtual_code)
    assert.is_not_nil(chunk, "Virtual code failed to parse: " .. tostring(err))
  end)

  it("formats spread attributes with valid table field comma separators", function()
    local src = "local x = <Button a={1} {...props} b={2} />"
    local virtual_code = virtual_source.transform(src)
    local chunk, err = loadstring("local Button = function(t) end; local props = {}; " .. virtual_code)
    assert.is_not_nil(chunk, "Virtual code with spread failed to parse: " .. tostring(err))
  end)

  it("produces valid Lua syntax for nested elements and custom components", function()
    local src = "local x = <div><Button title=\"Save\"><span>Text</span></Button></div>"
    local virtual_code = virtual_source.transform(src)
    local chunk, err = loadstring("local div, Button, span = function(t) end, function(t) end, function(t) end; " .. virtual_code)
    assert.is_not_nil(chunk, "Virtual code with nested elements failed to parse: " .. tostring(err))
  end)

  it("guarantees standard Lua select and table builtins are unshadowed", function()
    -- Ensure native select and table builtins exist and function normally
    assert.equal(select("#", 1, 2, 3), 3)
    assert.equal(type(table.concat), "function")
  end)

  describe("Exact 1:1 Byte-Aligned Lowering for Dotted Descriptors", function()
    it("lowers opening tag <d.button  (10 bytes) to ' d.button{' (10 bytes)", function()
      local src = "<d.button id=\"ok\">Click</d.button>"
      local virt = virtual_source.transform(src)
      assert.truthy(virt:find("^ d%.button{"))
      assert.equal(#src, #virt, "Exact length must be identical")
    end)

    it("lowers self-closing tag <d.input /> (11 bytes) to ' d.input{ }' (11 bytes)", function()
      local src = "<d.input />"
      local virt = virtual_source.transform(src)
      assert.equal(virt, " d.input{ }")
      assert.equal(#virt, 11)
      assert.equal(#src, 11)
    end)

    it("lowers closing tag </d.button> (11 bytes) to '}----------' (11 bytes, comment-padded)", function()
      -- Comment-padded (`}` + `--` line comment filling the rest), not
      -- space-padded, when the closing tag is the last thing on its
      -- line/source (as here) -- see virtual_source.lua's closing-tag
      -- comment for why: plain spaces here become real trailing
      -- whitespace in the virtual document, which LuaLS's own "Line
      -- with trailing space" diagnostic flags on every closing tag in
      -- a real file.
      local src = "<d.button>Hello</d.button>"
      local virt = virtual_source.transform(src)
      local close_part = virt:sub(-11)
      assert.equal(close_part, "}----------")
      assert.equal(#virt, #src)
    end)

    it("falls back to space-padding a closing tag when more markup follows it on the same line", function()
      -- Regression test: a first attempt at comment-padding
      -- unconditionally used `--`, which swallowed whatever followed on
      -- the same physical line as a comment -- caught by the sweep in
      -- commit b434c73's follow-up via examples/showcase/ErrorBoundary.luax's
      -- real `<pre><code>{msg}</code></pre>` (two closing tags on one
      -- line) and a sibling-comma case in examples/meteorite_ssr's
      -- App.luax, both of which stopped parsing as valid Lua.
      local src = "<d.pre><d.code>x</d.code></d.pre>"
      local virt = virtual_source.transform(src)
      local ok = loadstring and loadstring(virt) or load(virt)
      assert.truthy(ok, "virtual code with two closing tags on one line must still be valid Lua: " .. virt)
      assert.equal(#src, #virt)
    end)

    it("keeps a solo trailing {expr} child's braces paired instead of unbalancing the enclosing call", function()
      -- Regression test: a first attempt at avoiding trailing
      -- whitespace on a lone `}` (when a bare {expr} child, like
      -- `{props.children}`, is the only content on its line) blanked
      -- the opening `{` unconditionally but only conditionally kept the
      -- closing `}` -- removing one brace of the pair without the
      -- other, undercounting the enclosing call's closing braces by
      -- one. Caught by the sweep via examples/showcase/ErrorBoundary.luax's
      -- real `{props.children}` (sole child, own line, inside
      -- `<H.ErrorBoundary>`), which stopped parsing entirely.
      local src = "<d.main>\n  {props.children}\n</d.main>"
      local virt = virtual_source.transform(src)
      local ok = loadstring and loadstring(virt) or load(virt)
      assert.truthy(ok, "virtual code with a solo trailing {expr} child must still be valid Lua: " .. virt)
      assert.equal(#src, #virt)
    end)

    it("preserves exact column and byte coordinates for attributes and handlers", function()
      local src = "local b = <d.button onClick={function(e) return e end}>Go</d.button>"
      local virt = virtual_source.transform(src)
      assert.equal(#src, #virt)
      local orig_idx = src:find("function%(e%) return e end")
      local virt_idx = virt:find("function%(e%) return e end")
      assert.truthy(orig_idx)
      assert.equal(orig_idx, virt_idx)
    end)
  end)
end)
