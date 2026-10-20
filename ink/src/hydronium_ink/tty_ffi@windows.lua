-- Native console input records avoid blocking ReadFile after a resize/focus
-- event. The shared key parser still receives UTF-8 and terminal key sequences.
local ffi, bit = require("ffi"), require("bit")
ffi.cdef([[
typedef struct { short X, Y; } HY_COORD;
typedef struct { short Left, Top, Right, Bottom; } HY_RECT;
typedef struct { HY_COORD size, cursor; unsigned short attributes; HY_RECT window; HY_COORD maximum; } HY_SCREEN_INFO;
typedef struct { int down; unsigned short repeat_count, key, scan, character; uint32_t controls; } HY_KEY_EVENT;
typedef struct { unsigned short kind; union { HY_KEY_EVENT key; unsigned char padding[16]; } event; } HY_INPUT_RECORD;
void * __stdcall GetStdHandle(uint32_t id);
int __stdcall GetConsoleMode(void *handle, uint32_t *mode);
int __stdcall SetConsoleMode(void *handle, uint32_t mode);
unsigned int __stdcall GetConsoleOutputCP(void);
int __stdcall SetConsoleOutputCP(unsigned int codepage);
int __stdcall GetConsoleScreenBufferInfo(void *handle, HY_SCREEN_INFO *info);
int __stdcall GetNumberOfConsoleInputEvents(void *handle, uint32_t *count);
int __stdcall ReadConsoleInputW(void *handle, HY_INPUT_RECORD *records, uint32_t count, uint32_t *read);
uint32_t __stdcall WaitForSingleObject(void *handle, uint32_t milliseconds);
int __stdcall WriteFile(void *handle, const void *bytes, uint32_t size, uint32_t *written, void *overlapped);
]])
local C = ffi.load("kernel32")
local M, pending, high_surrogate = {}, "", nil
local function handle(fd) return C.GetStdHandle(fd == 0 and -10 or fd == 1 and -11 or -12) end
local function mode(fd)
  local result = ffi.new("uint32_t[1]")
  if C.GetConsoleMode(handle(fd), result) == 0 then return nil end
  return tonumber(result[0])
end
function M.isTTY(fd) return mode(fd) ~= nil end
function M.enableRawMode()
  local input, output = mode(0), mode(1)
  assert(input and output, "Ink requires a native Windows console on stdin and stdout")
  local saved = { input = input, output = output, codepage = tonumber(C.GetConsoleOutputCP()) }
  local ok, err = pcall(function()
    -- Raw key records include Ctrl+C; disable line input, echo, quick edit,
    -- processed input, mouse and VT input. Resize events remain enabled.
    local raw = bit.bor(bit.band(input, bit.bnot(0x1 + 0x2 + 0x4 + 0x10 + 0x40 + 0x200)), 0x8 + 0x80)
    assert(C.SetConsoleMode(handle(0), raw) ~= 0, "Ink could not enter raw console mode")
    assert(C.SetConsoleMode(handle(1), bit.bor(output, 0x1 + 0x4)) ~= 0, "Ink requires virtual terminal output support")
    assert(C.SetConsoleOutputCP(65001) ~= 0, "Ink could not enable UTF-8 output")
  end)
  if not ok then M.restoreMode(saved); error(err, 0) end
  pending, high_surrogate = "", nil
  return saved
end
function M.restoreMode(saved)
  if not saved or saved.restored then return end
  C.SetConsoleMode(handle(0), saved.input)
  C.SetConsoleMode(handle(1), saved.output)
  C.SetConsoleOutputCP(saved.codepage)
  saved.restored = true
end
function M.getWindowSize()
  local info = ffi.new("HY_SCREEN_INFO[1]")
  assert(C.GetConsoleScreenBufferInfo(handle(1), info) ~= 0, "Ink could not read console dimensions")
  return { columns = info[0].window.Right - info[0].window.Left + 1, rows = info[0].window.Bottom - info[0].window.Top + 1 }
end
function M.setNonBlocking(fd) assert(fd == 0, "Ink reads console input from stdin") end
local keys = { [0x21] = "[5~", [0x22] = "[6~", [0x23] = "[F", [0x24] = "[H", [0x25] = "[D", [0x26] = "[A", [0x27] = "[C", [0x28] = "[B", [0x2d] = "[2~", [0x2e] = "[3~" }
local function utf8(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then return string.char(0xc0 + math.floor(code / 64), 0x80 + code % 64) end
  if code < 0x10000 then return string.char(0xe0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64) end
  return string.char(0xf0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64, 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end
local function pump()
  local count = ffi.new("uint32_t[1]")
  assert(C.GetNumberOfConsoleInputEvents(handle(0), count) ~= 0, "Ink console input disconnected")
  if count[0] == 0 then return end
  local records = ffi.new("HY_INPUT_RECORD[?]", math.min(tonumber(count[0]), 128))
  assert(C.ReadConsoleInputW(handle(0), records, math.min(tonumber(count[0]), 128), count) ~= 0, "Ink console read failed")
  for i = 0, tonumber(count[0]) - 1 do
    local record = records[i]
    if record.kind == 1 and record.event.key.down ~= 0 then
      local key, bytes = record.event.key, nil
      local code, vk, controls = tonumber(key.character), tonumber(key.key), tonumber(key.controls)
      if code >= 0xd800 and code <= 0xdbff then high_surrogate = code
      elseif code >= 0xdc00 and code <= 0xdfff then
        bytes = utf8(high_surrogate and (0x10000 + (high_surrogate - 0xd800) * 1024 + code - 0xdc00) or 0xfffd)
        high_surrogate = nil
      elseif keys[vk] then
        local suffix = keys[vk]
        local modifier = 1 + (bit.band(controls, 0x10) ~= 0 and 1 or 0) + (bit.band(controls, 0x3) ~= 0 and 2 or 0) + (bit.band(controls, 0xc) ~= 0 and 4 or 0)
        if modifier > 1 then
          suffix = suffix:sub(-1) == "~" and suffix:gsub("~$", ";" .. modifier .. "~") or "[1;" .. modifier .. suffix:sub(-1)
        end
        bytes = "\27" .. suffix
      elseif vk == 9 and bit.band(controls, 0x10) ~= 0 then bytes = "\27[Z"
      elseif code ~= 0 then
        bytes = utf8(code == 8 and 127 or code)
        -- Right-Alt + Ctrl is AltGr, not an Alt shortcut.
        if bit.band(controls, 0x3) ~= 0 and bit.band(controls, 0xc) == 0 then bytes = "\27" .. bytes end
        high_surrogate = nil
      end
      if bytes then pending = pending .. bytes:rep(math.max(1, tonumber(key.repeat_count))) end
    end
  end
end
function M.pollReadable(fd, timeoutMs)
  assert(fd == 0, "Ink reads console input from stdin")
  local clock = require("hydronium_ink.clock")
  local deadline = clock.nowMs() + math.max(0, timeoutMs or 0)
  repeat
    pump()
    if #pending > 0 then return true end
    local remaining = deadline - clock.nowMs()
    if remaining <= 0 then return false end
    local result = tonumber(C.WaitForSingleObject(handle(0), math.ceil(remaining)))
    if result == 0x102 then return false end
    assert(result == 0, "Ink console wait failed")
  until false
end
function M.readAvailable(fd, maxBytes)
  assert(fd == 0, "Ink reads console input from stdin")
  pump()
  if #pending == 0 then return nil end
  local bytes = pending:sub(1, maxBytes)
  pending = pending:sub(#bytes + 1)
  return bytes
end
function M.pollWritable() return true end
function M.writeAll(fd, data)
  local sent, count = 0, ffi.new("uint32_t[1]")
  while sent < #data do
    local remaining = data:sub(sent + 1)
    if C.WriteFile(handle(fd), remaining, #remaining, count, nil) == 0 or count[0] == 0 then return false, sent end
    sent = sent + tonumber(count[0])
  end
  return true, sent
end
return M
