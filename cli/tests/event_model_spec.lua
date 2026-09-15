--[[
  hydronium-cli event_model -- JSON-line parsing, display labels, and the
  collapse/dedup ring buffer.

  Everything here runs on canned arrays of literal JSON lines: the module
  is pure by contract (no file, no process, no clock -- every timestamp
  comes out of the event's own `ts`), which is exactly what makes the 2s
  collapse window testable at all without sleeping.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local event_model = require("event_model")

--- Builds one real wire line. Written as string concatenation rather than
--- encoded from a table so the specs assert against the literal bytes
--- meteorite is specified to emit, not against this repo's own encoder.
local function request_line(ts, method, path, status, duration, remote)
  return '{"v":1,"ts":' .. ts .. ',"source":"server","kind":"request"'
    .. ',"method":"' .. method .. '","path":"' .. path .. '"'
    .. ',"status":' .. status .. ',"duration_ms":' .. duration
    .. ',"remote_addr":' .. (remote and ('"' .. remote .. '"') or "null")
    .. "}"
end

describe("hydronium-cli event_model -- parse_line", function()
  it("parses a real request line into its fields", function()
    local event = event_model.parse_line(request_line(1757000000000, "GET", "/home", 200, 51, "127.0.0.1"))
    assert.is_table(event)
    assert.equal(event.kind, "request")
    assert.equal(event.source, "server")
    assert.equal(event.method, "GET")
    assert.equal(event.path, "/home")
    assert.equal(event.status, 200)
    assert.equal(event.duration_ms, 51)
    assert.equal(event.remote_addr, "127.0.0.1")
    assert.equal(event.ts, 1757000000000)
  end)

  it("parses a startup line", function()
    local event = event_model.parse_line(
      '{"v":1,"ts":1757000000000,"source":"supervisor","kind":"startup",'
        .. '"routes":12,"mode":"hybrid_dev","backend":"fast_http","ready_ms":340}'
    )
    assert.equal(event.kind, "startup")
    assert.equal(event.routes, 12)
    assert.equal(event.ready_ms, 340)
  end)

  it("leaves remote_addr absent when the emitter wrote null", function()
    local event = event_model.parse_line(request_line(1757000000000, "GET", "/home", 200, 51, nil))
    assert.is_nil(event.remote_addr)
  end)

  it("skips a line truncated mid-write instead of raising", function()
    -- The real, expected case: another process is appending to the file
    -- while the tailer reads it.
    local event, reason = event_model.parse_line('{"v":1,"ts":1757000000000,"source":"ser')
    assert.is_nil(event)
    assert.equal(reason, "invalid json")
  end)

  it("skips blank lines, non-objects, and non-strings", function()
    assert.is_nil(event_model.parse_line(""))
    assert.is_nil(event_model.parse_line("   "))
    assert.is_nil(event_model.parse_line("[1,2,3]"))
    assert.is_nil(event_model.parse_line("not json at all"))
    assert.is_nil(event_model.parse_line(nil))
    assert.is_nil(event_model.parse_line(42))
  end)

  it("skips an envelope missing ts, source, or kind", function()
    assert.is_nil(event_model.parse_line('{"v":1,"source":"server","kind":"request"}'))
    assert.is_nil(event_model.parse_line('{"v":1,"ts":1,"kind":"request"}'))
    assert.is_nil(event_model.parse_line('{"v":1,"ts":1,"source":"server"}'))
  end)

  it("skips a line from a future schema version rather than guessing at it", function()
    local event, reason = event_model.parse_line('{"v":2,"ts":1,"source":"server","kind":"request"}')
    assert.is_nil(event)
    assert.equal(reason, "unsupported schema version")
  end)

  it("accepts an unrecognized kind -- only the envelope is validated", function()
    -- A newer meteorite emitting a kind this CLI has never heard of must
    -- still reach .hydronium/dev.log and still render as a line.
    local event = event_model.parse_line('{"v":1,"ts":1,"source":"supervisor","kind":"telemetry"}')
    assert.is_table(event)
    assert.equal(event.kind, "telemetry")
    assert.equal(event_model.label(event), "telemetry")
  end)

  it("parse_lines keeps the good lines in order and reports the rejected ones", function()
    local events, rejected = event_model.parse_lines({
      request_line(1, "GET", "/a", 200, 1),
      "{ broken",
      request_line(2, "GET", "/b", 200, 2),
    })
    assert.equal(#events, 2)
    assert.equal(events[1].path, "/a")
    assert.equal(events[2].path, "/b")
    assert.equal(#rejected, 1)
    assert.equal(rejected[1].reason, "invalid json")
  end)
end)

describe("hydronium-cli event_model -- signature", function()
  it("keys a request on method and path only", function()
    local a = event_model.parse_line(request_line(1, "GET", "/home", 200, 51))
    local b = event_model.parse_line(request_line(2, "GET", "/home", 500, 9))
    assert.equal(event_model.signature(a), "GET /home")
    -- Status and duration deliberately out of the key: two consecutive
    -- hits on one endpoint are one collapsed line.
    assert.equal(event_model.signature(a), event_model.signature(b))
  end)

  it("distinguishes method and path", function()
    local get = event_model.parse_line(request_line(1, "GET", "/home", 200, 1))
    local post = event_model.parse_line(request_line(1, "POST", "/home", 200, 1))
    local other = event_model.parse_line(request_line(1, "GET", "/about", 200, 1))
    assert.not_equal(event_model.signature(get), event_model.signature(post))
    assert.not_equal(event_model.signature(get), event_model.signature(other))
  end)

  it("keys every other kind on the kind alone", function()
    local reload = event_model.parse_line('{"v":1,"ts":1,"source":"supervisor","kind":"reload","ok":true}')
    assert.equal(event_model.signature(reload), "reload")
  end)
end)

describe("hydronium-cli event_model -- labels", function()
  it("formats a plain request as the target mock does", function()
    local event = event_model.parse_line(request_line(1, "GET", "/home", 200, 51))
    assert.equal(event_model.label(event), "GET /home \194\183 51ms")
  end)

  it("shows the status only when it is not a success", function()
    local bad = event_model.parse_line(request_line(1, "GET", "/nope", 404, 2))
    assert.equal(event_model.label(bad), "GET /nope \194\183 404 \194\183 2ms")
  end)

  it("appends remote_addr only when show_ips is on", function()
    local event = event_model.parse_line(request_line(1, "GET", "/home", 200, 51, "10.0.0.7"))
    assert.equal(event_model.label(event), "GET /home \194\183 51ms")
    assert.equal(
      event_model.label(event, { show_ips = true }),
      "GET /home \194\183 51ms \194\183 10.0.0.7"
    )
  end)

  it("does not append anything when show_ips is on but the address is null", function()
    local event = event_model.parse_line(request_line(1, "GET", "/home", 200, 51, nil))
    assert.equal(event_model.label(event, { show_ips = true }), "GET /home \194\183 51ms")
  end)

  it("relabels a request against a known dev endpoint", function()
    local watch = event_model.parse_line(request_line(1, "GET", "/__hydronium/watch?since=abc", 200, 2))
    assert.equal(event_model.label(watch), "hmr watch \194\183 2ms")

    local hmr = event_model.parse_line(request_line(1, "GET", "/__hydronium/hmr", 200, 3))
    assert.equal(event_model.label(hmr), "hmr reconnect \194\183 3ms")

    local moduleFetch = event_model.parse_line(request_line(1, "GET", "/__hydronium/dev/module/views/App.luax", 200, 4))
    assert.equal(event_model.label(moduleFetch), "module fetch \194\183 4ms")
  end)

  it("prefers the more specific client_manifest alias over client", function()
    local manifest = event_model.parse_line(request_line(1, "GET", "/__hydronium/client_manifest", 200, 1))
    assert.equal(event_model.label(manifest), "client manifest \194\183 1ms")
    local bundle = event_model.parse_line(request_line(1, "GET", "/__hydronium/client.js", 200, 1))
    assert.equal(event_model.label(bundle), "client bundle \194\183 1ms")
  end)

  it("leaves an ordinary app path alone", function()
    local event = event_model.parse_line(request_line(1, "GET", "/api/health", 200, 1))
    assert.equal(event_model.label(event), "GET /api/health \194\183 1ms")
  end)

  it("formats the supervisor kinds", function()
    local startup = event_model.parse_line(
      '{"v":1,"ts":1,"source":"supervisor","kind":"startup","routes":12,'
        .. '"mode":"hybrid_dev","backend":"fast_http","ready_ms":340}')
    assert.equal(event_model.label(startup), "server ready \194\183 hybrid_dev/fast_http \194\183 340ms")

    local rebuild = event_model.parse_line(
      '{"v":1,"ts":1,"source":"supervisor","kind":"rebuild","reason":"views/App.luax",'
        .. '"action":"zig","partitions":2}')
    assert.equal(rebuild and event_model.label(rebuild), "rebuild \194\183 views/App.luax \226\134\146 zig (2 partitions)")

    local ok = event_model.parse_line('{"v":1,"ts":1,"source":"supervisor","kind":"reload","ok":true}')
    local bad = event_model.parse_line('{"v":1,"ts":1,"source":"supervisor","kind":"reload","ok":false}')
    assert.equal(event_model.label(ok), "reload ok")
    assert.equal(event_model.label(bad), "reload failed")

    local err = event_model.parse_line(
      '{"v":1,"ts":1,"source":"supervisor","kind":"build_error","stage":"zig","detail":"missing symbol"}')
    assert.equal(event_model.label(err), "build error \194\183 zig: missing symbol")

    local exit = event_model.parse_line(
      '{"v":1,"ts":1,"source":"supervisor","kind":"server_exit","pid":4242,"reason":"signal 15"}')
    assert.equal(event_model.label(exit), "server exited \194\183 signal 15 (pid 4242)")
  end)

  it("flattens a multi-line build-error detail onto one row", function()
    local err = event_model.parse_line(
      '{"v":1,"ts":1,"source":"supervisor","kind":"build_error","stage":"zig","detail":"a\\nb"}')
    assert.equal(event_model.label(err), "build error \194\183 zig: a b")
  end)
end)

describe("hydronium-cli event_model -- collapse/dedup ring buffer", function()
  local function push_all(buffer, lines)
    for _, line in ipairs(lines) do
      buffer:push_line(line)
    end
    return buffer
  end

  it("defaults to three visible rows", function()
    assert.equal(event_model.DEFAULT_CAPACITY, 3)
    assert.equal(event_model.new_buffer().capacity, 3)
  end)

  it("rejects a non-positive capacity rather than silently defaulting", function()
    assert.has_error(function() event_model.new_buffer({ capacity = 0 }) end, "positive number")
  end)

  it("collapses consecutive identical requests into one counted row", function()
    local buffer = push_all(event_model.new_buffer(), {
      request_line(1000, "GET", "/home", 200, 51),
      request_line(1100, "GET", "/home", 200, 48),
      request_line(1200, "GET", "/home", 200, 47),
    })
    local entries = buffer:snapshot()
    assert.equal(#entries, 1)
    assert.equal(entries[1].signature, "GET /home")
    assert.equal(entries[1].count, 3)
    assert.equal(entries[1].last_ts, 1200)
    -- Latest wins: the row shows the most recent duration, not the first.
    assert.equal(entries[1].label, "GET /home \194\183 47ms")
    assert.same(buffer:lines(), { "GET /home \194\183 47ms x3" })
  end)

  it("does not suffix a count of one", function()
    local buffer = push_all(event_model.new_buffer(), { request_line(1000, "GET", "/home", 200, 51) })
    assert.same(buffer:lines(), { "GET /home \194\183 51ms" })
  end)

  it("collapses into the CURRENT TAIL only, never an older row", function()
    -- A/B/A must be three rows, not two with the first one counted twice:
    -- rewriting a row two lines up is not what "collapse consecutive
    -- repeats" means, and would make the pane lie about ordering.
    local buffer = push_all(event_model.new_buffer(), {
      request_line(1000, "GET", "/a", 200, 1),
      request_line(1100, "GET", "/b", 200, 2),
      request_line(1200, "GET", "/a", 200, 3),
    })
    local entries = buffer:snapshot()
    assert.equal(#entries, 3)
    assert.equal(entries[1].signature, "GET /a")
    assert.equal(entries[1].count, 1)
    assert.equal(entries[2].signature, "GET /b")
    assert.equal(entries[3].signature, "GET /a")
    assert.equal(entries[3].count, 1)
  end)

  it("starts a new row once the 2000ms window has passed", function()
    assert.equal(event_model.COLLAPSE_WINDOW_MS, 2000)
    local buffer = push_all(event_model.new_buffer(), {
      request_line(1000, "GET", "/home", 200, 1),
      request_line(3000, "GET", "/home", 200, 2), -- exactly 2000ms: still collapses
      request_line(5001, "GET", "/home", 200, 3), -- 2001ms later: new row
    })
    local entries = buffer:snapshot()
    assert.equal(#entries, 2)
    assert.equal(entries[1].count, 2)
    assert.equal(entries[1].last_ts, 3000)
    assert.equal(entries[2].count, 1)
    assert.equal(entries[2].last_ts, 5001)
  end)

  it("still collapses across a few ms of backwards clock jitter", function()
    -- `ts` comes from another process's wall clock.
    local buffer = push_all(event_model.new_buffer(), {
      request_line(2000, "GET", "/home", 200, 1),
      request_line(1998, "GET", "/home", 200, 2),
    })
    assert.equal(#buffer:snapshot(), 1)
    assert.equal(buffer:snapshot()[1].count, 2)
  end)

  it("evicts the oldest row when capacity is reached", function()
    local buffer = push_all(event_model.new_buffer(), {
      request_line(1000, "GET", "/a", 200, 1),
      request_line(1100, "GET", "/b", 200, 1),
      request_line(1200, "GET", "/c", 200, 1),
      request_line(1300, "GET", "/d", 200, 1),
    })
    local entries = buffer:snapshot()
    assert.equal(#entries, 3)
    assert.equal(entries[1].signature, "GET /b")
    assert.equal(entries[3].signature, "GET /d")
  end)

  it("honors a larger capacity, which is all --verbose changes", function()
    local buffer = push_all(event_model.new_buffer({ capacity = event_model.VERBOSE_CAPACITY }), {
      request_line(1000, "GET", "/a", 200, 1),
      request_line(1100, "GET", "/b", 200, 1),
      request_line(1200, "GET", "/c", 200, 1),
      request_line(1300, "GET", "/d", 200, 1),
    })
    assert.equal(#buffer:snapshot(), 4)
  end)

  it("evicts oldest-first when capacity shrinks in place", function()
    local buffer = push_all(event_model.new_buffer({ capacity = 4 }), {
      request_line(1000, "GET", "/a", 200, 1),
      request_line(1100, "GET", "/b", 200, 1),
      request_line(1200, "GET", "/c", 200, 1),
      request_line(1300, "GET", "/d", 200, 1),
    })
    buffer:set_capacity(2)
    assert.same(
      { buffer:snapshot()[1].signature, buffer:snapshot()[2].signature },
      { "GET /c", "GET /d" }
    )
  end)

  it("leaves the buffer untouched for a malformed line and reports why", function()
    local buffer = event_model.new_buffer()
    buffer:push_line(request_line(1000, "GET", "/home", 200, 1))
    local entry, event, reason = buffer:push_line('{"v":1,"ts":1000,"source":"ser')
    assert.is_nil(entry)
    assert.is_nil(event)
    assert.equal(reason, "invalid json")
    assert.equal(#buffer:snapshot(), 1)
  end)

  it("collapses a dev-endpoint poll burst under its alias", function()
    local buffer = event_model.new_buffer()
    for i = 0, 5 do
      buffer:push_line(request_line(1000 + i * 200, "GET", "/__hydronium/watch", 200, 2))
    end
    assert.same(buffer:lines(), { "hmr watch \194\183 2ms x6" })
  end)

  it("carries show_ips through to the collapsed row", function()
    local buffer = event_model.new_buffer({ show_ips = true })
    buffer:push_line(request_line(1000, "GET", "/home", 200, 51, "10.0.0.7"))
    buffer:push_line(request_line(1100, "GET", "/home", 200, 49, "10.0.0.9"))
    assert.same(buffer:lines(), { "GET /home \194\183 49ms \194\183 10.0.0.9 x2" })
  end)

  it("mixes kinds in arrival order, most recent last", function()
    local buffer = event_model.new_buffer()
    buffer:push_line('{"v":1,"ts":1000,"source":"supervisor","kind":"startup","routes":3,'
      .. '"mode":"hybrid_dev","backend":"fast_http","ready_ms":120}')
    buffer:push_line(request_line(1200, "GET", "/home", 200, 51))
    buffer:push_line('{"v":1,"ts":1400,"source":"supervisor","kind":"reload","ok":true}')
    assert.same(buffer:lines(), {
      "server ready \194\183 hybrid_dev/fast_http \194\183 120ms",
      "GET /home \194\183 51ms",
      "reload ok",
    })
  end)
end)
