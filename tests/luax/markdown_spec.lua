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
    assert.truthy(result.code:find('H.h%(HydroniumMdH1'))
    assert.truthy(result.code:find('H.h%(HydroniumMdStrong'))
    assert.truthy(result.code:find('H.h%(HydroniumMdA'))
    assert.truthy(result.code:find('H.h%(HydroniumMdUl'))
    assert.truthy(result.code:find('H.h%(HydroniumMdPre'))
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

  it("server renders compiled documents as normal Hydronium DOM", function()
    local result = markdown.compile("# Hello\n\nSome **bold** text.\n", { filename = "Page.md" })
    local component = (loadstring or load)(result.code, "@Page.md")()
    local H = require("hydronium")
    local html = require("hydronium_dom.server").renderToString(H.h(component))
    assert.truthy(html:find('<article><h1 id="hello">Hello</h1><p>Some <strong>bold</strong> text.</p></article>', 1, true))
  end)

  it("lets the host replace Markdown elements through component props", function()
    local result = markdown.compile("# Title\n\nCustom paragraph.\n", { filename = "Page.md" })
    local component = (loadstring or load)(result.code, "@Page.md")()
    local H = require("hydronium")
    local html = require("hydronium_dom.server").renderToString(H.h(component, { components = { p = "section" } }))
    assert.truthy(html:find("<section>Custom paragraph.</section>", 1, true))
  end)

  it("gives headings stable anchors and renders documentation tables", function()
    local source = [[# API Surface

# API Surface

| Package | Purpose |
| --- | --- |
| `lab` | Stories |
]]
    local result = markdown.compile(source, { filename = "API.md" })
    local component = (loadstring or load)(result.code, "@API.md")()
    local H = require("hydronium")
    local html = require("hydronium_dom.server").renderToString(H.h(component))
    assert.truthy(html:find('id="api-surface"', 1, true))
    assert.truthy(html:find('id="api-surface-2"', 1, true))
    assert.truthy(html:find("<table><thead>", 1, true))
    assert.truthy(html:find("<td>Stories</td>", 1, true))
  end)

  it("keeps a leading Lua example as code unless setup is explicit", function()
    local result = markdown.compile("~~~lua\nprint('example')\n~~~\n", { filename = "example.mdx" })
    assert.truthy(result.code:find('H.h%(HydroniumMdPre'))
    assert.falsy(result.code:find("\nprint%('example'%)"))
  end)
end)
