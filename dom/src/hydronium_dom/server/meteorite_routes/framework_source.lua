-- GET /hydronium-src/:path* -- Hydronium's own runtime modules for the browser
-- VM (mount.js fetches the files named by client_manifest.json). Resolved
-- through this request VM's package.path, so the browser runs exactly the
-- copy the server loads. Only allowlisted framework namespaces and `.lua` /
-- `.json` files are served; `..` is rejected before any lookup.
return function(c)
  local NAMESPACES = require("hydronium_dom.dev.client_manifest").NAMESPACES
  local rel = c:param("path") or ""
  if rel:find("..", 1, true) or not (rel:match("%.lua$") or rel:match("%.json$")) then
    return c:text(400, "invalid path")
  end
  local namespace, rest = rel:match("^([%w_]+)/(.+)$")
  if not namespace or not NAMESPACES[namespace] then return c:text(404, "not found") end
  local init = package.searchpath(namespace, package.path)
  if not init then return c:text(404, "not found") end
  local f = io.open(init:match("^(.*)/[^/]+$") .. "/" .. rest, "r")
  if not f then return c:text(404, "not found") end
  local content = f:read("*a")
  f:close()
  return c:text(200, content)
end
