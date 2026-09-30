local describe = _G.describe
local it = _G.it
local assert = _G.assert

local hydronium = require("hydronium")
local h = hydronium.createElement
local useContext = hydronium.useContext
local meteorite = require("hydronium_dom.server.meteorite")

describe("Meteorite Integration Adapter", function()
  it("renders a simple vnode to standard response table", function()
    local c = {
      params = { id = "42" },
      query = { tab = "info" },
      request_id = "req-12345",
    }

    local vnode = h("div", { class = "page" }, "Hello Meteorite")
    local res = meteorite.render(c, vnode)

    assert.truthy(type(res) == "table")
    assert.equal(res.status, 200)
    assert.equal(res.content_type, "text/html; charset=utf-8")
    assert.truthy(res.body:find("<div class=\"page\">Hello Meteorite</div>"))
  end)

  it("delegates to c:html when context provides html helper", function()
    local called_status, called_body, called_opts
    local c = {
      html = function(self, status, body, opts)
        called_status = status
        called_body = body
        called_opts = opts
        return {
          status = status,
          content_type = "text/html; charset=utf-8",
          body = body,
          headers = opts and opts.headers,
        }
      end,
      params = { slug = "hydronium-ssr" },
      query = {},
      request_id = function(self) return "req-mock-id" end,
    }

    local vnode = h("h1", nil, "Title")
    local res = meteorite.render(c, vnode, {
      status = 201,
      headers = { ["X-Custom-Header"] = "Meteorite" }
    })

    assert.equal(called_status, 201)
    assert.truthy(called_body:find("<h1>Title</h1>"))
    assert.truthy(called_opts)
    assert.equal(called_opts.headers["X-Custom-Header"], "Meteorite")
    assert.equal(res.status, 201)
    assert.equal(res.headers["X-Custom-Header"], "Meteorite")
  end)

  it("bridges request context to components via useContext(meteorite.RequestContext)", function()
    local captured_req = nil

    local function UserProfile(props)
      local req = useContext(meteorite.RequestContext)
      captured_req = req
      return h("div", { class = "user-profile" }, {
        h("span", { id = "user-id" }, req.params.user_id or ""),
        h("span", { id = "tab" }, req.query.tab or ""),
        h("span", { id = "req-id" }, req.request_id or ""),
      })
    end

    local c = {
      params = { user_id = "user-999" },
      query = { tab = "activity" },
      target = function() return "/users/user-999?tab=activity" end,
      path = function() return "/users/user-999" end,
      route_id = function() return "users.show" end,
      request_id = "req-abc-999",
      state = { user_role = "admin" },
      scope = { org = "meteorite-foundation" },
    }

    local res = meteorite.render(c, UserProfile)

    assert.truthy(captured_req ~= nil)
    assert.equal(captured_req.params.user_id, "user-999")
    assert.equal(captured_req.query.tab, "activity")
    assert.equal(captured_req.request_id, "req-abc-999")
    assert.equal(captured_req.state.user_role, "admin")
    assert.equal(captured_req.scope.org, "meteorite-foundation")
    assert.equal(captured_req.url, "/users/user-999?tab=activity")
    assert.equal(captured_req.path, "/users/user-999")
    assert.equal(captured_req.route_id, "users.show")

    assert.truthy(res.body:find("<span id=\"user%-id\">user%-999</span>"))
    assert.truthy(res.body:find("<span id=\"tab\">activity</span>"))
    assert.truthy(res.body:find("<span id=\"req%-id\">req%-abc%-999</span>"))
  end)

  it("creates a reusable route handler function with meteorite.handler", function()
    local function Page(props)
      return h("main", nil, "Package: " .. tostring(props.params.pkg))
    end

    local handler = meteorite.handler(Page, {
      headers = { ["X-Powered-By"] = "Hydronium+Meteorite" }
    })

    local c = {
      params = { pkg = "hydronium" },
      query = {},
    }

    local res = handler(c)
    assert.equal(res.status, 200)
    assert.truthy(res.body:find("<main>Package: hydronium</main>"))
    assert.equal(res.headers["X-Powered-By"], "Hydronium+Meteorite")
  end)

  it("handles ErrorBoundary inside SSR component tree gracefully", function()
    local function BrokenComponent()
      error("Simulated crash in subcomponent")
    end

    local function SafePage()
      return h(hydronium.ErrorBoundary, {
        fallback = function(err)
          return h("div", { class = "ssr-error-fallback" }, "Recovered: " .. tostring(err.message or err))
        end
      }, {
        h(BrokenComponent, nil)
      })
    end

    local c = { params = {}, query = {} }
    local res = meteorite.render(c, SafePage, { status = 500 })

    assert.equal(res.status, 500)
    assert.truthy(res.body:find("class=\"ssr%-error%-fallback\""))
    assert.truthy(res.body:find("Simulated crash in subcomponent"))
  end)

  it("supports streaming rendering via meteorite.render_stream", function()
    local chunks = {}
    local sink = {
      write = function(self, chunk)
        table.insert(chunks, chunk)
      end,
      flush = function(self) end,
      close = function(self) end,
    }

    local c = { params = { name = "StreamingPage" }, query = {} }
    local function StreamApp(props)
      return h("article", nil, {
        h("h1", nil, "Streamed Header"),
        h("p", nil, "Target: " .. props.params.name)
      })
    end

    meteorite.render_stream(c, StreamApp, sink)

    local full_html = table.concat(chunks, "")
    assert.truthy(full_html:find("<article><h1>Streamed Header</h1><p>Target: StreamingPage</p></article>"))
  end)
  it("does not emit text-boundary markers inside <title> or <textarea>, and still escapes", function()
    local res = meteorite.render({}, h("html", nil, {
      h("title", nil, { "Hello, ", "<Ada>" }),
      h("textarea", nil, { "a", "b" }),
      h("p", nil, { "x", "y" }),
    }))
    assert.truthy(res.body:find("<title>Hello, &lt;Ada&gt;</title>", 1, true))
    assert.truthy(res.body:find("<textarea>ab</textarea>", 1, true))
    assert.truthy(res.body:find("<p>x<!--hy:t-->y</p>", 1, true))
  end)

  describe("mount", function()
    local function fake()
      local app = { routes = {} }
      function app:get(path, options, handler)
        local route = { path = path, options = options, handler = handler }
        self.routes[#self.routes + 1] = route
        return route
      end
      local m = {
        dir = function(root, opts) return { kind = "dir", root = root, opts = opts } end,
        file = function(path, opts) return { kind = "file", path = path, opts = opts } end,
        lua = function(ref, opts) return { kind = "lua", module = ref, path = opts.path, arg_mode = opts.arg_mode } end,
      }
      return app, m
    end
    local function by_path(app)
      local out = {}
      for _, route in ipairs(app.routes) do out[route.path] = route end
      return out
    end

    it("declares framework routes as documented file handlers, vendor before runtime", function()
      local app, m = fake()
      meteorite.mount(app, { meteorite = m, client_manifest = false })
      local routes = by_path(app)
      assert.equal(app.routes[1].path, "/js/bootstrap/vendor/:path*")
      assert.equal(app.routes[2].path, "/js/bootstrap/:path*")
      assert.equal(routes["/js/bootstrap/:path*"].options.memory.request_arena, "1mb")
      assert.truthy(routes["/js/router/history.js"])
      assert.is_nil(routes["/__hydronium/client_manifest.json"])
      for _, path in ipairs({ "/hydronium-src/:path*", "/__hydronium/dev/manifest.json",
        "/__hydronium/dev/module/:id", "/__hydronium/watch" }) do
        local handler = routes[path].handler
        assert.equal(handler.kind, "lua")
        assert.equal(handler.arg_mode, "lazy_context")
        local chunk = loadfile(handler.path)
        assert.truthy(chunk)
        assert.equal(type(chunk()), "function")
      end
      for _, route in ipairs(app.routes) do
        assert.truthy(route.options.id and route.options.summary)
      end
    end)

    it("omits dev routes with dev = false and the router assets with router = false", function()
      local app, m = fake()
      meteorite.mount(app, { meteorite = m, dev = false, router = false, client_manifest = false })
      local routes = by_path(app)
      assert.is_nil(routes["/__hydronium/watch"])
      assert.is_nil(routes["/js/router/history.js"])
      assert.truthy(routes["/hydronium-src/:path*"])
    end)

    it("derives the client manifest by default and pins a static file on request", function()
      local app, m = fake()
      meteorite.mount(app, { meteorite = m })
      assert.equal(by_path(app)["/__hydronium/client_manifest.json"].handler.kind, "lua")
      app, m = fake()
      meteorite.mount(app, { meteorite = m, client_manifest = "manifest.json" })
      assert.equal(by_path(app)["/__hydronium/client_manifest.json"].handler.path, "manifest.json")
    end)

    it("keeps module delivery but drops the HMR stream in a release build", function()
      local previous = rawget(_G, "METEORITE_BUILD_MODE")
      _G.METEORITE_BUILD_MODE = "release-hybrid"
      local ok, err = pcall(function()
        assert.truthy(meteorite.is_release_build())
        local app, m = fake()
        meteorite.mount(app, { meteorite = m })
        local routes = by_path(app)
        assert.is_nil(routes["/__hydronium/watch"])
        assert.truthy(routes["/__hydronium/dev/module/:id"])
        assert.truthy(routes["/__hydronium/dev/manifest.json"].handler.path:find("release_manifest.lua", 1, true))
      end)
      _G.METEORITE_BUILD_MODE = previous
      assert.truthy(ok, err)
    end)

    it("serves the HMR stream in a development build", function()
      local previous = rawget(_G, "METEORITE_BUILD_MODE")
      _G.METEORITE_BUILD_MODE = "hybrid_dev"
      local app, m = fake()
      meteorite.mount(app, { meteorite = m })
      _G.METEORITE_BUILD_MODE = previous
      local routes = by_path(app)
      assert.truthy(routes["/__hydronium/watch"])
      assert.truthy(routes["/__hydronium/dev/manifest.json"].handler.path:find("dev_manifest.lua", 1, true))
    end)

    it("serves href'd watch stylesheets from disk in development, ahead of static routes", function()
      local routes = require("hydronium_dom.server.meteorite_routes")
      local original = routes.registry
      routes.registry = function()
        return require("hydronium_dom.dev.source_registry").from_config({
          files = {}, watch = { "notes.txt", { path = "public/style.css", href = "/public/style.css" } },
        })
      end
      local previous = rawget(_G, "METEORITE_BUILD_MODE")
      local ok, err = pcall(function()
        _G.METEORITE_BUILD_MODE = "hybrid_dev"
        local app, m = fake()
        meteorite.mount(app, { meteorite = m })
        local route = by_path(app)["/public/style.css"]
        assert.truthy(route and route.handler.path:find("dev_file.lua", 1, true))
        assert.same(meteorite.dev_watch().passive, { "public/style.css" })

        _G.METEORITE_BUILD_MODE = "release-hybrid"
        app, m = fake()
        meteorite.mount(app, { meteorite = m })
        assert.is_nil(by_path(app)["/public/style.css"])
      end)
      _G.METEORITE_BUILD_MODE = previous
      routes.registry = original
      assert.truthy(ok, err)
    end)

    it("serves the Ballad bundle in a release build and advertises its chunks", function()
      local routes = require("hydronium_dom.server.meteorite_routes")
      local original = routes.client_chunks
      routes.client_chunks = function() return { "/__hydronium/client/runtime-abc.lua" } end
      local previous = rawget(_G, "METEORITE_BUILD_MODE")
      local ok, err = pcall(function()
        _G.METEORITE_BUILD_MODE = "release-hybrid"
        local app, m = fake()
        meteorite.mount(app, { meteorite = m })
        local route = by_path(app)["/__hydronium/client/:path*"]
        assert.truthy(route and route.handler.kind == "dir" and route.handler.opts.immutable)
        _G.METEORITE_BUILD_MODE = "hybrid_dev"
        app, m = fake()
        meteorite.mount(app, { meteorite = m })
        assert.is_nil(by_path(app)["/__hydronium/client/:path*"], "development never boots from a (possibly stale) bundle")
      end)
      _G.METEORITE_BUILD_MODE = previous
      routes.client_chunks = original
      assert.truthy(ok, err)
    end)

    it("rejects something that is not a Meteorite app", function()
      assert.has_error(function() meteorite.mount({}, {}) end)
    end)
  end)
end)
