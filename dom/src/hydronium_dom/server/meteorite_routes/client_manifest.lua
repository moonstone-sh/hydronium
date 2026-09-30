-- GET /__hydronium/client_manifest.json -- the framework modules the browser
-- VM needs, derived from the project's client/shared modules' real require
-- graph (see hydronium_dom.dev.client_manifest). Nothing to regenerate by hand.
return function(c)
  local routes = require("hydronium_dom.server.meteorite_routes")
  local registry = routes.registry()
  local sources = {}
  for _, record in ipairs(registry.records) do
    if record.target == "client" or record.target == "shared" then
      local ok, source = pcall(function()
        if record.transform == "luax" or record.transform == "md" or record.transform == "mdx" then
          return require("hydronium_luax").loader.source(record.path)
        end
        local f = assert(io.open(record.path, "r"))
        local content = f:read("*a")
        f:close()
        return content
      end)
      -- A module that fails to compile reports through its own module route.
      if ok then sources[#sources + 1] = source end
    end
  end
  return c:json(require("hydronium_dom.dev.client_manifest").build(nil, sources))
end
