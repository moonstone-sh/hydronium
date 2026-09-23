-- Host-neutral description of a mounted Lab HTTP surface.  This module owns
-- URL policy only: an adapter (Meteorite, another HTTP server, or a test host)
-- decides how the routes are registered and served.
local M = {}

local function normalize_base_path(value)
  value = value or "/__hydronium/lab"
  if type(value) ~= "string" or value == "" then
    error("hydronium_lab.host: base_path must be a non-empty string", 3)
  end
  value = value:gsub("\\", "/"):gsub("/+", "/")
  if value:sub(1, 1) ~= "/" then value = "/" .. value end
  if #value > 1 then value = value:gsub("/$", "") end
  if value:find("[%z\r\n?#]") then
    error("hydronium_lab.host: base_path must be a URL path without a query or fragment", 3)
  end
  for segment in value:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      error("hydronium_lab.host: base_path cannot contain dot segments", 3)
    end
  end
  return value
end

local function append(base, suffix)
  if base == "/" then return suffix == "" and "/" or "/" .. suffix end
  return suffix == "" and base .. "/" or base .. "/" .. suffix
end

local function normalize_asset_path(value, label)
  if type(value) ~= "string" or value == "" then
    error("hydronium_lab.host: " .. label .. " must be a non-empty relative URL path", 3)
  end
  if value:sub(1, 1) == "/" or value:find("\\", 1, true) or value:find("[%z\r\n?#]") then
    error("hydronium_lab.host: " .. label .. " must be a relative URL path without a query or fragment", 3)
  end
  value = value:gsub("/+", "/"):gsub("/$", "")
  for segment in value:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      error("hydronium_lab.host: " .. label .. " cannot contain dot segments", 3)
    end
  end
  return value
end

--- Describe the stable browser/host boundary for one mounted Lab instance.
--- Hosts may add private endpoints, but the workbench only depends on this
--- versioned contract.  `{id}` is a URL-encoded session-id placeholder.
--- @param opts? {base_path?: string, client_asset?: string, stylesheet_asset?: string, workbench_stylesheet_asset?: string, workbench_client_asset?: string, renderer_stylesheet_asset?: string}
function M.contract(opts)
  opts = opts or {}
  local base = normalize_base_path(opts.base_path)
  local stylesheet_asset = normalize_asset_path(opts.stylesheet_asset or "assets/lab.css", "stylesheet_asset")
  local workbench_stylesheet_asset = normalize_asset_path(opts.workbench_stylesheet_asset or "assets/workbench.css", "workbench_stylesheet_asset")
  local workbench_client_asset = normalize_asset_path(opts.workbench_client_asset or "assets/workbench.js", "workbench_client_asset")
  local client_asset = normalize_asset_path(opts.client_asset or "assets/meteorite.js", "client_asset")
  local assets = {
    -- Compatibility bundle for hosts which have not adopted layered renderer
    -- assets yet.
    stylesheet = append(base, stylesheet_asset),
    workbench_stylesheet = append(base, workbench_stylesheet_asset),
    workbench_client = append(base, workbench_client_asset),
    client = append(base, client_asset),
  }
  if opts.renderer_stylesheet_asset then
    assets.renderer_stylesheet = append(base, normalize_asset_path(opts.renderer_stylesheet_asset, "renderer_stylesheet_asset"))
  end
  return {
    version = 1,
    base_path = base,
    assets = assets,
    transport = {
      kind = "http-json-v1",
      catalog = append(base, "catalog"),
      create_session = append(base, "sessions"),
      session_operations = append(base, "sessions/{id}/operations"),
      close_session = append(base, "sessions/{id}"),
    },
  }
end

M.normalize_base_path = normalize_base_path
M.normalize_asset_path = normalize_asset_path
return M
