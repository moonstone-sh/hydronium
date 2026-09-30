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

  local function html(source, filename, props)
    local result = markdown.compile(source, { filename = filename or "doc.md" })
    local component = (loadstring or load)(result.code, "@" .. (filename or "doc.md"))()
    local H = require("hydronium")
    local out = require("hydronium_dom.server").renderToString(H.h(component, props))
    return (out:gsub("<!%-%-hy:t%-%->", "")), result
  end

  it("follows CommonMark block structure", function()
    assert.truthy(html("Intro\n## Section\n"):find("<p>Intro</p><h2 id=\"section\">Section</h2>", 1, true))
    assert.truthy(html("Title\n=====\n\nSub\n---\n"):find('<h1 id="title">Title</h1><h2 id="sub">Sub</h2>', 1, true))
    assert.truthy(html("- a\n  - b\n- c\n"):find("<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>", 1, true))
    assert.truthy(html("1. one\n2. two\n\n3) x\n"):find('<ol><li>one</li><li>two</li></ol><ol start="3"><li>x</li></ol>', 1, true))
    assert.truthy(html("- a\n\n- b\n"):find("<li><p>a</p></li><li><p>b</p></li>", 1, true))
    assert.truthy(html("> quote\ncontinued\n"):find("<blockquote><p>quote continued</p></blockquote>", 1, true))
    assert.truthy(html("para\n\n    code\n"):find("<pre><code>code</code></pre>", 1, true))
    assert.truthy(html("one  \ntwo\\\nthree\n"):find("one<br>two<br>three", 1, true))
  end)

  it("follows CommonMark inline rules", function()
    local out = html("[**b** l](https://x.y \"T\") _u_ \\*e\\* ~~d~~ ***s*** snake_case_word &copy;\n")
    assert.truthy(out:find('<a href="https://x.y" title="T"><strong>b</strong> l</a>', 1, true))
    assert.truthy(out:find("<em>u</em> *e* <del>d</del> <em><strong>s</strong></em> snake_case_word \194\169", 1, true))
    local refs = html("[docs][d], [d] and <https://a.b>.\n\n[d]: https://docs.test\n")
    assert.truthy(refs:find('<a href="https://docs.test">docs</a>, <a href="https://docs.test">d</a>', 1, true))
    assert.truthy(refs:find('<a href="https://a.b">https://a.b</a>', 1, true))
  end)

  it("exposes frontmatter as meta and headings as toc", function()
    local _, result = html("---\ntitle: Hi\ntags: [a, b]\ndraft: false\nauthors:\n  - Ada\n---\n# Doc\n## Part *one*\n")
    assert.equal(result.meta.title, "Hi")
    assert.equal(result.meta.tags[2], "b")
    assert.equal(result.meta.draft, false)
    assert.equal(result.meta.authors[1], "Ada")
    assert.equal(#result.toc, 2)
    assert.equal(result.toc[2].id, "part-one")
    assert.equal(result.toc[2].text, "Part one")
    assert.equal(result.toc[2].line, 9)
  end)

  it("evaluates mdx expressions and multi-line or inline components", function()
    package.preload.MarkdownSpecCard = function()
      local H = require("hydronium")
      return function(p) return H.h("span", nil, p.title) end
    end
    local out = html([[```lua setup
local Card = require("MarkdownSpecCard")
```

Hello {props.name}!

<Card
  title={"block"}
/>

Inline <Card title="inline" /> too.
]], "doc.mdx", { name = "Ada" })
    assert.truthy(out:find("<p>Hello Ada!</p><span>block</span><p>Inline <span>inline</span> too.</p>", 1, true))
    assert.truthy(html("Literal {braces}\n"):find("Literal {braces}", 1, true))
  end)

  it("reports mdx mistakes at the Markdown line", function()
    local ok, err = pcall(markdown.compile, "# T\n```lua setup\nlocal X = 1\n```\n", { filename = "a.mdx" })
    assert.falsy(ok)
    assert.truthy(tostring(err):find("line 2: a `lua setup` fence must come before", 1, true))
    ok, err = pcall(markdown.compile, "ok\n\n<Card x={1 +} />\n", { filename = "a.mdx" })
    assert.falsy(ok)
    assert.truthy(tostring(err):find("line 3:", 1, true))
  end)

  it("keeps generated LUAX line-aligned and maps back to the Markdown source", function()
    local source = "---\nt: x\n---\n# Head\n\n- item {props.a}\n\nPara {props.b}\n"
    local result = markdown.compile(source, { filename = "a.mdx" })
    local lines = {}
    for line in (result.generated_luax .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    assert.truthy(lines[6]:find("props.a", 1, true))
    assert.truthy(lines[8]:find("props.b", 1, true))
    assert.truthy(result.map_json:find('"file": "a.lua"', 1, true))
    assert.truthy(result.map_json:find("Para {props.b}", 1, true))
  end)

  it("routes every dialect through one dispatcher", function()
    local dialects = require("hydronium_luax.dialects")
    assert.equal(dialects.of("a/B.luax"), "luax")
    assert.equal(dialects.of("mdx"), "markdown")
    assert.equal(dialects.of(".md"), "markdown")
    assert.equal(dialects.of("x.lua"), nil)
    assert.truthy(dialects.compile("# Hi\n", { filename = "x.md" }).code:find("HydroniumMdH1", 1, true))
    assert.truthy(dialects.compile("return <div />", { filename = "x.luax" }).code)
  end)
end)
