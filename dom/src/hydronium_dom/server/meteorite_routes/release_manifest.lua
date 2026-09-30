-- GET /__hydronium/dev/manifest.json in a release build: the same module
-- metadata, but `hmr = false`, because mount() declares no HMR stream there.
return function(c)
  return c:json(require("hydronium_dom.server.meteorite_routes").browser_manifest(false))
end
