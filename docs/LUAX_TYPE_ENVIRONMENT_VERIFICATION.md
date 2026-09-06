# LUAX Type Environment Verification & Global Isolation

## 1. Executive Summary
In prior design iterations of `.luax` typing definitions, DOM intrinsic elements were declared as global functions:
```lua
-- DEPRECATED & ERADICATED DANGEROUS PATTERN:
function button(props) end
function select(props) end
function table(props) end
local _ = { button = button, ... }
```
This naive approach severely broke Lua language ergonomics:
- Calling Lua's built-in `select(n, ...)` or `select("#", ...)` resolved to the DOM `<select>` tag function rather than the Lua standard library builtin.
- Referencing `table.insert` or `table.concat` conflicted with the HTML `<table>` tag.
- The global `_` alias polluted the canonical Lua throwaway variable convention (`for _, item in ipairs(list) do`).

This document verifies the total remediation and isolation of DOM types under a strictly namespaced architecture.

---

## 2. Four-Quadrant Type Isolation Matrix

The type system is segmented into four distinct execution environments to ensure zero cross-contamination:

| Quadrant | Environment | DOM Types Present? | Global Scope State | Type Signature Resolution |
| :--- | :--- | :--- | :--- | :--- |
| **Q1** | **Pure Lua (Standard)** | **NO** | 100% Standard Lua. `select`, `table`, `string`, `math` pristine. | Core Lua 5.1/LuaJIT EmmyLua annotations only. |
| **Q2** | **Pure Luax (DOM UI)** | **YES (Namespaced)** | Standard Lua globals remain intact. DOM accessed exclusively via `__luax_intrinsic.<tag>`. | EmmyLua parses `LuaxIntrinsics` table catalog. |
| **Q3** | **Mixed Lua + Luax** | **YES (Isolated)** | Standard Lua files in same project never see DOM types in global scope. | `.luax` files lowered via virtual buffer; `.lua` files untouched. |
| **Q4** | **Cross-Runtime Luax** | **Custom Factory** | Zero Hydronium globals injected. Custom pragma / runtime (`Starship.h`). | Virtual lowering adapts to target runtime factory without coupling. |

---

## 3. Global Isolation Proofs

### Proof A: Standard Built-in `select` is Unshadowed
```lua
-- In any .lua or .luax file:
local function test_select(...)
  local count = select("#", ...) -- Must resolve to Lua's select(), NOT HTML <select>
  local second = select(2, ...)
  return count, second
end

local n, val = test_select("alpha", "beta", "gamma")
assert(n == 3)
assert(val == "beta")
```
- **Type Checking**: LuaLS resolves `select` to `fun(index: integer|string, ...: any): any`.
- **Runtime Check**: Passes with zero collisions in [`tests/luax/virtual_source_spec.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/tests/luax/virtual_source_spec.lua#L80-L100).

### Proof B: Standard Built-in `table` is Unshadowed
```lua
local items = {}
table.insert(items, "first")
table.insert(items, "second")
local joined = table.concat(items, ", ")
assert(joined == "first, second")
```
- **Type Checking**: `table` resolves to standard Lua table library (`tablelib`). HTML `<table>` is isolated under `__luax_intrinsic.table`.

### Proof C: Eradication of Global `_` Alias
- In [`types/dom/intrinsics.d.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/types/dom/intrinsics.d.lua), all occurrences of `_ = __luax_intrinsic` have been removed.
- In [`tools/dom_generator/init.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/tools/dom_generator/init.lua), the generator no longer emits any top-level global declarations or aliases.
- Developers are free to use `local _ = ...` or `for _, v in ipairs(...)` without type linter warnings.

---

## 4. Structural Typing Architecture

DOM intrinsic types are declared in [`types/dom/intrinsics.d.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/types/dom/intrinsics.d.lua) using EmmyLua classes:

```lua
---@class LuaxIntrinsics
---@field button fun(props?: HTMLButtonProps, ...: any): VNode
---@field div fun(props?: HTMLDivProps, ...: any): VNode
---@field input fun(props?: HTMLInputProps, ...: any): VNode
---@field select fun(props?: HTMLSelectProps, ...: any): VNode
---@field table fun(props?: HTMLTableProps, ...: any): VNode
---... (115 HTML5 & SVG elements)

---@type LuaxIntrinsics
__luax_intrinsic = {}
```

### Component Lowering Signature
Custom components are wrapped with `__luax_component`:
```lua
---@generic P
---@param component fun(props: P): VNode
---@param props P
---@return VNode
function __luax_component(component, props, ...) end
```
This generic parameter typing ensures that passing incorrect props to custom components (e.g. missing required props or wrong prop types) is immediately highlighted as a diagnostic error by LuaLS.
