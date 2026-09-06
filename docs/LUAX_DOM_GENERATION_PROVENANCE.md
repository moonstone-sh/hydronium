# LUAX DOM Typing Provenance & Upstream Specification

## 1. Upstream Data Source & Provenance
Hydronium's DOM type definitions are derived directly from authoritative web standards bodies:
- **WHATWG HTML Living Standard** (https://html.spec.whatwg.org)
- **W3C DOM Level 4 & UI Events Specification** (https://www.w3.org/TR/uievents)
- **MDN WebRef Machine-Readable Metadata** (`@webref/elements`, `@webref/idl`)
- **ARIA 1.2 Specification** (W3C Accessible Rich Internet Applications)

### Licensing & Upstream Rights
- **W3C Software and Document Notice and License**: Permissive attribution license permitting redistribution and generation of derivative typing stubs.
- **MDN WebDocs Content**: CC0 1.0 Universal Public Domain Dedication.
- **Hydronium Code Generator**: MIT License.

---

## 2. Generation Toolchain Architecture

The generation pipeline is implemented in [`tools/dom_generator/init.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/tools/dom_generator/init.lua) and [`src/hydronium/luax/dom_typing.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/src/hydronium/luax/dom_typing.lua):

```
[ W3C / WHATWG WebRef Specifications ]
                   |
                   v
     [ tools/dom_generator/init.lua ]
                   |
     +-------------+-------------+
     |                           |
     v                           v
[ Element Catalog ]       [ Event Hierarchy ]
- 115 HTML5 Elements      - SyntheticEvent<T>
- 64 SVG Elements         - SyntheticMouseEvent<T>
- 14 Void Elements        - SyntheticKeyboardEvent<T>
                          - SyntheticChangeEvent<T>
                   |
                   v
     [ EmmyLua Type Code Emitter ]
                   |
                   v
[ types/dom/intrinsics.d.lua & elements.d.lua ]
- Pure namespaced table: __luax_intrinsic
- ZERO top-level global element functions
```

---

## 3. Attribute Classification Hierarchy

To ensure high typing fidelity without type explosion, attributes are organized into an inheritance tree:

### A. Base `HTMLAttributes`
Available on all HTML elements:
- Core: `id`, `class`, `className`, `title`, `dir`, `lang`, `hidden`, `tabIndex`
- Inline Styles: `style` (table of camelCase CSS properties or string)
- Reactivity & Keys: `key`, `ref`, `children`
- Data & ARIA: `data-*`, `aria-*`, `role`
- Event Listeners:
  - Mouse: `onClick`, `onDoubleClick`, `onMouseDown`, `onMouseUp`, `onMouseEnter`, `onMouseLeave`
  - Keyboard: `onKeyDown`, `onKeyUp`, `onKeyPress`
  - Focus: `onFocus`, `onBlur`
  - Form: `onChange`, `onInput`, `onSubmit`, `onReset`

### B. Element-Specific Subtypes
Subtypes extend `HTMLAttributes` with specialized attributes:
- `HTMLButtonProps`: `type` ("button"|"submit"|"reset"), `disabled`, `form`, `formAction`
- `HTMLInputProps`: `type`, `value`, `checked`, `disabled`, `placeholder`, `required`, `readOnly`, `minLength`, `maxLength`, `pattern`, `autoFocus`
- `HTMLAnchorProps`: `href`, `target`, `rel`, `download`
- `HTMLImageProps`: `src`, `alt`, `width`, `height`, `loading`, `decoding`
- `HTMLFormProps`: `action`, `method`, `encType`, `target`, `noValidate`

### C. Synthetic Event Model
Event handlers in Hydronium receive typed `SyntheticEvent<T>` instances:
```lua
---@class SyntheticEvent<T>
---@field target T
---@field currentTarget T
---@field type string
---@field timeStamp number
---@field defaultPrevented boolean
---@field preventDefault fun()
---@field stopPropagation fun()

---@class SyntheticMouseEvent<T>: SyntheticEvent<T>
---@field clientX number
---@field clientY number
---@field button integer
---@field altKey boolean
---@field ctrlKey boolean
---@field shiftKey boolean
---@field metaKey boolean
```

---

## 4. Deterministic Regeneration Instructions

To regenerate all DOM type definitions from scratch:
```bash
luajit tools/dom_generator/init.lua --out types/dom/intrinsics.d.lua
```
Verification of generated definitions is enforced in the test runner via [`tests/luax/dom_typing_spec.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/tests/luax/dom_typing_spec.lua), ensuring that no future pull requests can accidentally re-introduce global pollution.
