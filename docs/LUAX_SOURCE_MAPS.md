# Hydronium .luax Source Maps Specification (v3)

## 1. Overview

Because `.luax` code compiles into standard `.lua` code, any runtime error, stack trace, or debugging breakpoint must map back accurately to the author's original `.luax` source file.

Hydronium implements full **Source Map v3** support written in pure standard Lua (`hydronium.luax.sourcemap` and `hydronium.luax.compiler.sourcemap`). The implementation features:
- **Base64 VLQ Encoder & Decoder**: Pure-Lua bitwise / arithmetic implementation compatible with Lua 5.1, LuaJIT, and Lua 5.2–5.4.
- **Bi-Directional Coordinate Lookup**: Fast mapping from generated line/column to original source line/column and vice versa.
- **Stack Trace Remapping**: Hooking `debug.traceback` to transparently rewrite compiled `.lua` lines back to `.luax` lines.
- **Detached & Inline Data URI Emission**: Full compatibility with browser devtools (Chrome, Firefox, Safari) and IDE debuggers (VSCode, Neovim).

---

## 2. Source Map v3 JSON Structure

Hydronium emits standard v3 JSON maps:

```json
{
  "version": 3,
  "file": "Button.lua",
  "sourceRoot": "",
  "sources": [
    "Button.luax"
  ],
  "sourcesContent": [
    "local function Button(props)\n    return <button class=\"btn\">{props.text}</button>\nend\nreturn Button"
  ],
  "names": [],
  "mappings": "AAAA,eAAe,CAAC,KAAK,CAAC;AACtB,IAAI,kBAAkB,CAAC,gBAAgB;AACvC;AACA"
}
```

### Format Fields:
- `version`: Always integer `3`.
- `file`: The name of the generated `.lua` file.
- `sources`: Array of relative or absolute paths to the original `.luax` source files.
- `sourcesContent`: Optional embedded copy of original source text, ensuring maps remain fully debuggable even when original files are not on the host filesystem.
- `names`: Array of original identifier names (optional).
- `mappings`: A semicolon-separated string of Base64 VLQ encoded segments representing mapped positions.

---

## 3. Base64 VLQ Algorithm in Pure Lua

Source map mappings compress coordinate deltas using **Variable-Length Quantities (VLQ)** encoded as Base64 characters (`A-Z`, `a-z`, `0-9`, `+`, `/`).

### 3.1 VLQ Segment Structure
Each mapping segment consists of 1, 4, or 5 variable-length values:
1. **Generated Column**: 0-based column offset in the generated line (delta from previous segment in the same line).
2. **Source Index**: 0-based index into `sources` array (delta from previous segment).
3. **Original Line**: 0-based line number in original file (delta from previous segment).
4. **Original Column**: 0-based column number in original file (delta from previous segment).
5. **Name Index**: (Optional) 0-based index into `names` array (delta from previous segment).

### 3.2 Pure Lua Implementation Strategy
Because Lua 5.1 and LuaJIT 2.0 lack standard bitwise operators (`&`, `|`, `>>`, `<<`), Hydronium's VLQ encoder uses standard integer arithmetic (`math.floor(val / 32)`, `val % 32`), ensuring 100% compatibility across all Lua runtimes without external C modules:

```lua
local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function sourcemap.encode_vlq(value)
    local vlq = value < 0 and ((-value * 2) + 1) or (value * 2)
    local result = {}
    repeat
        local digit = vlq % 32
        vlq = math.floor(vlq / 32)
        if vlq > 0 then
            digit = digit + 32 -- Continuation bit set
        end
        table.insert(result, CHARS:sub(digit + 1, digit + 1))
    until vlq == 0
    return table.concat(result)
end
```

---

## 4. Stack Trace Translation (Runtime Remapping)

When an error occurs in compiled Lua code, the callstack points to line numbers in the emitted `.lua` file. Hydronium provides a stack trace remapper (`hydronium.luax.sourcemap.remap_traceback`) that hooks into `debug.traceback` to restore original `.luax` file names and line numbers.

### 4.1 Traceback Hook Example

```lua
local sourcemap = require("hydronium.luax.sourcemap")

-- Load the source map for the compiled module
local map = sourcemap.load_file("dist/App.luax.map")

-- Install the global traceback hook
local old_traceback = debug.traceback
debug.traceback = function(thread_or_msg, msg_or_level, level)
    local raw_trace = old_traceback(thread_or_msg, msg_or_level, level)
    return sourcemap.remap_traceback(raw_trace, {
        ["dist/App.lua"] = map
    })
end
```

### 4.2 Before and After Translation

#### Unmapped Lua Traceback:
```
dist/App.lua:42: in function 'render'
dist/App.lua:118: in function 'mount'
main.lua:15: in main chunk
```

#### Remapped .luax Traceback:
```
src/App.luax:23 (mapped from dist/App.lua:42): in function 'render'
src/App.luax:65 (mapped from dist/App.lua:118): in function 'mount'
main.lua:15: in main chunk
```

---

## 5. IDE & Debugger Integration

### 5.1 VSCode (Local Lua Debugger)
In `.vscode/launch.json`:
```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug Hydronium App",
            "type": "lua-local",
            "request": "launch",
            "program": {
                "lua": "luajit",
                "file": "${workspaceFolder}/main.lua"
            },
            "sourceMaps": true,
            "sourceMapPathOverrides": {
                "dist/*.lua": "${workspaceFolder}/src/*.luax"
            }
        }
    ]
}
```

### 5.2 Chrome DevTools & Web Debugging
When compiling `.luax` to WebAssembly or Lua-in-browser engines (e.g. Fengari, Wasmer), emit inline source maps:
```bash
luax compile src/App.luax -o dist/App.lua --inline-source-map
```
The browser will automatically fetch the embedded base64 map, and breakpoints placed inside `<button>` or `{expr}` in `App.luax` will trigger seamlessly.
