-- Runtime validation and build-time provenance share this declarative contract.
local M = { name = "dom", version = 1 }
local definitions = {
  create_element = { "core", "dom.write", true }, create_text = { "core", "dom.write", true },
  set_text = { "core", "dom.write", true }, append_child = { "core", "dom.write", true },
  insert_before = { "core", "dom.write", true }, remove_child = { "core", "dom.write", true },
  set_attr = { "core", "dom.write", true }, remove_attr = { "core", "dom.write", true },
  set_listener = { "events", "dom.listen", true, "remove_listener" },
  remove_listener = { "events", "dom.listen", true }, prevent_default = { "events", "event.cancel" },
  first_child = { "hydration", "dom.read", true }, next_sibling = { "hydration", "dom.read", true },
  is_element = { "hydration", "dom.read", true }, is_text = { "hydration", "dom.read", true },
  tag_of = { "hydration", "dom.read", true }, is_comment = { "hydration", "dom.read" },
  hydration_mismatch = { "hydration", "diagnostic.write" },
  set_style_property = { "styles", "dom.write" }, remove_style_property = { "styles", "dom.write" },
  observe_virtual_item = { "virtual", "dom.observe", false, "returned_disposer" },
  observe_virtual_container = { "virtual", "dom.observe", false, "returned_disposer" },
  scroll_virtual_container = { "virtual", "dom.write" },
}
function M.manifest()
  local methods = {}
  for name, d in pairs(definitions) do
    methods[#methods + 1] = { name = name, group = d[1], effect = d[2], required = d[3] == true,
      cleanup = d[4], legacy_global = "__dom_" .. name }
  end
  table.sort(methods, function(a, b) return a.name < b.name end)
  return { name = M.name, version = M.version, methods = methods,
    provider = { language = "javascript", package = "@hydronium-js/dom-client", module = "dom_bridge.js", export = "createDomBridge" },
    lifecycle = "vm", registration_effect = "host.install" }
end
function M.validate(bridge)
  if type(bridge) ~= "table" then error("DOM bridge must be a table", 2) end
  local missing = {}
  for name, d in pairs(definitions) do
    if d[3] and type(bridge[name]) ~= "function" then missing[#missing + 1] = name end
  end
  table.sort(missing)
  if #missing > 0 then error("hydronium.host.dom.createDomHost: missing required DOM bridge function(s): " .. table.concat(missing, ", "), 2) end
  return bridge
end
return M
