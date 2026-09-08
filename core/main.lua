local H = require("hydronium")

print("=== Hydronium v0.1.0 Initializing Demo ===")

-- Closure Component (Setup-once / Render-many)
local function Counter(props)
  local count, setCount = H.createSignal(props.initial or 0)

  H.createEffect(function()
    print("  [Effect] Counter changed to: " .. count())
  end)

  return function()
    return H.h("div", { class = "counter-widget" },
      H.h("h1", nil, props.title),
      H.h("span", { class = "badge" }, "Count: " .. count()),
      H.h("button", { onClick = function() setCount(count() + 1) end }, "Increment")
    )
  end
end

-- Render into in-memory Test Host
local root = H.test.render(H.h(Counter, { title = "Interactive Hydronium Counter", initial = 1 }))

print("\nRendered ASCII Tree:")
print(root:toTreeString())

print("\nSimulating Click Event inside act()...")
local button = root:find("button")
H.test.act(function()
  button.props.onClick()
end)

print("\nUpdated ASCII Tree:")
print(root:toTreeString())

print("\n=== Demo Completed Successfully ===")
