package.path = "./luax/src/?.lua;" .. package.path
local markdown = require("hydronium_luax.markdown")
local loader = require("hydronium_luax.loader")

describe("Hydronium Markdown components", function()
  it("compiles prose, links, lists and fenced code as safe DOM nodes", function()
    local source = [[# Guide

Use **Hydronium** with [Lab](https://example.test/lab).

- One
- Two

```lua
<unsafe>
```
]]
    local result = markdown.compile(source, { filename = "Guide.md" })
    assert.truthy(result.code:find('H.h%("h1"'))
    assert.truthy(result.code:find('H.h%("strong"'))
    assert.truthy(result.code:find('H.h%("a"'))
    assert.truthy(result.code:find('H.h%("ul"'))
    assert.truthy(result.code:find('H.h%("pre"'))
    assert.falsy(result.code:find('H.h%("unsafe"'))
  end)

  it("compiles Lua setup and standalone LUAX components in mdx", function()
    local result = markdown.compile([[```lua setup
local Demo = require("Demo")
```

# Try it
<Demo count={2} />
]], { filename = "Guide.mdx" })
    assert.truthy(result.code:find('require%("Demo"%)'))
    assert.truthy(result.code:find('H.h%(Demo'))
    assert.truthy(result.code:find('count = 2'))
  end)

  it("does not turn prose into HTML or unsafe link schemes", function()
    local result = markdown.compile("<script>alert(1)</script> [click](javascript:alert(1))", { filename = "safe.md" })
    assert.falsy(result.code:find('H.h%("script"'))
    assert.falsy(result.code:find('href = "javascript:'))
  end)

  it("uses the same content-cached loader for md and mdx", function()
    local path = os.tmpname() .. ".md"
    local file = io.open(path, "wb")
    assert.truthy(file)
    file:write("# Cached document\n"); file:close()
    local code = loader.source(path)
    assert.truthy(code:find('Cached document'))
    assert.is_function(loader.load(path))
    os.remove(path)
    loader.invalidate(path)
  end)

  it("resolves a Markdown component through ordinary require", function()
    local path = "/tmp/hydronium_markdown_require_spec.mdx"
    local file = io.open(path, "wb")
    assert.truthy(file)
    file:write("# Required document\n"); file:close()
    package.path = "/tmp/?.lua;" .. package.path
    loader.install()
    package.loaded.hydronium_markdown_require_spec = nil
    local component = require("hydronium_markdown_require_spec")
    assert.is_function(component)
    os.remove(path)
    package.loaded.hydronium_markdown_require_spec = nil
  end)
end)
