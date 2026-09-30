-- GET /__hydronium/dev/module/:id -- one declared project module, compiled on
-- demand (`.luax` through hydronium_luax's content-cached loader) and returned
-- as text for the browser VM. Both the first mount and every hot update fetch
-- this URL, so the two can never drift apart.
--
-- The registry is the only id -> path authority: an undeclared or server-only
-- id is a 404, never a filesystem lookup.
return function(c)
  local routes = require("hydronium_dom.server.meteorite_routes")
  local registry = routes.registry()
  local id = c:param("id") or ""
  local record = registry:module(id)
  if not record or (record.target ~= "client" and record.target ~= "shared") then
    return c:text(404, "module not found")
  end

  -- Read between two checks of the watcher revision the browser is applying:
  -- a concurrent edit yields 409, never a mixed multi-module HMR batch.
  local watch = require("hydronium_dom.dev.watch")
  local source, revision, reason, err = watch.read_snapshot(routes.watch_files(registry), c:query("revision"), function()
    if require("hydronium_luax.dialects").compiles(record.transform) then
      local ok, code = pcall(require("hydronium_luax").loader.source, record.path)
      if not ok then error("compile failed for " .. id .. ": " .. tostring(code), 0) end
      return code
    end
    local f = assert(io.open(record.path, "r"), "not found")
    local content = f:read("*a")
    f:close()
    return content
  end)
  if reason == "stale" then
    return c:text(409, "HMR source snapshot is stale", { headers = {
      ["X-Hydronium-Revision"] = revision or "",
      ["Cache-Control"] = "no-store",
    } })
  elseif reason == "read_failed" then
    return c:text(500, "-- hydronium dev: " .. tostring(err), { headers = { ["Cache-Control"] = "no-store" } })
  end
  return c:text(200, source, { headers = {
    ["X-Hydronium-Revision"] = revision,
    ["Cache-Control"] = "no-store",
  } })
end
