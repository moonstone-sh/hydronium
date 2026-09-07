# Hydronium Server-Side Rendering (SSR) Architecture

## 1. Overview & Protocol
The Hydronium Server-Side Rendering engine ([`src/hydronium/server/init.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/src/hydronium/server/init.lua) and [`src/hydronium/server/html.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/src/hydronium/server/html.lua)) transforms virtual DOM element and component trees into production-ready HTML strings or streaming chunk sequences.

It provides two primary entrypoints:
1. `server.render_to_string(vnode, options)` (alias: `server.renderToString`): Synchronously renders the tree into a single concatenated HTML string.
2. `server.render(vnode, sink, options)` (alias: `server.render_to_stream`, `server.renderToStream`): Streams chunks progressively into a sink object implementing `{ write = fun(chunk), flush = fun(), close = fun() }`.

---

## 2. Strict HTML5 Void Element Compliance

HTML5 Section 8.1.2 defines void elements as elements that cannot have child nodes and must never include an end tag or self-closing slash.

The **14 strict void elements** supported by Hydronium:
`area`, `base`, `br`, `col`, `embed`, `hr`, `img`, `input`, `link`, `meta`, `param`, `source`, `track`, `wbr`.

### Serialization Rules
1. **No Self-Closing Slash**: Rendered strictly as `<input type="text" name="q">` (NOT `<input ... />`). Self-closing slashes are obsolete syntax from XHTML.
2. **Strict Child Prohibition**: If any children (text, VNodes, fragments, arrays) are provided to a void element, the server renderer immediately throws an explicit error:
   ```
   Void element <input> cannot have children
   ```
3. **Non-Void Elements Always Closed**: Non-void elements (such as `<div>`, `<span>`, `<textarea>`, `<script>`) always emit full opening and closing tags even when completely empty: `<div></div>`.

---

## 3. Attribute Serialization Rules

Attributes are deterministically sorted alphabetically (`a-z`) so that HTML emitted across server instances and requests is bit-for-bit identical regardless of Lua hash table internal iteration order.

### A. Boolean vs. ARIA Attributes
- **HTML Boolean Attributes** (`disabled`, `checked`, `readonly`, `required`, `autofocus`, `multiple`, `open`, `novalidate`, `playsinline`, etc.):
  - Truthy (`true` or matching string): Emits only attribute name: `<button disabled>` or `<input checked>`.
  - Falsy (`false` or `nil`): Completely omitted from HTML output.
- **ARIA & Data Attributes** (`aria-*`, `data-*`):
  - In ARIA specifications, `aria-hidden="false"` carries semantic meaning distinct from attribute absence.
  - Boolean `false` is serialized explicitly: `<span aria-hidden="false" aria-expanded="false">`.
  - Boolean `true` is serialized as: `<span aria-hidden="true">`.

### B. CSS Style Serialization
When `style` is passed as a table (e.g. `style={{ backgroundColor = "red", fontSize = 14 }}`):
1. **camelCase to kebab-case**: Property names are converted (`backgroundColor` -> `background-color`).
2. **Deterministic Sort**: CSS properties are sorted alphabetically (`a-z`).
3. **Unitless Property Preservation**: Dimensions append `"px"` by default (`fontSize = 14` -> `font-size: 14px`), except for standard unitless properties (`opacity`, `zIndex`, `lineHeight`, `flex`, `flexGrow`, `flexShrink`, `order`, `fontWeight`, `zoom`, `strokeOpacity`, etc.).
4. **Escaping**: The resulting style string is safely escaped against quote injections.

---

## 4. Escaping Order & XSS Prevention

Hydronium implements multi-layer defense-in-depth sanitization:
1. **Escaping Order**: The ampersand `&` MUST be escaped first, followed by `< `, `>`, `"`, and `'`:
   ```lua
   str = str:gsub("&", "&amp;")
            :gsub("<", "&lt;")
            :gsub(">", "&gt;")
            :gsub('"', "&quot;")
            :gsub("'", "&#39;")
   ```
2. **Script & Style Breakout Prevention**: Text children inside `<script>` and `<style>` elements are treated as raw text (not HTML escaped), but sanitized to neutralize breakout injection attacks:
   - `<script>` content: Any closing tag variant (`</script>`, `</Script>`) is replaced with `<\/script>`.
   - `<style>` content: Any closing tag variant (`</style>`, `</Style>`) is replaced with `<\/style>`.
3. **Raw HTML (`unsafe_raw_html` / `dangerouslySetInnerHTML`)**:
   - Injected directly into element contents without escaping.
   - Throws an immediate runtime error if children and raw HTML are provided simultaneously on the same element.

---

## 5. Reactivity & Effect Suppression during SSR

Server-side rendering is an instantaneous, one-shot computation. Establishing long-lived subscriptions and queuing DOM effects on the server leads to severe memory leaks and concurrency race conditions.

Hydronium enforces strict effect suppression during SSR:
- `scheduler.setSSR(true)` is activated at render start and restored in a guaranteed `finally` block.
- `createEffect(fn)`: Checked against `scheduler.isSSR()`. When true, the effect is **suppressed entirely** and never scheduled or executed.
- `createSignal` and `createComputed`: Evaluated synchronously to extract their current value without attaching observers.
- `scheduler.scheduleRender` and `scheduler.queueEffect`: Suppressed during SSR.

## 5.1 State transfer and sink ownership

`server.encode_state` accepts only acyclic JSON values. Object keys are sorted,
arrays must be contiguous positive-integer sequences, and unsupported values
(including functions, userdata, `NaN`, infinity, cycles, and mixed tables)
fail rather than being coerced. State strings escape `<`, `>`, and `&` as JSON
unicode escapes, so serialized state cannot terminate the
`application/json` script element.

`server.render` accepts either `fun(chunk)` or a sink object with
`write(self, chunk)` and optional `flush`/`close`. The renderer owns exactly
one close attempt after its render transaction, including write failure. It is
synchronous: sinks and components must not yield or retain a render scope.

---

## 6. ErrorBoundary & Resilient State Cleanup

If an unhandled error occurs during server rendering, the engine guarantees complete resource isolation:

```
                      server.render_to_string(vnode)
                                    |
                 +------------------+------------------+
                 | Save Context Stack & Scope Depth    |
                 | Set scheduler.setSSR(true)          |
                 +------------------+------------------+
                                    |
                            [ render_node ]
                                    |
                    +---------------+---------------+
                    |                               |
              [ Normal Node ]              [ ErrorBoundary ]
                    |                               |
                    v                         pcall(children)
              (Emits HTML)                          |
                                       +------------+------------+
                                       |                         |
                                   (Success)                  (Error)
                                       |                         |
                                 (Emits HTML)            pcall(fallback, err)
                                                                 |
                                                           (Emits Fallback)
                                    |
                 +------------------+------------------+
                 | FINALLY (Guaranteed via pcall):     |
                 | - Dispose root Scope                |
                 | - Reset ScopeStack to initial depth |
                 | - Reset ContextStack & ContextMap   |
                 | - Restore scheduler.setSSR(prev)    |
                 +-------------------------------------+
```

Even if a catastrophic component failure occurs outside an `ErrorBoundary`, the `finally` block guarantees that the `Scope` stack, `Context` map, and SSR scheduler flag are completely restored to their pre-request state, preventing thread-local state pollution in pooled Lua environments.
