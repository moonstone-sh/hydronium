-- GET /__hydronium/dev/manifest.json -- public metadata for the project's own
-- browser modules (logical ids and update policies, never source paths), in a
-- development build: the HMR stream is available.
return function(c)
  return c:json(require("hydronium_dom.server.meteorite_routes").browser_manifest(true))
end
