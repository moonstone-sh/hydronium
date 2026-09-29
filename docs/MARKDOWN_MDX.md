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
`docs/Intro.mdx`. The compiler does not yet implement all CommonMark/MDX
syntax, such as nested lists, multiline component blocks, arbitrary
HTML, JavaScript imports, or JSX expressions. `.mdx` uses **Lua and LUAX**, not
JavaScript.

App builds, browser source inventory, and Lab story discovery still need to
register these extensions. That wiring belongs to the build/source pipeline;
it should use the same `markdown.compile` or `loader.source` entry point rather
than introducing a second Markdown parser.
