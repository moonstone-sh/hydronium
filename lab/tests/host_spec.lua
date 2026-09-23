package.path = "src/?.lua;src/?/init.lua;" .. package.path

local host = require("hydronium_lab.host")

local function same(actual, expected, label)
  assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local contract = host.contract({ base_path = "tools/lab/", renderer_stylesheet_asset = "assets/ink.css" })
same(contract.version, 1, "version")
same(contract.base_path, "/tools/lab", "base path")
same(contract.assets.stylesheet, "/tools/lab/assets/lab.css", "stylesheet")
same(contract.assets.workbench_stylesheet, "/tools/lab/assets/workbench.css", "workbench stylesheet")
same(contract.assets.workbench_client, "/tools/lab/assets/workbench.js", "workbench client")
same(contract.assets.renderer_stylesheet, "/tools/lab/assets/ink.css", "renderer stylesheet")
same(contract.assets.client, "/tools/lab/assets/meteorite.js", "client")
same(contract.transport.catalog, "/tools/lab/catalog", "catalog")
same(contract.transport.create_session, "/tools/lab/sessions", "sessions")
same(contract.transport.session_operations, "/tools/lab/sessions/{id}/operations", "operations")
same(contract.transport.close_session, "/tools/lab/sessions/{id}", "close session")

local ok = pcall(host.contract, { base_path = "/lab/../admin" })
assert(not ok, "dot segments must be rejected")

ok = pcall(host.contract, { renderer_stylesheet_asset = "../private.css" })
assert(not ok, "asset dot segments must be rejected")

local root = host.contract({ base_path = "/" })
same(root.assets.client, "/assets/meteorite.js", "root client")
same(root.transport.catalog, "/catalog", "root catalog")

print("hydronium_lab.host: ok")
