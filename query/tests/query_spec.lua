local test = require("tests.runner")
local q = require("hydronium_query")

test.describe("hydronium/query", function()
  test.it("canonicalizes JSON-shaped keys and rejects ambiguous keys", function()
    test.assert.equal(q.encode_key({ "todos", { page = 2, done = false } }), '["todos",{"done":false,"page":2}]')
    test.assert.has_error(function() q.encode_key({ [2] = "hole" }) end, "sparse")
    test.assert.has_error(function() q.encode_key({ [true] = "bad" }) end, "string keys")
  end)

  test.it("dedupes observers, guards obsolete completions, cancels last observer and collects lazily", function()
    local now, starts, cancel, done = 0, 0
    local client = q.createClient({ clock = function() return now end, stale_time = 30, gc_time = 10 })
    local opts = { key = { "todo", 1 }, query = function(_, complete) starts = starts + 1; done = complete; return function() cancel = (cancel or 0) + 1 end end }
    local a, b = {}, {}
    local un_a = client:observe(opts, function(state) a[#a + 1] = state.status end)
    local un_b = client:observe(opts, function(state) b[#b + 1] = state.status end)
    test.assert.equal(starts, 1)
    un_a(); un_b(); test.assert.equal(cancel, 1)
    done(nil, { id = 2 }) -- stale completion is ignored after cancellation
    now = 11; client:collect()
    test.assert.equal(next(client.entries), nil)
  end)

  test.it("invalidates exact or prefix keys and mutations mark related data stale", function()
    local client = q.createClient({ stale_time = 100 })
    local done
    local stop = client:observe({ key = { "todos", 1 }, query = function(_, complete) done = complete end }, function() end)
    done(nil, { ok = true })
    local entry = client:_entry({ "todos", 1 })
    client:invalidate({ "todos" }, { refetch = false })
    test.assert.equal(entry.updated_at, nil)
    local mutation_done
    client:mutation({ mutate = function(_, complete) complete(nil, true) end, invalidate = { { "todos" } } })(nil, function(err) mutation_done = err == nil end)
    test.assert.truthy(mutation_done)
    stop()
  end)

  test.it("settles mutations once and ignores completion after cancellation", function()
    local client = q.createClient()
    local reply, calls, cancellations = nil, 0, 0
    local mutate = client:mutation({ mutate = function(_, done)
      reply = done
      return function() cancellations = cancellations + 1 end
    end })
    mutate(nil, function() calls = calls + 1 end)
    reply(nil, true); reply("late failure")
    test.assert.equal(calls, 1)
    local cancel = mutate(nil, function() calls = calls + 1 end)
    cancel(); cancel(); reply(nil, true)
    test.assert.equal(calls, 1)
    test.assert.equal(cancellations, 1)
  end)

  test.it("exposes a signal-backed useQuery handle without a global client", function()
    local client, done = q.createClient(), nil
    local handle = client:useQuery({ key = { "profile", 1 }, query = function(_, complete) done = complete end })
    test.assert.equal(handle.state().status, "pending")
    done(nil, { name = "Ada" })
    test.assert.equal(handle.data().name, "Ada")
    handle:dispose()
  end)
  test.it("starts component observations after render and cancels on unmount", function()
    local H = require("hydronium")
    local scheduler = require("hydronium.core.scheduler")
    local starts, stops, complete = 0, 0
    local client = q.createClient()
    local function Preview()
      local result = client:useQuery({ key={"preview"}, query=function(_, done)
        test.assert.falsy(scheduler.isRendering())
        starts = starts + 1; complete = done
        return function() stops = stops + 1 end
      end })
      return function() return H.h("output", {}, result.state().status) end
    end
    local root = H.create_test_root()
    H.act(function() root:render(H.h(Preview)) end)
    test.assert.equal(starts, 1)
    test.assert.equal(root:text(), "pending")
    H.act(function() root:render(nil) end)
    test.assert.equal(stops, 1)
    complete(nil, "obsolete")
  end)

  test.it("host startup scheduling is cancelled by disposal and SSR starts no request", function()
    local scheduler = require("hydronium.core.scheduler")
    local queued, starts = nil, 0
    local client = q.createClient({ schedule=function(fn) queued=fn end })
    local options={key={"scheduled"},query=function() starts=starts+1 end}
    local handle=client:useQuery(options)
    test.assert.equal(starts,0)
    handle.dispose();queued()
    test.assert.equal(starts,0)
    scheduler.setSSR(true)
    local ok, err = pcall(function()
      local server=q.createClient():useQuery(options)
      test.assert.equal(server.state().status,"idle")
      test.assert.equal(starts,0)
      server.dispose()
    end)
    scheduler.setSSR(false)
    if not ok then error(err) end
  end)


  test.it("expires idle caches using elapsed time instead of CPU time",function()
    local original=os.time
    local current=100
    os.time=function()return current end
    local ok,err=pcall(function()
      local starts=0
      local client=q.createClient({stale_time=5})
      local options={key="idle",query=function(_,done)starts=starts+1;done(nil,true)end}
      client:observe(options,function()end)()
      current=110
      client:observe(options,function()end)()
      test.assert.equal(starts,2)
      current=90
      test.assert.equal(client.clock(),110)
    end)
    os.time=original
    if not ok then error(err)end
  end)
end)
