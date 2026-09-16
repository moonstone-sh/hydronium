-- Tagged route lifecycle results. Plain loader values remain ordinary data.
local M = {}

local function tagged(kind, fields)
  local out = fields or {}
  out._hydronium_route_result = kind
  return out
end

function M.redirect(to, opts)
  opts = opts or {}
  if type(to) ~= "string" or to == "" then
    error("hydronium_router.redirect: target must be a non-empty string", 2)
  end
  return tagged("redirect", {
    to = to,
    status = opts.status or 302,
    replace = opts.replace ~= false,
  })
end

function M.error(opts, message, data)
  if type(opts) == "number" then
    opts = { status = opts, message = message, data = data }
  end
  opts = opts or {}
  if type(opts) == "string" then opts = { message = opts } end
  if type(opts) ~= "table" then error("hydronium_router.error expects a table or message", 2) end
  return tagged("error", {
    status = opts.status or 500,
    kind = opts.kind or "route_error",
    message = opts.message or "Route loader failed",
    cause = opts.cause,
    data = opts.data,
  })
end

function M.kind(value)
  return type(value) == "table" and value._hydronium_route_result or nil
end

return M
