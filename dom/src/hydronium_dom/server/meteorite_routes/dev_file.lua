-- GET <href> for each `{ path, href }` entry in hydronium.sources.lua's
-- `watch` list, development builds only. Meteorite bakes `m.site`/`m.dir`
-- content into its graph, so a stylesheet served that way is stale until the
-- server rebuilds -- and the browser's in-place swap would refetch it too
-- early. This route reads the declared file from disk on every request, so
-- the swap sees the edit immediately and the server never restarts for it.
-- Only an exact declared href is served; the request never names a path.
local TYPES = {
  css = "text/css; charset=utf-8",
  js = "text/javascript; charset=utf-8",
  svg = "image/svg+xml",
  json = "application/json",
}

return function(c)
  local routes = require("hydronium_dom.server.meteorite_routes")
  local wanted = (c:path() or ""):match("^[^?]*")
  for _, entry in ipairs(routes.registry().watch) do
    if entry.href == wanted then
      local f = io.open(entry.path, "rb")
      if not f then return c:text(404, "not found") end
      local content = f:read("*a")
      f:close()
      local ext = entry.path:match("%.([%w]+)$") or ""
      return c:bytes(200, TYPES[ext] or "application/octet-stream", content, { headers = {
        ["Cache-Control"] = "no-store",
        ["X-Content-Type-Options"] = "nosniff",
      } })
    end
  end
  return c:text(404, "not found")
end
