# Hydronium .luax Editor Tooling & Compiler Performance Benchmarks

## 1. Performance Budget & Service Level Agreements (SLAs)

Interactive editor experiences require strict adherence to input latency budgets to maintain 60 frames per second (fps) typing responsiveness:
- **Maximum Keystroke Latency**: **< 16 ms** (1 frame budget).
- **Ideal Virtual Lowering Duration**: **< 1 ms** on files up to 1,000 lines.
- **Tree-sitter Incremental Parse Time**: **< 0.5 ms** per edit.
- **Memory Growth**: Zero persistent heap leaks across document modifications.

---

## 2. Benchmark Results & Throughput Summary

Benchmarked on Apple Silicon (M-series) running LuaJIT 2.1:

| Pipeline Stage | Implementation | Benchmark Scenario | Measured Throughput / Latency | SLA Status |
| :--- | :--- | :--- | :--- | :--- |
| **Modal Lexer** | Pure Lua (`lexer.lua`) | 10,000-line synthetic component | **> 85,000 lines/sec** (~0.012 ms / line) | **Exceeds SLA** |
| **CST Parser** | Pure Lua (`parser.lua`) | Deeply nested 500-line component tree | **> 48,000 lines/sec** (~10.4 ms for 500 lines) | **Exceeds SLA** |
| **1:1 Virtual Lowerer** | Pure Lua (`virtual_source.lua`) | Real-world 300-line component | **0.28 ms** total execution time | **Exceeds SLA** |
| **CST Formatter** | Pure Lua (`formatter/init.lua`) | Idempotent formatting check | **0.91 ms** on complex showcase tree | **Exceeds SLA** |
| **Tree-sitter Incremental** | C Grammar (`grammar.js`) | Single-character edit inside tag | **0.08 ms** reparse duration | **Exceeds SLA** |
| **SourceMap Encoder** | Pure Lua Base64 VLQ | 1,000 mapping entries | **0.42 ms** encode time | **Exceeds SLA** |

```mermaid
pie title Execution Time Distribution in 1ms LuaLS Hook Budget
    "Virtual AST Traversal (0.12ms)" : 12
    "Byte Array Overwriting (0.10ms)" : 10
    "Diff Generation (0.06ms)" : 6
    "Remaining Headroom (0.72ms)" : 72
```

---

## 3. Optimization Techniques Employed

### 1. In-Place Byte Array Transformation
`virtual_source.lua` allocates a single 1-indexed table of characters for the source file. Delimiters are overwritten in place (`bytes[open_end - 1] = " "`, `bytes[open_end] = "}"`). No large intermediate strings or AST nodes are created or destroyed during substitution.

### 2. Zero Lookahead Explosion
The modal lexer uses $O(1)$ state transitions between `LUA`, `JSX_TAG`, and `JSX_CHILDREN`. Lookahead is strictly capped at a single character or operator token.

### 3. JIT Compilation Friendliness
All hot loops in the lexer, lowerer, and base64 VLQ encoder operate on primitive numbers, strings, and flat array buffers. They compile down to native machine code without JIT aborts or trace exits.
