# LUAX Real-World Usage Findings & DX Friction Audit

## 1. Context & Scope
To validate the `.luax` language design under real-world engineering conditions, a full exemplar application was built in [`examples/showcase/`](file:///Users/extrordinaire/Workbench/user/hydronium/examples/showcase), comprising 7 distinct component modules:
- [`Header.luax`](file:///Users/extrordinaire/Workbench/user/hydronium/examples/showcase/Header.luax): Responsive brand header & navigation.
- [`SVG.luax`](file:///Users/extrordinaire/Workbench/user/hydronium/examples/showcase/SVG.luax): Scalable vector graphics icon system.
- [`InteractiveIsland.luax`](file:///Users/extrordinaire/Workbench/user/hydronium/examples/showcase/InteractiveIsland.luax): Hydratable counter & island metadata.
- [`PackageBrowser.luax`](file:///Users/extrordinaire/Workbench/user/hydronium/examples/showcase/PackageBrowser.luax): Card grid with conditional badge rendering.
- [`Form.luax`](file:///Users/extrordinaire/Workbench/user/hydronium/examples/showcase/Form.luax): Form with inputs, selects, textareas, and validation.
- [`ErrorBoundary.luax`](file:///Users/extrordinaire/Workbench/user/hydronium/examples/showcase/ErrorBoundary.luax): Diagnostic capture & presentation wrapper.
- [`App.luax`](file:///Users/extrordinaire/Workbench/user/hydronium/examples/showcase/App.luax): Root composition and styling layout.

---

## 2. Key DX Friction Points & Implemented Remedies

### A. Lua Reserved Keyword Attribute Names (The `<label for="...">` Bug)
* **Finding**: HTML forms extensively use the `for` attribute on `<label for="element-id">`. In Lua 5.1/LuaJIT, `for` is a reserved grammar keyword. Emitting unbracketed `{ for = "element-id" }` causes an immediate fatal parser syntax error: `unexpected symbol near 'for'`.
* **Remedy**: Hardened [`CodeEmitter:emit_attr_table`](file:///Users/extrordinaire/Workbench/user/hydronium/src/hydronium/luax/compiler/init.lua#L379-L388) with a comprehensive `LUA_KEYWORDS` lookup table. Any attribute matching a Lua reserved keyword (`for`, `in`, `do`, `while`, `repeat`, `until`, `if`, `then`, `else`, `elseif`, `end`, `return`, `break`, `local`, `function`, `nil`, `false`, `true`, `and`, `or`, `not`, `goto`) is automatically emitted as a bracketed string literal: `["for"] = "element-id"`.

### B. LuaJIT Metatable Proxy Iteration
* **Finding**: In LuaJIT, `freezeProps(t)` returns a proxy table whose only actual key is `_store = t`. Standard Lua `pairs(proxy)` does not invoke `__pairs` unless special 5.2 compatibility flags are compiled into the LuaJIT host binary. This previously led to `{ _store = "table: 0x..." }` leaking into attribute serialization.
* **Remedy**: The SSR serializer explicitly unpacks `raw_props = (type(props) == "table" and props._store) or props`, and explicitly excludes `k == "_store"` from any attribute emission.

### C. Self-Closing Void Elements in JSX vs. HTML5
* **Finding**: Developers accustomed to React frequently write `<input />` or `<img />`. In `.luax`, self-closing syntax is accepted and parsed into a VNode without children. The compiler correctly preserves this AST structure, and the SSR renderer serializes it as strict HTML5 `<input>` (without trailing `/`), preserving HTML5 spec compliance while maintaining familiar JSX authoring ergonomics.

### D. Spread Operator Precedence (`{...props}`)
* **Finding**: Mixing static props and spreads in complex cards (e.g. `<article class="card" {...extra} id="override">`) requires strict left-to-right evaluation semantics so that trailing explicit props override spread properties.
* **Remedy**: Verified in [`tests/luax/spread_spec.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/tests/luax/spread_spec.lua) and showcase execution that `__luax.spread` chunks static tables and spread tables left-to-right, ensuring accurate attribute overwrites.

---

## 3. Autocompletion & Neovim Editor Experience

Observations when editing `.luax` files in Neovim with `lua-language-server` 3.18.2:
1. **Completion Triggering**: Typing `<` followed by element names triggers completion popups with documentation snippets for HTML5 elements.
2. **Contextual Callback Typing**: Inside `onClick={function(e) ... end}`, typing `e.` provides instant property completions (`target`, `preventDefault`, `clientX`, `clientY`).
3. **Syntax Highlighting**: Treesitter with standard JSX queries highlights `.luax` tags, attributes, and strings with vivid fidelity.
4. **Coordinate Diagnostics**: Errors placed inside embedded `{ ... }` blocks report the exact line and column of the error in the editor statusline.

---

## 4. Recommendations for Future Evolution

1. **Automatic Reactivity Wrapping**: Allow JSX text to bind directly to accessors: `<span>{count}</span>` without needing explicit `tostring(count())`. (Currently supported in SSR and reconciler, but recommended to document as canonical pattern).
2. **Short Fragment Shorthand `<> ... </>`**: Working smoothly; recommended to maintain as standard syntax.
3. **CSS Class Merge Helper**: Provide a built-in `cx(...)` or `classnames(...)` utility in `hydronium.util` to simplify conditional class lists like `class={active and "btn active" or "btn"}`.
