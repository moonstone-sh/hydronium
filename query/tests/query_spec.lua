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

  test.it("exposes a signal-backed useQuery handle without a global client", function()
    local client, done = q.createClient(), nil
    local handle = client:useQuery({ key = { "profile", 1 }, query = function(_, complete) done = complete end })
    test.assert.equal(handle.state().status, "pending")
    done(nil, { name = "Ada" })
    test.assert.equal(handle.data().name, "Ada")
    handle:dispose()
  end)
end)
