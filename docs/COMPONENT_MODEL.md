# Hydronium Component Model

## 1. Component Paradigms

Hydronium supports two complementary component authoring paradigms: **Pure Functional Components** and **Closure (Setup-Once / Render-Many) Components**.

### 1.1 Pure Functional Components
The simplest component is a stateless Lua function that accepts `props` and returns a Virtual DOM element (`VNode`).

```lua
local H = require("hydronium")

local function StatusBadge(props)
  local badgeClass = props.active and "badge-active" or "badge-inactive"
  return H.h("span", { class = badgeClass }, props.label)
end
```

Every time `StatusBadge` re-renders (due to parent updates or external triggers), the function body executes from top to bottom.

### 1.2 Closure Components (Setup-Once, Render-Many)
For components with internal state, Hydronium supports the **Closure Component** pattern. If the initial invocation of a component returns a function, Hydronium treats the outer function as a **Setup Phase** and the returned inner function as the **Render Function**.

```lua
local function Counter(props)
  -- 1. SETUP PHASE: Executes exactly once on initial mount
  local count, setCount = H.createSignal(props.initial or 0)

  H.createEffect(function()
    print("Counter updated to: " .. count())
  end)

  H.onCleanup(function()
    print("Counter unmounted, releasing resources")
  end)

  -- 2. RENDER FUNCTION: Executes on initial mount and on every reactive change
  return function(currentProps)
    return H.h("div", { class = "counter" },
      H.h("span", nil, "Count: " .. count()),
      H.h("button", { onClick = function() setCount(count() + 1) end }, "Increment")
    )
  end
end
```

#### Advantages of Closure Components
- **Zero Hook Rules**: State primitives like `createSignal` and `createEffect` run naturally in the lexical closure during setup. There are no restrictions on loops or conditions in the setup body.
- **Garbage Collection Efficiency**: Signals and effects are instantiated once, avoiding closure allocations on every render pass.

---

## 2. Props & Child Normalization

### 2.1 The Props Contract
- Props are passed as a Lua table to the component.
- Special reserved props:
  - `key`: Used by the Reconciler to identify items across array diffs. Extracted onto `vnode.key` and stripped from element props.
  - `ref`: Used to capture the underlying host instance. Extracted onto `vnode.ref` and stripped from props **for ELEMENT vnodes only** — on every other kind (COMPONENT, BOUNDARY, FRAGMENT, SUSPENSE, ISLAND, SCRIPT) it stays in `props.ref` as an ordinary prop instead (see §5.3).
  - `children`: Contains normalized child VNodes if passed via the props table instead of varargs.
- **Immutability**: User code should treat `props` as read-only. Hydronium protects props tables from accidental runtime mutations.

### 2.2 Varargs Safety & Child Normalization (Amendment 1)
Hydronium strictly complies with Lua 5.1-5.4 / LuaJIT compatibility rules:
1. **Vararg Processing with `select("#", ...)`**:
   Lua tables with `nil` entries contain gaps that break the `#` length operator. Hydronium inspects varargs using `select("#", ...)` to ensure that `nil` arguments do not truncate sibling arguments.
2. **Dropping Non-Renderables**:
   `nil`, `false`, and `true` are safely discarded. This enables idiomatic conditional rendering:
   ```lua
   H.h("div", nil,
     isLoggedIn() and H.h(UserAvatar),
     isAdmin() and H.h(AdminPanel)
   )
   ```
3. **Automatic Number Conversion**:
   Numbers are converted to strings (`tostring(num)`) and wrapped in Text VNodes.
4. **Recursive Array Flattening**:
   Nested tables returned by mapping operations are flattened into a contiguous 1-indexed array:
   ```lua
   local items = { "Item 1", { "Item 2", "Item 3" } }
   H.h("ul", nil, items) -- Normalized to 3 contiguous li/text children
   ```

---

## 3. Scopes & Lifecycles

Every component instance is bound to an active `Scope`:
- **Owner Scope**: When a component is mounted, a child scope is created under its parent component's scope.
- **Cleanup Registration**: Cleanups registered inside the component setup via `scope:defer(fn)` or `H.onCleanup(fn)` are attached to this scope.
- **LIFO Teardown**: When a component is removed during reconciliation, its scope is disposed in Last-In, First-Out (LIFO) order.
- **Resilient Execution (Amendment 2)**: Every cleanup callback runs inside a protected `pcall`. If a cleanup callback fails, the error is recorded, and remaining cleanups continue executing.

---

## 4. Context System (`hydronium.core.context`)

The Context API allows passing data through the component tree without passing props down through intermediate components:

```lua
-- 1. Create Context with default value
local ThemeContext = H.createContext("light")

-- 2. Provide Context value at root or ancestor level
local function App()
  return H.h(ThemeContext.Provider, { value = "dark" },
    H.h(Header),
    H.h(MainContent)
  )
end

-- 3. Consume Context value anywhere in subtree
local function Header()
  local theme = H.useContext(ThemeContext)
  return H.h("header", { class = "theme-" .. theme }, "Application Header")
end
```

Context inheritance uses Lua metatable inheritance (`__index = parentContext`), providing $O(1)$ lexical lookup without copying tables down the hierarchy.

---

## 5. Refs System (`hydronium.core.ref`)

Refs provide direct access to host instances (e.g. TestNodes, DOM elements, or game engine scene nodes):

### 5.1 Object Refs
```lua
local myInputRef = H.createRef()

local function Form()
  return H.h("input", { ref = myInputRef, type = "text" })
end

-- After render/commit:
-- myInputRef.current points to the host node.
-- On unmount:
-- myInputRef.current is cleared to nil.
```

### 5.2 Callback Refs
```lua
local function CanvasComponent()
  return H.h("canvas", {
    ref = function(node)
      if node then
        print("Canvas mounted:", node)
      else
        print("Canvas unmounted")
      end
    end
  })
end
```

### 5.3 Refs on components — no `forwardRef`

`ref` is only extracted onto `vnode.ref` for **ELEMENT** vnodes, since
that is the only kind that produces a single real host node for the
reconciler to bind to (see `docs/RECONCILIATION.md` §7). A component or
ErrorBoundary has no such single node — its render may produce zero, one,
or many host nodes, or a fragment — so `ref` passed to a component is
left as an ordinary prop, `props.ref`, instead of being auto-forwarded.
There is no `forwardRef` wrapper API; the component author forwards it
explicitly:

```lua
local function Fancy(props)
  return H.h("button", { ref = props.ref }, "click")
end

-- caller:
H.h(Fancy, { ref = myRef })
```

This also covers the `useImperativeHandle` use case with no separate
API — assign a synthesized handle instead of a real host node:

```lua
local function VideoPlayer(props)
  if props.ref then
    props.ref.current = { play = function() ... end, pause = function() ... end }
  end
  return H.h("video", nil)
end
```

A component that never reads `props.ref` simply has an unused prop, not
a silently dropped ref.

FRAGMENT, SUSPENSE, ISLAND and SCRIPT vnodes keep `props.ref` the same
way, but with a caveat worth stating plainly: no framework code consumes
it for those kinds, and unlike a component there is no author-written
body that could. A ref on one of them is **inert** — preserved and
inspectable, never assigned. See `docs/RECONCILIATION.md` §7 for the
correction note on what earlier revisions of these docs got wrong here.

---

## 6. Resilient Error Boundaries (`ErrorBoundary`)

Hydronium provides declarative error handling via the `ErrorBoundary` component:

```lua
local function SafeApp()
  return H.h(H.ErrorBoundary, {
    fallback = function(err, retry)
      return H.h("div", { class = "error-screen" },
        H.h("h2", nil, "Something went wrong"),
        H.h("p", nil, tostring(err.message or err)),
        H.h("button", { onClick = retry }, "Try Again")
      )
    end,
    onError = function(err)
      logToTelemetry(err)
    end
  },
    H.h(UnstableFeature)
  )
end
```

### Error Boundary Invariants (Amendment 2)
1. **Setup & Render Interception**: Catches errors in both setup and render phases of child components.
2. **Fallback Cascading**: If an `ErrorBoundary`'s fallback function throws an error, the error bubbles to the nearest enclosing parent `ErrorBoundary`.
3. **Transactional State**: The `retry` callback resets the boundary error state and safely re-attempts rendering.

---

## 7. Suspense & Resources (`H.Suspense`, `H.resource`)

A `Resource` has exactly three states — `pending`, `ready`, `failed` —
which are never conflated. A **failed** resource is an `ErrorBoundary`
concern, not a Suspense one; Suspense is only about *"can this subtree
render right now, and what shows while it can't"*.

```lua
local res = H.resource()               -- pending, no loader

local function Profile()
  return H.h("p", nil, res:get())      -- suspends while pending
end

H.h(H.Suspense, { fallback = H.h("p", nil, "loading...") }, H.h(Profile))
--> "<p>loading...</p>"
```

### 7.1 How a suspension travels

`Resource:get()` on a pending resource signals suspension with a tagged
table (recognized by `resource.isSuspension`) in one of two ways:

| Context | Mechanism |
| --- | --- |
| Inside a coroutine a Suspense boundary is **actively driving** | `coroutine.yield` — freezes the stack so it can be resumed in place |
| **Everywhere else** — the main thread, *or any other coroutine* | `error()` — catchable, exactly as v1 always did |

The second row is deliberately narrower than "am I in a coroutine".
`coroutine.isyieldable()` is true inside *any* coroutine, including ones
this framework knows nothing about — a per-request-coroutine server, a
generator in user code, a test harness. Yielding there would send the
suspension past the caller's own `pcall` (a yield crosses a resumable
`pcall` rather than being caught by it) to a driver with no idea what it
is, leaving that coroutine suspended forever with no diagnostic. So a
suspension is only ever yielded to a driver that explicitly registered
for it via `resource.markDriven(co)`; everyone else keeps the v1
catchable-error contract.

> **Fixed 2026-09-09.** The gate was previously `coroutine.isyieldable()`
> alone, which regressed any coroutine-hosted renderer from "catchable
> error" to "silent permanent hang".

### 7.2 `onSuspend` — synchronous resume-in-place

`Suspense` accepts an optional `onSuspend(resource)` prop, called
**synchronously** the moment a suspension is caught, *before* the boundary
commits to its fallback:

```lua
H.h(H.Suspense, {
  fallback = H.h("p", nil, "loading..."),
  onSuspend = function(r)
    r:resolve(cache:lookup())          -- must resolve DURING this call
  end,
}, H.h(Profile))
--> "<p>hello</p>"   -- no fallback ever shown
```

If the handler resolves (or rejects) the resource during that call, the
suspended subtree resumes **exactly where `Resource:get()` yielded**, with
already-buffered sibling output preserved rather than recomputed, and no
fallback is rendered at all. This is what the coroutine buys over v1's
`error()`, which destroyed the continuation.

With no `onSuspend`, behavior is identical to v1 at zero extra cost.

### 7.3 Limits — the boundary closes once it falls back

If the resource is **still pending** when `onSuspend` returns, the
fallback is committed and **that boundary is closed**. A resolve arriving
later cannot contribute output, because SSR writes a sequential stream:
once the fallback bytes are written, the position where the real content
belonged is gone.

Such a late resolve is a **reported no-op** — never a second write, never
silently dropped. It is reported through the suspense diagnostic channel:

```lua
local resource = require("hydronium.core.resource")

resource.setSuspenseDiagnosticHandler(function(diag)
  log.warn(diag.code, diag.message)     -- "suspense.late_resolve", ...
end)
-- nil restores the default (one line to stderr); false silences.
```

`diag.after_render` distinguishes *"the owning render was still running"*
from *"it had already returned its string to the caller"*.

So `onSuspend` is a hook for a **synchronously satisfiable** source — a
warm cache, a preloaded batch — not a general async escape hatch. True
out-of-order streaming (placeholder plus later replacement) is separate,
larger work at the meteorite integration layer and is not implemented.

> **Fixed 2026-09-09.** A late resolve previously resumed the coroutine
> anyway, flushing its buffer into the still-live sink so the output
> contained **both** the fallback and the real content, the latter landing
> wherever in tree order the resolve happened to occur.

### 7.4 Errors and ErrorBoundary reachability

`Resource:resolve()` / `:reject()` are plain data setters and **never**
raise a subtree's render error. Concretely:

- A render error on the **synchronous** resume path propagates normally to
  the nearest enclosing `ErrorBoundary`.
- An `ErrorBoundary` **inside** the Suspense subtree sits on the
  coroutine's own frozen stack, so it still catches errors raised after a
  resume.
- An `ErrorBoundary` **outside** an already-fallen-back Suspense is
  unreachable — not by choice, but because it has already produced its
  own output and returned.

Waiters are each invoked under `pcall`, so one failing waiter can neither
escape `resolve()` nor prevent its siblings from running; failures are
reported as `suspense.waiter_error`.

> **Fixed 2026-09-09.** A render error after a deferred resume used to
> propagate out of `Resource:resolve()` at the *resolver's* call site —
> arbitrary application code, nowhere near the boundary that should have
> handled it. Waiters were also invoked unprotected, and `_waiters` is
> cleared before iterating, so the first waiter to throw permanently
> stranded every later one.

### 7.5 PUC Lua 5.1

5.1 has no `coroutine.isyieldable`, so suspensions there always take the
`error()` path and resume-in-place is unavailable. This is a real
compatibility boundary, not a bug: 5.1 callers get exactly v1 behavior
(discard and show the fallback).
