local runner = require("tests.runner")
local plugin = require("hydronium_luax.plugin")

describe("LUAX LuaLS Plugin & Virtual Lowering", function()
  describe("virtual_lower", function()
    -- `virtual_lower` is byte-length-preserving (see the "1:1 line coordinate
    -- stability" tests below and docs/LUAX_DX_CURRENT_STATE.md): every tag
    -- projects to a direct call using the *exact same identifier text* the
    -- source already contains (`button{...}`, `UserProfile{...}`, `d.button{...}`),
    -- never a longer qualified/wrapped form (`__luax_intrinsic.button(...)`,
    -- `__luax_component(UserProfile, ...)`), because introducing extra
    -- characters at a tag site cannot be done without shifting every
    -- following byte on that line -- which corrupts LuaLS rename/reference
    -- results computed against the virtual document. Bare intrinsic tags
    -- therefore surface as plain identifier calls (typically an
    -- undefined-global from LuaLS's point of view unless the project
    -- happens to bind that name), which is a real, honest signal nudging
    -- toward the lexical `<d.button>` form or an explicit
    -- `---@luax environment <alias>` pragma (see compiler/init.lua and the
    -- "Explicit Bare-Tag Environment Pragma" spec) rather than a cosmetic one.
    it("lowers bare intrinsic tags to a direct, byte-width-preserving call", function()
      local src = [[local btn = <button id="my-btn" disabled onClick={handleClick}>Click Me</button>]]
      local virt = plugin.virtual_lower(src)

      assert.truthy(virt:find("button{"), "Expected a direct button{...} call in output")
      assert.truthy(virt:find('id="my%-btn"'), "Expected id prop in output")
      assert.truthy(virt:find("disabled"), "Expected boolean attribute disabled in output")
      assert.truthy(virt:find("onClick=%(handleClick%)"), "Expected onClick attribute in output")
      assert.equal(#src, #virt, "Virtual output must be exactly as long as the source")
    end)

    it("lowers custom components to a direct call on the component identifier", function()
      local src = [[local comp = <UserProfile name="Ada" age={36} />]]
      local virt = plugin.virtual_lower(src)

      assert.truthy(virt:find("UserProfile{"), "Expected a direct UserProfile{...} call in output")
      assert.truthy(virt:find('name="Ada"'), "Expected name prop in output")
      assert.truthy(virt:find("age=%(36%)"), "Expected age prop in output")
      assert.equal(#src, #virt, "Virtual output must be exactly as long as the source")
    end)

    it("lowers fragments to a bare table literal", function()
      local src = [[local frag = <><span>Item 1</span><span>Item 2</span></>]]
      local virt = plugin.virtual_lower(src)

      assert.truthy(virt:find("span{"), "Expected span elements in output")
      assert.equal(#src, #virt, "Virtual output must be exactly as long as the source")
    end)

    it("lowers nested elements and components preserving structure and byte length", function()
      local src = [[
local card = (
  <Card title="Overview">
    <div class="content">
      <button onClick={onSave}>Save</button>
    </div>
  </Card>
)
]]
      local virt = plugin.virtual_lower(src)

      assert.truthy(virt:find("Card{"), "Expected a direct Card{...} call")
      assert.truthy(virt:find("div{"), "Expected div intrinsic")
      assert.truthy(virt:find("button{"), "Expected button intrinsic")
      assert.truthy(virt:find("onClick=%(onSave%)"), "Expected onClick handler")
      assert.equal(#src, #virt, "Virtual output must be exactly as long as the source")
    end)
  end)

  describe("1:1 line coordinate stability", function()
    local function count_lines(s)
      local count = 1
      for _ in s:gmatch("\n") do count = count + 1 end
      return count
    end

    it("preserves exact line count for multi-line component", function()
      local src = [[
local function Counter(props)
  local count, setCount = Hydronium.createSignal(0)

  local function increment()
    setCount(count() + 1)
  end

  return (
    <div class="counter">
      <span>Count: {count()}</span>
      <button onClick={increment}>
        +
      </button>
    </div>
  )
end
return Counter
]]
      local virt = plugin.virtual_lower(src)
      assert.equal(count_lines(virt), count_lines(src), "Virtual code line count must match original source line count")
    end)

    it("maintains line alignment for embedded expressions", function()
      local src = "local a = 1\nlocal b = <button onClick={function(ev)\n  print(ev.clientX)\nend} />\nlocal c = 2"
      local virt = plugin.virtual_lower(src)
      assert.equal(count_lines(virt), count_lines(src))

      local function split_lines(str)
        local lines = {}
        for line in (str .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(lines, line)
        end
        return lines
      end

      local virt_lines = split_lines(virt)

      assert.truthy(virt_lines[1]:find("local a = 1"), "Line 1 mismatch")
      assert.truthy(virt_lines[3]:find("print%(ev%.clientX%)"), "Line 3 mismatch")
      assert.truthy(virt_lines[5]:find("local c = 2"), "Line 5 mismatch")
    end)
  end)

  describe("OnSetText hook", function()
    it("intercepts .luax URIs and returns virtual lower text", function()
      local uri = "file:///workspace/project/App.luax"
      local src = "local el = <button onClick={fn}>Click</button>"
      local res = plugin.OnSetText(uri, src)

      assert.is_table(res, "Expected table result from OnSetText for .luax")
      assert.is_string(res.text, "Expected string text property")
      assert.truthy(res.text:find("button{"), "Expected virtual lowering in text")
    end)

    it("ignores non-.luax URIs (returns nil)", function()
      local uri = "file:///workspace/project/App.lua"
      local src = "local x = 42"
      local res = plugin.OnSetText(uri, src)

      assert.is_nil(res, "Expected nil result for .lua files")
    end)

    it("handles nil or empty URI gracefully", function()
      local res1 = plugin.OnSetText(nil, "local x = 1")
      assert.is_nil(res1)

      local res2 = plugin.OnSetText("", "local x = 1")
      assert.is_nil(res2)
    end)
  end)

  describe("ResolveRequire hook", function()
    it("resolves .luax files relative to base URI", function()
      local uri = "file:///Users/extrordinaire/Workbench/user/hydronium/tests/fixtures/fixture_runtime.lua"
      local res = plugin.ResolveRequire(uri, "sample_component")

      assert.is_string(res, "Expected resolved URI string")
      assert.truthy(res:find("sample_component%.luax$"), "Expected resolved path to end in sample_component.luax")
    end)

    it("resolves .luax files via tests/ directory lookup", function()
      local res = plugin.ResolveRequire(nil, "fixtures.sample_component")

      assert.is_string(res, "Expected resolved path for fixtures.sample_component")
      assert.truthy(res:find("tests/fixtures/sample_component%.luax$"), "Expected tests/ path prefix")
    end)

    it("returns nil for nonexistent modules", function()
      local res = plugin.ResolveRequire(nil, "nonexistent.module.xyz")
      assert.is_nil(res, "Expected nil for nonexistent module")
    end)

    it("returns nil for invalid or nil module names", function()
      assert.is_nil(plugin.ResolveRequire(nil, nil))
      assert.is_nil(plugin.ResolveRequire(nil, 123))
    end)
  end)
end)
