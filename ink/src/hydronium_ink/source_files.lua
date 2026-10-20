-- Source-mode discovery for native Ink HMR. A generated Ballad source
-- inventory remains authoritative when one is available.
return function(root)
  local quote = "'" .. root:gsub("'", "'\\''") .. "'"
  local pipe = assert(io.popen("find " .. quote .. " -type f \\( -name '*.lua' -o -name '*.luax' \\) -print", "r"))
  local files = {}
  for file in pipe:lines() do files[#files + 1] = file end
  local ok = pipe:close()
  assert(ok == true or ok == 0, "Ink source discovery failed: " .. root)
  table.sort(files)
  return files
end
