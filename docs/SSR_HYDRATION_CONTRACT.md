# Hydronium SSR Hydration Contract & Islands Architecture

## 1. Core Principles
Hydronium adopts an **Islands of Interactivity** architecture for client hydration. In this model:
- The vast majority of a document (layouts, navigation, static articles, tables, footers) is rendered by the server into pure, non-reactive HTML with zero client JavaScript/Lua overhead.
- Isolated interactive components ("islands") are marked with semantic HTML attributes.
- On client load, the hydration runtime scans only for designated island elements, instantiates their reactive state, and attaches event listeners without re-rendering or traversing the surrounding static DOM.

---

## 2. Semantic Island Markers

Islands are demarcated in HTML using dedicated data attributes:

```html
<section
  class="island-container"
  data-island="package-counter"
  data-island-priority="visible"
  data-island-props='{"initialCount":42}'
>
  <button type="button" class="btn">-</button>
  <span class="count">42</span>
  <button type="button" class="btn">+</button>
</section>
```

### Supported Marker Attributes
1. `data-island="<IslandIdentifier>"`: Identifies the registered client component to mount.
2. `data-island-priority`: Defines hydration scheduling:
   - `immediate`: Hydrates synchronously during initial script bootstrap.
   - `idle` (default): Uses `requestIdleCallback` to defer hydration until the main browser thread is idle.
   - `visible`: Uses `IntersectionObserver` to hydrate only when the element enters the viewport.
   - `interaction`: Hydrates on the first user interaction event (e.g. `pointerenter`, `focusin`, `touchstart`).
3. `data-island-props`: Optional inline JSON containing component initialization properties.

---

## 3. State Transfer Protocol (`__HYDRONIUM_STATE__`)

When dynamic server data needs to be shared across islands or hydrated into client signals, the server renderer automatically injects a deterministic JSON payload:

```html
<script id="__HYDRONIUM_STATE__" type="application/json">
  {"initialCount":42,"user":{"id":1,"name":"Core Team"}}
</script>
```

### Security & Sanitization
The state serializer in [`src/hydronium/server/init.lua`](file:///Users/extrordinaire/Workbench/user/hydronium/src/hydronium/server/init.lua#L270-L310):
- Encodes strings safely, escaping quotes, newlines, and carriage returns.
- Sorts object keys alphabetically (`a-z`) for deterministic hashing and caching.
- Neutralizes `</script>` tags within string values to eliminate script tag breakout vulnerabilities.

### Client Bootstrapping Sequence
```lua
-- On client initialization:
local function hydrate_island(island_el)
  local island_name = island_el:getAttribute("data-island")
  local component = IslandRegistry[island_name]
  if not component then return end

  -- 1. Read global state
  local state_el = document:getElementById("__HYDRONIUM_STATE__")
  local state = state_el and json.decode(state_el.textContent) or {}

  -- 2. Read local island props
  local props_attr = island_el:getAttribute("data-island-props")
  local props = props_attr and json.decode(props_attr) or {}

  -- 3. Hydrate component onto existing DOM node
  Hydronium.hydrate(component, props, island_el)
end
```

---

## 4. DOM Structural Reconciliation & Mismatch Recovery

Hydration reconciles existing server DOM nodes against the newly rendered client VNode tree:

1. **Tag & Type Matching**: The runtime traverses children and checks that `hostNode.tagName:lower() == vnode.tag:lower()`.
2. **Event Listener Attachment**: Reactive callbacks (`onClick`, `onInput`) are bound directly to the existing DOM element without destroying or replacing the element.
3. **Text Node Fast-Path**: If the text content matches, no DOM mutation is performed.

### Mismatch Detection & Recovery Strategy
If server-rendered HTML and client VNode trees disagree (due to client-only state, locale differences, or clock skew):
- **Development Mode**: An explicit warning is logged to the console identifying the exact DOM path and mismatched values.
- **Production Recovery**:
  1. The client suppresses crashing.
  2. The reconciler discards the corrupted server DOM subtree for that specific island.
  3. The reconciler performs a clean client-side mount of the component inside the island container.
  4. The surrounding document remains intact with zero page flash or layout disruption.
