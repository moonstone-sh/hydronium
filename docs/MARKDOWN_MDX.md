# Markdown and MDX in Hydronium

The LUAX package provides `hydronium_luax.markdown.compile(source, { filename = "Page.md" })`.
It returns the same compiled-result shape as `hydronium_luax.compile`, including
`code`. The result is a Lua module exporting an ordinary Hydronium DOM
component. `hydronium_luax.loader.load(path)` and `.source(path)` also accept
`.md` and `.mdx` files and cache by source content.

`.md` treats the document as prose. Current block support covers headings,
paragraphs, unordered and ordered lists, blockquotes, horizontal rules,
tables, and fenced code. Headings receive stable, deduplicated anchors.
Inline support covers emphasis, strong text, code, links, and images. Prose
is emitted as text nodes, so HTML-looking text cannot become active markup
accidentally.

`.mdx` adds a leading `lua setup` fence for local imports and setup code, followed
by standalone, single-line LUAX component elements. For example:

````mdx
```lua setup
local Counter = require("components.Counter")
```

# Try Hydronium

This is **interactive** documentation.

<Counter initial={2} />
````

The module exports a function component; `require("docs.Intro")` can be used
as a component after the ordinary loader finds `docs/Intro.md` or
`docs/Intro.mdx`. Hosts can override generated elements through a `components`
prop, for example `components = { p = MyParagraph, code = MyCodeBlock }`.
The map also accepts intrinsic tag names such as `{ p = "section" }`.
The compiler does not yet implement all CommonMark/MDX
syntax, such as nested lists, multiline component blocks, arbitrary
HTML, JavaScript imports, or JSX expressions. `.mdx` uses **Lua and LUAX**, not
JavaScript.

Lab discovers `.stories.md` and `.stories.mdx` as DOM stories. An ordinary
`.stories.lua` or `.stories.luax` file can also import a `.md` or `.mdx`
component; the DOM preview compiles its source and follows its LUAX imports.

The Ballad LUAX compile step emits `.md` and `.mdx` inputs as `hy_module` Lua
assets. The app development module route serves a declared Markdown module as
compiled Lua and uses that same code for hot updates. Source discovery and
inventory must include the extension before these paths can find new files;
that work is being completed in Hydronium's separate source-pipeline update.

Until automatic inventory includes Markdown, an app can declare files and
transforms explicitly in `hydronium.sources.lua`:

```lua
return {
  entry = "app.Document",
  roots = { { path = "src", transforms = {
    lua = "lua", luax = "luax", md = "md", mdx = "mdx",
  } } },
  files = { "src/app/Document.luax", "src/docs/Intro.mdx" },
}
```

`require("docs.Intro")` then loads the document component in an app. Lab's
story scan discovers `src/docs/Intro.stories.mdx` automatically under a
declared Lab root.
