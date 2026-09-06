# Hydronium .luax Developer Experience (DX) Architecture

## 1. Architectural Mission & Tenets

The Hydronium `.luax` developer experience architecture provides standard, idiomatic JSX-like authoring for Lua while guaranteeing:
1. **Zero Global Pollution**: The host global environment `_G` remains pristine. No magic global variables (`__luax_intrinsic`, `div`, `button`) contaminate the user's runtime.
2. **1:1 Language Server Coordinate Stability**: Diagnostics, autocomplete completions, go-to-definition targets, and hover tooltips map without column or line drift.
3. **Lexical Intrinsic Descriptors**: Intrinsic tags (`d.button`, `d.input`) are real, typed Lua objects in lexical scope (`require("hydronium.dom").d`).
4. **Decoupled Runtime Target**: Compiles cleanly to factory calls (`H.h`), direct callable calls (`d.button`), or universal calls (`__luax.element`), without hardcoding host assumptions.
5. **Universal Tooling Support**: Native editor support across Neovim, VS Code, Tree-sitter, TextMate, and LuaLS.

---

## 2. Multi-Tier System Diagram

```mermaid
graph TD
    subgraph Layer1 [1. Authoring Layer (.luax)]
        SRC["User .luax File\n<d.button id='save' onClick={handleSave}>Save</d.button>"]
    end

    subgraph Layer2 [2. Editor Layer]
        TS["Tree-sitter Parser\n(CST Nodes: element_expression, tag_expression)"]
        TM["TextMate Grammar\n(Scopes: entity.name.tag, meta.tag.open.dotted)"]
        NVIM["Neovim Plugin (extra/nvim)\n(:checkhealth, :HydroniumFormat)"]
    end

    subgraph Layer3 [3. Language Server Virtual Layer]
        VIRTUAL["1:1 Byte-Aligned Lowerer\n(' d.button{id = \"save\", onClick = (handleSave), \"Save\"}          ')"]
        TYPES["LuaCATS Types\n(hydronium.Intrinsic<HTMLButtonProps, HTMLButtonElement>)"]
        LUALS["Lua Language Server (LuaLS)\nType-checks Props, Inferred Event Callbacks"]
    end

    subgraph Layer4 [4. Compiler Layer]
        COMP["Compiler (bin/luax / compiler/init.lua)\nEmits H.h(d.button, { id = 'save', onClick = handleSave }, 'Save')"]
    end

    subgraph Layer5 [5. Runtime & Normalization Layer]
        NORM["Core Normalizer (element.lua, server/init.lua, reconciler.lua)\nUnwraps d.button.$$typeof == symbols.INTRINSIC -> 'button'"]
        DOM["DOM Host (createInstance('button'))"]
        SSR["Server Host (<button id='save'>Save</button>)"]
    end

    SRC --> TS & TM & VIRTUAL & COMP
    TS & TM --> NVIM
    VIRTUAL --> LUALS
    TYPES --> LUALS
    COMP --> NORM
    NORM --> DOM & SSR
```

---

## 3. Coordinate Preservation & Virtual Lowering Mechanics

LuaLS operates directly on Lua abstract syntax trees. To avoid requiring a customized C++ LuaLS fork, Hydronium synthesizes a **Virtual Source** in the `OnSetText` hook:

### Byte-Aligned Transformation Rules
Every JSX delimiter is replaced with an equal number of ASCII characters or spaces:

| Original `.luax` Snippet | Byte Count | Lowered Virtual Lua Snippet | Byte Count | Invariant |
| :--- | :--- | :--- | :--- | :--- |
| `<d.button ` | 10 bytes | ` d.button{` | 10 bytes | Leading `<` replaced by space; trailing space replaced by `{` |
| `<d.input />` | 11 bytes | ` d.input{ }` | 11 bytes | Self-closing slash and angle bracket become `{ }` |
| `</d.button>` | 11 bytes | `}          ` | 11 bytes | Leading `</` becomes `}`; trailing characters padded with spaces |
| `onClick={fn}` | 13 bytes | `onClick=(fn)` | 13 bytes | `{` and `}` delimiters become `(` and `)` |
| `{...props}` | 10 bytes | ` ,   props ` | 10 bytes | Spread syntax masked as valid comma-separated expression |

Because every substitution preserves byte count, line breaks, and column offsets, any diagnostic produced by LuaLS points to the exact pixel-perfect character in the user's `.luax` editor view.

---

## 4. Decoupled Runtime Target Philosophy

Hydronium `.luax` distinguishes between **syntax** and **runtime execution**:

1. **Hydronium Factory Mode (`--runtime hydronium`)**:
   Compiles `<d.button id="btn" />` into `H.h(d.button, { id = "btn" })`. This enables central VNode allocation, key extraction, ref attachment, and dev-mode inspection.
2. **Direct Execution Mode (`--runtime direct`)**:
   Compiles `<d.button id="btn" />` into `d.button({ id = "btn" })`. This allows component templates to run directly as callable tables without requiring an `H` factory in scope.
3. **Universal Host Mode (`--runtime universal`)**:
   Compiles `<d.button id="btn" />` into `__luax.element(d.button, { id = "btn" })`. This is completely host-agnostic, suitable for third-party renderers (such as Starship UI or Love2D).
