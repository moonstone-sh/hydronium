-- Literal inventory, not an optimizer. Unknown access always retains providers.
local lexer = require("hydronium_luax.lexer")
local M = {}
local function array() return setmetatable({}, { __jsontype = "array" }) end
local function literal(token)
  if not token or token.type ~= "STRING" then return nil end
  return token.value:match('^"([%w_.%-]+)"$') or token.value:match("^'([%w_.%-]+)'$")
end
function M.scan(source, contracts)
  local tokens = {}
  for _, token in ipairs(lexer.tokenize(source, "@host-capabilities", { include_whitespace = false })) do
    if token.type ~= "COMMENT" and token.type ~= "WHITESPACE" and token.type ~= "EOF" then tokens[#tokens + 1] = token end
  end
  local known = {}
  for _, contract in ipairs(contracts) do
    for _, method in ipairs(contract.methods) do known[method.legacy_global] = { contract = contract, method = method } end
  end
  local result = { references = array(), unresolved = array(), retain_all = false, analysis = "literal_inventory_v1" }
  local function unknown(t, reason)
    result.retain_all = true
    result.unresolved[#result.unresolved + 1] = { line = t.line, reason = reason }
  end
  local function legacy(name, token, next_token)
    local entry = known[name]
    if not entry then unknown(token, "undeclared_legacy_binding:" .. name); return end
    local write = next_token and next_token.value == "="
    result.references[#result.references + 1] = { name = entry.contract.name, version = entry.contract.version,
      method = entry.method.name, effect = entry.method.effect, line = token.line,
      access = write and "write" or "read", source = "legacy_global" }
    if write then unknown(token, "legacy_binding_mutation") end
  end
  local aliases = {}
  for i, t in ipairs(tokens) do
    local next_t, after = tokens[i + 1], tokens[i + 2]
    if t.value == "local" and next_t and next_t.type == "IDENT" and after and after.value == "="
      and tokens[i + 3] and tokens[i + 3].value == "require" and tokens[i + 4] and tokens[i + 4].value == "("
      and literal(tokens[i + 5]) == "hydronium.runtime.hosts" then aliases[next_t.value] = true end
    if t.type == "IDENT" and t.value:match("^__dom_") then
      local previous, base = tokens[i - 1], tokens[i - 2]
      if not previous or previous.value ~= "." or (base and base.value == "_G") then legacy(t.value, t, next_t) end
    elseif t.value == "_G" then
      if next_t and next_t.value == "." and after and after.type == "IDENT" then
        -- The subsequent identifier is inventoried by the branch above.
        if not after.value:match("^__dom_") then unknown(t, "global_environment_access") end
      elseif next_t and next_t.value == "[" then
        local name = literal(after)
        if name and name:match("^__dom_") and tokens[i + 3] and tokens[i + 3].value == "]" then
          legacy(name, t, tokens[i + 4])
        else unknown(t, "computed_global_access") end
      else unknown(t, "global_environment_escape") end
    elseif t.value == "require" and next_t and next_t.value == "(" and literal(after) == "hydronium.runtime.hosts" then
      local previous, alias, declaration = tokens[i - 1], tokens[i - 2], tokens[i - 3]
      if not (previous and previous.value == "=" and alias and aliases[alias.value] and declaration and declaration.value == "local") then unknown(t, "host_registry_unbound_result") end
    elseif t.value == "getfenv" or t.value == "setfenv" or t.value == "rawget" or t.value == "rawset" then
      unknown(t, "environment_or_raw_access")
    elseif aliases[t.value] and next_t and next_t.value == "." and after
      and (after.value == "require" or after.value == "get" or after.value == "install") then
      local open, name, comma, version = tokens[i + 3], tokens[i + 4], tokens[i + 5], tokens[i + 6]
      if open and open.value == "(" and literal(name) and comma and comma.value == "," and version and version.type == "NUMBER" then
        local found
        for _, contract in ipairs(contracts) do
          if contract.name == literal(name) and contract.version == tonumber(version.value) then found = contract end
        end
        if found then
          result.references[#result.references + 1] = { name = found.name, version = found.version, line = t.line,
            source = "host_registry", access = after.value == "install" and "provide" or "consume" }
        else unknown(t, "undeclared_host_capability") end
      else unknown(t, "computed_host_capability") end
    elseif aliases[t.value] and not (tokens[i - 1] and tokens[i - 1].value == "local") then
      unknown(t, "host_registry_escape_or_mutation")
    end
  end
  return result
end
function M.manifest(module_records, contracts)
  local modules, providers, included = array(), array(), {}
  local retain_all = false
  for _, record in ipairs(module_records) do
    local analysis = record.host_capabilities
    modules[#modules + 1] = { id = record.id, references = analysis.references, unresolved = analysis.unresolved, retain_all = analysis.retain_all }
    retain_all = retain_all or analysis.retain_all
    for _, ref in ipairs(analysis.references) do included[ref.name] = true end
  end
  for _, contract in ipairs(contracts) do
    if retain_all or included[contract.name] then providers[#providers + 1] = { name = contract.name, version = contract.version, provider = contract.provider } end
  end
  return { schema = "hydronium.host-capabilities.v1", contracts = contracts, modules = modules,
    providers = providers, retain_all = retain_all, elimination = "disabled" }
end
return M
