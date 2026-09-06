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
  - `ref`: Used to capture the underlying host instance. Extracted onto `vnode.ref` and stripped from element props.
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
