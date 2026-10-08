--[[
  Link: an <a href> that navigates inside the app.

    <r.Link to="/about">About</r.Link>
    <r.Link route="post" params={{ id = 7 }} query={{ tab = "comments" }}>Post 7</r.Link>

  It renders a real href, so it works before (and without) the browser
  runtime and opens in a new tab with a modified click. In the browser an
  ordinary click navigates through the router (the DOM host's guarded
  `navigate` event) instead of reloading the page. A link to the current
  location gets aria-current="page". Other props (class, title, ...) pass
  through to the <a>.
]]
local H = require("hydronium.core")
local hooks = require("hydronium_router.hooks")

local OWN = { to = true, route = true, params = true, query = true, replace = true, state = true, children = true }

---@class hydronium.LinkProps
---@field to? string           an app path, such as "/about"
---@field route? string        a route id, instead of `to`
---@field params? table        the route's path params
---@field query? table         search params
---@field replace? boolean     replace the history entry instead of pushing one
---@field state? any           history state for the new entry
---@field class? string | hydronium.Getter
---@field children? any

---@param props hydronium.LinkProps
local function Link(props)
  local router = hooks.use_router()
  return function()
    local path
    if props.route then
      path = router.route_path(props.route, props.params, props.query)
    elseif props.to then
      path = props.to
    else
      error("hydronium_router.Link needs `to` or `route`", 2)
    end
    local href = router.to_href(path)
    local attrs = {}
    -- Props are frozen behind a proxy; their fields live in _store.
    for key, value in pairs(props._store or props) do
      if not OWN[key] then attrs[key] = value end
    end
    attrs.href = href
    -- Read while rendering, so aria-current follows navigation.
    local location = hooks.use_location()
    if attrs["aria-current"] == nil and location and location.path == href:match("^[^?#]*") then
      attrs["aria-current"] = "page"
    end
    attrs.onNavigate = function()
      router.navigate(path, { replace = props.replace, state = props.state })
    end
    return H.h("a", attrs, props.children)
  end
end

return Link
