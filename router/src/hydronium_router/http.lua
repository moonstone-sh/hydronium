-- Host-neutral GET transport for route loaders. The server uses Meteorite's
-- named HTTP capability; the browser uses the abortable fetch bridge.
local json = require("hydronium_router.history.state")

local M = {}

function M.get(ctx, capability, path, done)
  if type(done) ~= "function" then error("hydronium_router.http.get requires a completion callback", 2) end
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
    error("hydronium_router.http.get path must start with '/'", 2)
  end

  local request = ctx and ctx.request
  if type(request) == "table" and type(request.http) == "function" then
    local response = request:http(capability):get(path)
    done(response)
    return nil
  end

  local bridge = _G.__router_http_get
  if type(bridge) ~= "function" then
    error("hydronium_router.http.get needs Meteorite request:http or createHttpGlobals() in the browser", 2)
  end
  return bridge(path, function(payload)
    local ok, response = pcall(json.decode, payload)
    if not ok or type(response) ~= "table" then
      done(nil, "invalid HTTP bridge response")
    elseif response.status == 0 then
      done(nil, response.error or "HTTP request failed")
    else
      done(response)
    end
  end)
end

return M
