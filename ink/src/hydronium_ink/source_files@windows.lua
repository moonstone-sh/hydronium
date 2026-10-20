-- Native UTF-16 directory enumeration: source polling must not spawn a
-- PowerShell process on the UI thread or depend on the console code page.
local ffi, bit = require("ffi"), require("bit")
ffi.cdef([[
typedef struct { uint32_t attributes; uint32_t times[6]; uint32_t size_high, size_low, reserved0, reserved1; uint16_t name[260], alternate[14]; } HY_FIND_DATA;
int __stdcall MultiByteToWideChar(unsigned int cp, uint32_t flags, const char *bytes, int count, uint16_t *wide, int size);
int __stdcall WideCharToMultiByte(unsigned int cp, uint32_t flags, const uint16_t *wide, int count, char *bytes, int size, const char *fallback, int *used);
void * __stdcall FindFirstFileW(const uint16_t *path, HY_FIND_DATA *data);
int __stdcall FindNextFileW(void *search, HY_FIND_DATA *data);
int __stdcall FindClose(void *search);
uint32_t __stdcall GetLastError(void);
]])
local C = ffi.load("kernel32")
local invalid = ffi.cast("void *", -1)
local function wide(value)
  local n = C.MultiByteToWideChar(65001, 8, value, #value, nil, 0)
  assert(n > 0, "source path is not valid UTF-8")
  local buffer = ffi.new("uint16_t[?]", n + 1)
  assert(C.MultiByteToWideChar(65001, 8, value, #value, buffer, n) == n, "source path conversion failed")
  return buffer
end
local function text(value)
  local n = C.WideCharToMultiByte(65001, 0, value, -1, nil, 0, nil, nil)
  assert(n > 0, "source filename conversion failed")
  local buffer = ffi.new("char[?]", n)
  assert(C.WideCharToMultiByte(65001, 0, value, -1, buffer, n, nil, nil) == n, "source filename conversion failed")
  return ffi.string(buffer, n - 1)
end
return function(root)
  local files = {}
  local function walk(dir)
    local data = ffi.new("HY_FIND_DATA[1]")
    local search = C.FindFirstFileW(wide(dir .. "/*"), data)
    if search == invalid then
      local code = tonumber(C.GetLastError())
      if code == 2 or code == 3 then return end
      error("cannot enumerate source directory " .. dir .. " (Windows error " .. code .. ")")
    end
    local ok, err = pcall(function()
      repeat
        local name = text(data[0].name)
        if name ~= "." and name ~= ".." then
          local full = dir .. "/" .. name
          if bit.band(data[0].attributes, 0x10) ~= 0 then
            -- Do not traverse directory junctions or symbolic links: a
            -- workspace link can point back to an ancestor indefinitely.
            if bit.band(data[0].attributes, 0x400) == 0 then walk(full) end
          elseif name:match("%.luax?$") then files[#files + 1] = full end
        end
      until C.FindNextFileW(search, data) == 0
      local code = tonumber(C.GetLastError())
      assert(code == 18, "source directory enumeration failed: " .. code)
    end)
    C.FindClose(search)
    if not ok then error(err, 0) end
  end
  walk(root:gsub("\\", "/"):gsub("/$", ""))
  table.sort(files)
  return files
end
