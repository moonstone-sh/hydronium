--[[
  Hydronium Suspense (v1 -- SSR only, sequential/buffered)

  Answers "can this subtree render right now, and what shows while it
  can't" -- deliberately independent of client ownership (d.lua.island /
  d.js.island, see hydronium/dom/init.lua) and of error handling
  (ErrorBoundary, see hydronium/core/errors.lua). See
  docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md for what this does and does not
  implement yet (no out-of-order streaming replacement this version --
  hydronium/server/init.lua's Suspense handling buffers the subtree and
  either flushes it whole or renders `fallback` instead, in one pass).

  Mirrors errors.ErrorBoundary's shape exactly (a plain marker-returning
  function recognized by identity in core/element.lua's createElement),
  so it composes with the same VNode/kind machinery.
--]]

local symbols = require("hydronium.core.symbols")

local suspense = {}

--- Props:
---   fallback: VNode, rendered in place of `children` while a descendant
---             Resource is pending (see hydronium.core.resource).
---   children: child nodes
function suspense.Suspense(props)
  return {
    _typeof = symbols.VNODE,
    kind = symbols.SUSPENSE,
    tag = suspense.Suspense,
    props = props or {},
    children = props and props.children or {},
  }
end

return suspense
