local writer = {}

--- Lua's own `%q` format quotes for LUA SOURCE, not for a POSIX shell --
--- it is not a safe way to interpolate a path into `os.execute`. This is
--- the real shell quoting rule: wrap in single quotes, and turn any
--- embedded single quote into `'\''` (close the quote, an escaped quote,
--- reopen the quote).
local function shell_quote(str)
  return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

local function write_file(path, content)
  local f, err = io.open(path, "w")
  if not f then
    return nil, err
  end
  f:write(content)
  f:close()
  return true
end

function writer.write_project(target_dir, files, opts)
  opts = opts or {}
  local is_dry_run = opts.dry_run or false
  local results = {
    created = {},
    directories = {},
  }

  -- Sort filenames for deterministic output
  local sorted_names = {}
  for name in pairs(files) do
    table.insert(sorted_names, name)
  end
  table.sort(sorted_names)

  for _, rel_path in ipairs(sorted_names) do
    local entry = files[rel_path]
    local full_path = target_dir .. "/" .. rel_path
    full_path = full_path:gsub("/+", "/")

    -- Check directory
    local dir = full_path:match("(.+)/[^/]+$")
    if dir and not results.directories[dir] then
      if not is_dry_run then
        local ok = os.execute(string.format('mkdir -p %s', shell_quote(dir)))
        if not ok then
          return nil, string.format("Failed to create directory %s", dir)
        end
      end
      results.directories[dir] = true
    end

    local content = entry
    if not is_dry_run then
      local ok, err = write_file(full_path, content)
      if not ok then
        return nil, string.format("Failed to write %s: %s", full_path, tostring(err))
      end
    end

    table.insert(results.created, {
      path = rel_path,
      full_path = full_path,
      size = #content,
    })
  end

  return results
end

return writer
