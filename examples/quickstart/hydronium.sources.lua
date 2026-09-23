-- Project-owned source topology. Paths are explicit in development so a
-- Meteorite request handler never scans the filesystem or exposes it by ID.
return {
  entry = "views.App",
  files = {
    "src/views/App.luax", "src/views/Counter.luax", "src/views/Home.luax", "src/views/About.luax",
    "src/views/Site.lua", "src/views/Actions.lua", "src/views/Document.luax",
  },
  roots = {
    { path = "src/views", namespace = "views", target = "client", update = "hot", effects = "safe",
      transforms = { lua = "lua", luax = "luax" } },
  },
  entries = {
    { id = "views.App", path = "src/views/App.luax" },
    { id = "views.Document", path = "src/views/Document.luax", target = "server", update = "reload", effects = "restart" },
    { id = "views.Site", path = "src/views/Site.lua", target = "shared", update = "reload", effects = "restart" },
    { id = "views.Actions", path = "src/views/Actions.lua", target = "shared", update = "reload", effects = "restart" },
  },
}
