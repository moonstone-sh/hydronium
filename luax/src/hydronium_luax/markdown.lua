-- Markdown documents compile to ordinary Hydronium component modules.
-- .mdx adds a Lua setup fence and standalone LUAX component elements.
local luax = require("hydronium_luax.compiler")

local M = {}

local TAGS = { "article", "h1", "h2", "h3", "h4", "h5", "h6", "p", "a", "img", "em", "strong",
  "code", "pre", "ul", "ol", "li", "blockquote", "hr", "table", "thead", "tbody", "tr", "th", "td" }
local function tag(name) return "HydroniumMd" .. name:sub(1, 1):upper() .. name:sub(2) end

local function trim(value) return (value:gsub("^%s+", ""):gsub("%s+$", "")) end
local function text_node(value) return "{" .. string.format("%q", value) .. "}" end
local function attribute(value) return string.format("%q", value) end
local function slug(value)
  local result = value:lower():gsub("`", ""):gsub("[^%w%s%-]", ""):gsub("[%s%-]+", "-")
  result = result:gsub("^%-+", ""):gsub("%-+$", "")
  return result ~= "" and result or "section"
end
local function cells(line)
  line = trim(line):gsub("^|", ""):gsub("|$", "")
  local result = {}
  for cell in (line .. "|"):gmatch("(.-)|") do result[#result + 1] = trim(cell) end
  return result
end
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
      parts[#parts + 1] = safe_url(b) and ('<' .. tag("img") .. ' alt=' .. attribute(a) .. ' src=' .. attribute(b) .. ' />') or text_node(a)
    elseif kind == "link" then
      parts[#parts + 1] = safe_url(b) and ('<' .. tag("a") .. ' href=' .. attribute(b) .. '>' .. text_node(a) .. '</' .. tag("a") .. '>') or text_node(a)
    else parts[#parts + 1] = '<' .. tag(kind) .. '>' .. text_node(a) .. '</' .. tag(kind) .. '>' end
    cursor = finish + 1
  end
  return table.concat(parts)
end

local function blocks(source, mdx)
  local lines = {}
  for line in (source:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local nodes, setup, ids, i = {}, {}, {}, 1
  local function emit(name, body)
    local element = tag(name)
    nodes[#nodes + 1] = "<" .. element .. ">" .. body .. "</" .. element .. ">"
  end
  local function blank(line) return line == nil or trim(line) == "" end
  while i <= #lines do
    local line = lines[i]
    local fence_run, fence_info = line:match("^%s*([`~]+)%s*(.-)%s*$")
    local fence = fence_run and #fence_run >= 3 and fence_run:match("^" .. fence_run:sub(1, 1) .. "+$") and fence_run
    local language, directive
    if fence_info then language, directive = fence_info:match("^([%w_-]*)%s*([%w_-]*)$") end
    local heading, title = line:match("^%s*(#+)%s+(.+)$")
    local list = line:match("^%s*[-*+]%s+(.+)$")
    local numbered = line:match("^%s*%d+%.%s+(.+)$")
    local table_separator = lines[i + 1] and lines[i + 1]:find("%-") and lines[i + 1]:match("^%s*[|:%-%s]+%s*$")
    if blank(line) then i = i + 1
    elseif fence then
      local content, closed = {}, false
      i = i + 1
      while i <= #lines do
        local close = lines[i]:match("^%s*([`~]+)%s*$")
        if close and #close >= #fence and close:match("^" .. fence:sub(1, 1) .. "+$") then
          closed = true; i = i + 1; break
        end
        content[#content + 1] = lines[i]; i = i + 1
      end
      if not closed then error("hydronium markdown: unclosed code fence", 2) end
      if mdx and language == "lua" and directive == "setup" and #nodes == 0 then
        setup[#setup + 1] = table.concat(content, "\n")
      else
        local code = table.concat(content, "\n")
        nodes[#nodes + 1] = '<' .. tag("pre") .. '><' .. tag("code")
          .. (language ~= "" and (' class=' .. attribute("language-" .. language)) or "")
          .. '>' .. text_node(code) .. '</' .. tag("code") .. '></' .. tag("pre") .. '>'
      end
    elseif mdx and line:match("^%s*<[A-Z][%w_.]*[%s/>]") then
      -- LUAX handles attributes, expressions and lexical component lookup.
      -- Keep a component element on one line; Markdown around it remains prose.
      nodes[#nodes + 1] = trim(line)
      i = i + 1
    elseif heading and #heading <= 6 then
      local base = slug(title)
      ids[base] = (ids[base] or 0) + 1
      local id = ids[base] == 1 and base or base .. "-" .. ids[base]
      local heading_tag = "h" .. #heading
      nodes[#nodes + 1] = "<" .. tag(heading_tag) .. " id=" .. attribute(id) .. ">" .. inline(trim(title)) .. "</" .. tag(heading_tag) .. ">"
      i = i + 1
    elseif line:match("^%s*%-%-%-%s*$") then
      nodes[#nodes + 1] = "<" .. tag("hr") .. " />"; i = i + 1
    elseif line:find("|", 1, true) and table_separator then
      local headers, rows = cells(line), {}
      i = i + 2
      while i <= #lines and not blank(lines[i]) and lines[i]:find("|", 1, true) do
        rows[#rows + 1] = cells(lines[i]); i = i + 1
      end
      local head = {}
      for _, value in ipairs(headers) do head[#head + 1] = "<" .. tag("th") .. ">" .. inline(value) .. "</" .. tag("th") .. ">" end
      local body = {}
      for _, row in ipairs(rows) do
        local values = {}
        for index = 1, #headers do values[#values + 1] = "<" .. tag("td") .. ">" .. inline(row[index] or "") .. "</" .. tag("td") .. ">" end
        body[#body + 1] = "<" .. tag("tr") .. ">" .. table.concat(values) .. "</" .. tag("tr") .. ">"
      end
      nodes[#nodes + 1] = "<" .. tag("table") .. "><" .. tag("thead") .. "><" .. tag("tr") .. ">"
        .. table.concat(head) .. "</" .. tag("tr") .. "></" .. tag("thead") .. "><" .. tag("tbody") .. ">"
        .. table.concat(body) .. "</" .. tag("tbody") .. "></" .. tag("table") .. ">"
    elseif list or numbered then
      local ordered = numbered ~= nil
      local items = {}
      while i <= #lines do
        local item = ordered and lines[i]:match("^%s*%d+%.%s+(.+)$") or lines[i]:match("^%s*[-*+]%s+(.+)$")
        if not item then break end
        items[#items + 1] = "<" .. tag("li") .. ">" .. inline(trim(item)) .. "</" .. tag("li") .. ">"
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
      emit("blockquote", "<" .. tag("p") .. ">" .. inline(table.concat(quoted, " ")) .. "</" .. tag("p") .. ">")
    else
      local paragraph = { trim(line) }
      i = i + 1
      while i <= #lines and not blank(lines[i]) and not lines[i]:match("^%s*#%s")
          and not lines[i]:match("^%s*[-*+]%s+") and not lines[i]:match("^%s*%d+%.%s+")
          and not lines[i]:match("^%s*```") and not lines[i]:match("^%s*~~~")
          and not (mdx and lines[i]:match("^%s*<[A-Z]")) do
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
  local bindings = {}
  for _, name in ipairs(TAGS) do
    bindings[#bindings + 1] = "  local " .. tag(name) .. " = components." .. name .. " or " .. string.format("%q", name)
  end
  local generated = table.concat({
    'local H = require("hydronium")', setup,
    'return function(props)',
    '  local components = props and props.components or {}',
    table.concat(bindings, "\n"),
    '  return <' .. tag("article") .. ' class={props and props.class}>' .. body .. '</' .. tag("article") .. '>',
    'end',
  }, "\n")
  local compiled = luax.compile(generated, { filename = filename, module_id = options.module_id,
    development = options.development, runtime = options.runtime or "hydronium" })
  compiled.generated_luax = generated
  return compiled
end

return M
