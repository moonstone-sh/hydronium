local writer = {}

local function ensure_dir(path)
  -- Uses standard mkdir -p or recursive creation
  os.execute(string.format('mkdir -p "%s"', path))
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
    local content = files[rel_path]
    local full_path = target_dir .. "/" .. rel_path
    full_path = full_path:gsub("/+", "/")

    -- Check directory
    local dir = full_path:match("(.+)/[^/]+$")
    if dir and not results.directories[dir] then
      if not is_dry_run then
        ensure_dir(dir)
      end
      results.directories[dir] = true
    end

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
