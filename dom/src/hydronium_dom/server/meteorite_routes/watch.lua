-- GET /__hydronium/watch -- the HMR change stream hydronium_dom/client/hmr.js
-- subscribes to. The watched set comes from the source registry plus
-- `hydronium.sources.lua`'s optional `watch` list; what each change *means*
-- to the running VM is the browser manifest's `updates` policy.
return function(c)
  local routes = require("hydronium_dom.server.meteorite_routes")
  require("hydronium_dom.dev.watch").serve_sse(c, routes.watch_files(routes.registry()))
end
