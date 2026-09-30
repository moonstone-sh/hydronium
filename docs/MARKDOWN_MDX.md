# Markdown and MDX in Hydronium

Markdown documents are **source modules**, like `.luax`: `require("docs.Guide")`
finds `docs/Guide.md` or `docs/Guide.mdx` and returns a Hydronium component.
They go through the same pipeline as every other module (Ballad compile step,
dev module route and hot updates, client manifest, Lab) with nothing
Markdown-specific to wire.

| File   | Is                                   | Code inside                               |
|--------|--------------------------------------|-------------------------------------------|
| `.md`  | plain CommonMark (+ GFM tables, `~~strike~~`) | none: reads the same on GitHub |
| `.mdx` | Markdown with Lua, as `.luax` is Lua with elements | `lua setup` fences, `{expr}`, LUAX components |

## `.md`

Headings (ATX and underlined), paragraphs, nested and loose lists, ordered
lists with a start number, blockquotes, fenced and indented code, thematic
breaks, tables with column alignment, hard line breaks, emphasis (`*`/`_`),
strong, strikethrough, code spans, inline and reference links, autolinks,
images, backslash escapes and HTML entities.

Headings get stable, deduplicated `id`s. Raw HTML is never passed through (it
renders as text), and links or images with a scheme other than `http`,
`https`, `mailto` or `tel` are dropped.

Frontmatter is read into `meta`:

```md
---
title: Getting started
tags: [intro, setup]
authors:
  - Ada
---
```

## `.mdx`

````mdx
```lua setup
local Counter = require("components.Counter")
```

# Hello {props.name}

This is **interactive** documentation: <Counter initial={2} /> inline, or as a block:

<Counter
  initial={props.start}
  step={2}
/>
````

- `lua setup` fences hold the module's requires and setup code. They must come
  before the content (the compiler reports the line otherwise). A plain
  `lua` fence is an ordinary code example.
- `{expr}` is a Lua expression, anywhere in prose. `props` is in scope. A
  paragraph that is only `{expr}` or only a component renders without a `<p>`.
- Component elements (`<Card …/>`, `<ui.Card>`, `<d.div>`) are LUAX. They may
  span several lines.

## The compiled module

`hydronium_luax.markdown.compile(source, { filename = "Guide.mdx" })` returns
the LUAX compiler's result (`code`, `sourcemap`, `map_json`) plus:

- `meta`: the frontmatter table (`{}` when there is none),
- `toc`: `{ { level, id, text, line } }` for every heading,
- `generated_luax`: the intermediate LUAX, for debugging.

The module itself returns a plain component function, the shape HMR families,
the router's lazy loader and Lab discovery recognize. Hosts replace any element
through the `components` prop: `{ p = MyParagraph, code = MyCodeBlock }` or an
intrinsic name, `{ p = "section" }`.

`hydronium_luax.compile_file(source, { filename = … })` picks the compiler by
extension (`hydronium_luax.dialects`); every tool uses it instead of matching
extensions itself.

The generated LUAX keeps each block on its Markdown line, so parse errors,
runtime errors and the source map (whose `sourcesContent` is the Markdown)
point at the document, not at an intermediate file.

## Editor support

The LUAX LuaLS plugin (`luax/src/hydronium_luax/luals/init.lua`) projects an
`.mdx` document to Lua: setup code, `{expr}` contents and components keep
their exact positions, and prose is blanked. Diagnostics, hover, completion
and go-to-definition work on the code parts, and `require` resolves `.luax`,
`.md` and `.mdx` modules. The project's `.luarc.json` needs:

```json
"files.associations": { "*.luax": "lua", "*.mdx": "lua" }
```

(`hydronium create` writes both.) In Neovim, `luax.nvim`'s `setup()` adds an
`mdx` filetype when nothing else provides one and highlights it with the
Markdown parser (which already injects Lua into `lua` fences). Add `"mdx"` to
`lua_ls`'s `filetypes` so the server attaches.

## Discovery

Lab discovers `.stories.md` and `.stories.mdx` as DOM stories; an ordinary
`.stories.lua`/`.stories.luax` can also import a document component.

Source roots only include Markdown when asked, so a `README.md` never becomes a
module by accident. Declare the transforms on the root that holds documents:

```lua
return {
  entry = "app.Document",
  roots = { { path = "src", transforms = {
    lua = "lua", luax = "luax", md = "md", mdx = "mdx",
  } } },
}
```
