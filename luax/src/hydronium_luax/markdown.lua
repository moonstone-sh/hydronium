-- Markdown documents compile to ordinary Hydronium component modules.
-- .mdx adds a Lua setup fence and standalone LUAX component elements.
local luax = require("hydronium_luax.compiler")

local M = {}

local function trim(value) return (value:gsub("^%s+", ""):gsub("%s+$", "")) end
local function text_node(value) return "{" .. string.format("%q", value) .. "}" end
local function attribute(value) return string.format("%q", value) end
local function safe_url(value)
  local normalized = trim(value):gsub("[%c%s]", "")
  local scheme = normalized:match("^([%a][%w+.-]*):")
  if scheme and not ({ http = true, https = true, mailto = true })[scheme:lower()] then return nil end
  return value
end

local function inline(source)
  local parts, cursor = {}, 1
  local function plain(value)
    if value ~= "" then parts[#parts + 1] = text_node(value) end
  end
  while cursor <= #source do
    local next_at, kind, a, b, finish
    local patterns = {
      { "image", "!%[([^%]]+)%]%(([^%)]+)%)" },
      { "link", "%[([^%]]+)%]%(([^%)]+)%)" },
      { "code", "`([^`]+)`" },
      { "strong", "%*%*([^*]+)%*%*" },
      { "em", "%*([^*]+)%*" },
    }
    for _, item in ipairs(patterns) do
      local start, stop, first, second = source:find(item[2], cursor)
      if start and (not next_at or start < next_at) then
        next_at, finish, kind, a, b = start, stop, item[1], first, second
      end
    end
    if not next_at then plain(source:sub(cursor)); break end
    plain(source:sub(cursor, next_at - 1))
    if kind == "image" then
      parts[#parts + 1] = safe_url(b) and ('<img alt=' .. attribute(a) .. ' src=' .. attribute(b) .. ' />') or text_node(a)
    elseif kind == "link" then
      parts[#parts + 1] = safe_url(b) and ('<a href=' .. attribute(b) .. '>' .. text_node(a) .. '</a>') or text_node(a)
    else parts[#parts + 1] = '<' .. kind .. '>' .. text_node(a) .. '</' .. kind .. '>' end
    cursor = finish + 1
  end
  return table.concat(parts)
end

local function blocks(source, mdx)
  local lines = {}
  for line in (source:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local nodes, setup, i = {}, {}, 1
  local function emit(tag, body) nodes[#nodes + 1] = "<" .. tag .. ">" .. body .. "</" .. tag .. ">" end
  local function blank(line) return line == nil or trim(line) == "" end
  while i <= #lines do
    local line = lines[i]
    local fence, language, directive = line:match("^%s*(```+)%s*([%w_-]*)%s*([%w_-]*)%s*$")
    local heading, title = line:match("^%s*(#+)%s+(.+)$")
    local list = line:match("^%s*[-*+]%s+(.+)$")
    local numbered = line:match("^%s*%d+%.%s+(.+)$")
    if blank(line) then i = i + 1
    elseif fence then
      local content, closed = {}, false
      i = i + 1
      while i <= #lines do
        if lines[i]:match("^%s*" .. fence .. "%s*$") then closed = true; i = i + 1; break end
        content[#content + 1] = lines[i]; i = i + 1
      end
      if not closed then error("hydronium markdown: unclosed code fence", 2) end
      if mdx and language == "lua" and directive == "setup" and #nodes == 0 then
        setup[#setup + 1] = table.concat(content, "\n")
      else
        local code = table.concat(content, "\n")
        nodes[#nodes + 1] = '<pre><code' .. (language ~= "" and (' class=' .. attribute("language-" .. language)) or "") .. '>' .. text_node(code) .. '</code></pre>'
      end
    elseif mdx and line:match("^%s*<[A-Z][%w_.]*[%s/>]") then
      -- LUAX handles attributes, expressions and lexical component lookup.
      -- Keep a component element on one line; Markdown around it remains prose.
      nodes[#nodes + 1] = trim(line)
      i = i + 1
    elseif heading and #heading <= 6 then
      emit("h" .. #heading, inline(trim(title))); i = i + 1
    elseif line:match("^%s*%-%-%-%s*$") then
      nodes[#nodes + 1] = "<hr />"; i = i + 1
    elseif list or numbered then
      local ordered = numbered ~= nil
      local items = {}
      while i <= #lines do
        local item = ordered and lines[i]:match("^%s*%d+%.%s+(.+)$") or lines[i]:match("^%s*[-*+]%s+(.+)$")
        if not item then break end
        items[#items + 1] = "<li>" .. inline(trim(item)) .. "</li>"
        i = i + 1
      end
      emit(ordered and "ol" or "ul", table.concat(items))
    elseif line:match("^%s*>%s?") then
      local quoted = {}
      while i <= #lines do
        local quote = lines[i]:match("^%s*>%s?(.*)$")
        if quote == nil then break end
        quoted[#quoted + 1] = quote; i = i + 1
      end
      emit("blockquote", "<p>" .. inline(table.concat(quoted, " ")) .. "</p>")
    else
      local paragraph = { trim(line) }
      i = i + 1
      while i <= #lines and not blank(lines[i]) and not lines[i]:match("^%s*#%s")
          and not lines[i]:match("^%s*[-*+]%s+") and not lines[i]:match("^%s*%d+%.%s+")
          and not lines[i]:match("^%s*```") and not (mdx and lines[i]:match("^%s*<[A-Z]")) do
        paragraph[#paragraph + 1] = trim(lines[i]); i = i + 1
      end
      emit("p", inline(table.concat(paragraph, " ")))
    end
  end
  return table.concat(setup, "\n"), table.concat(nodes, "\n")
end

function M.compile(source, options)
  options = options or {}
  local filename = options.filename or "document.md"
  local mdx = filename:match("%.mdx$") ~= nil
  local setup, body = blocks(source, mdx)
  local generated = table.concat({
    'local H = require("hydronium")', setup,
    'return function(props)',
    '  return <article class={props and props.class}>' .. body .. '</article>',
    'end',
  }, "\n")
  local compiled = luax.compile(generated, { filename = filename, module_id = options.module_id,
    development = options.development, runtime = options.runtime or "hydronium" })
  compiled.generated_luax = generated
  return compiled
end

return M
