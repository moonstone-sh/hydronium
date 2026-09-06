local runner = require("tests.runner")
local plugin = require("hydronium.luax.plugin")

describe("LUAX LuaLS Plugin & Virtual Lowering", function()
  describe("virtual_lower", function()
    it("lowers intrinsic elements to __luax_intrinsic calls", function()
      local src = [[local btn = <button id="my-btn" disabled onClick={handleClick}>Click Me</button>]]
      local virt = plugin.virtual_lower(src)

      assert.truthy(virt:find("__luax_intrinsic%.button"), "Expected __luax_intrinsic.button in output")
      assert.truthy(virt:find("id = \"my%-btn\""), "Expected id prop in output")
      assert.truthy(virt:find("disabled = true"), "Expected boolean attribute disabled=true in output")
      assert.truthy(virt:find("onClick = handleClick"), "Expected onClick attribute in output")
      assert.truthy(virt:find("\"Click Me\""), "Expected child text in output")
    end)

    it("lowers custom components to __luax_component calls", function()
      local src = [[local comp = <UserProfile name="Ada" age={36} />]]
      local virt = plugin.virtual_lower(src)

      assert.truthy(virt:find("__luax_component%s*%(%s*UserProfile"), "Expected __luax_component(UserProfile) in output")
      assert.truthy(virt:find("name = \"Ada\""), "Expected name prop in output")
      assert.truthy(virt:find("age = 36"), "Expected age prop in output")
    end)

    it("lowers fragments to __luax_fragment calls", function()
      local src = [[local frag = <><span>Item 1</span><span>Item 2</span></>]]
      local virt = plugin.virtual_lower(src)

      assert.truthy(virt:find("__luax_fragment"), "Expected __luax_fragment in output")
      assert.truthy(virt:find("__luax_intrinsic%.span"), "Expected span elements in output")
    end)

    it("lowers nested elements and components preserving structure", function()
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

      assert.truthy(virt:find("__luax_component%s*%(%s*Card"), "Expected Card component")
      assert.truthy(virt:find("__luax_intrinsic%.div"), "Expected div intrinsic")
      assert.truthy(virt:find("__luax_intrinsic%.button"), "Expected button intrinsic")
      assert.truthy(virt:find("onClick = onSave"), "Expected onClick handler")
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
      assert.truthy(res.text:find("__luax_intrinsic%.button"), "Expected virtual lowering in text")
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
