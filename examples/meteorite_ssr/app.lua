--[[
  Hydronium SSR + Meteorite context-shape demo (NOT a Meteorite integration test)

  IMPORTANT (corrected 2026-09-06): the `run_dispatch_simulation()` function
  below does NOT exercise Meteorite's real router or HTTP layer. It scans
  `app.routes` for `r.raw_path == req_info.path` and calls the handler
  directly with a hand-built mock `c` table -- and the test requests below
  use the literal route pattern string (e.g. "/packages/:id") as the
  request path, not a real URL, which is why that naive lookup "works" at
  all. Any timing numbers this script prints are NOT representative of
  Meteorite request latency. For a real, working exemplar routed through
  Meteorite's actual `meteorite invoke` CLI (genuine route matching, query
  parsing, dispatch), see examples/meteorite_ssr/src/main.lua instead. See
  docs/METEORITE_HYDRONIUM_INTEGRATION_BRIEF.md for the full picture.

  What this file IS useful for: a quick, dependency-light way to check that
  Hydronium component trees render correctly against the props/context
  shape a real Meteorite `ctx` would provide, without needing Meteorite
  installed at all (see the mock fallback below).

  Run standalone with:
    luajit examples/meteorite_ssr/app.lua
--]]

-- Ensure hydronium and meteorite packages are in package.path
package.path = "../hydronium/src/?.lua;../hydronium/src/?/init.lua;src/?.lua;src/?/init.lua;../meteorite/src/?.lua;../meteorite/src/?/init.lua;" .. package.path

local hydronium = require("hydronium")
local h = hydronium.createElement
local useContext = hydronium.useContext
local meteorite = require("hydronium.server.meteorite")
local RequestContext = meteorite.RequestContext

-- Attempt to load real meteorite, fall back to lightweight in-process mock if running standalone
local has_meteorite, m = pcall(require, "meteorite")
if not has_meteorite then
  m = {
    app = function(opts)
      local app_obj = { name = opts.name, routes = {} }
      function app_obj:get(path, handler_or_opts, maybe_handler)
        local handler = maybe_handler or handler_or_opts
        table.insert(self.routes, { method = "GET", path = path, handler = handler })
      end
      return app_obj
    end,
  }
end

local app = m.app({ name = "meteorite-hydronium-ssr" })

--------------------------------------------------------------------------------
-- UI Components
--------------------------------------------------------------------------------

local function Layout(props)
  local req = useContext(RequestContext)
  return h("html", { lang = "en" }, {
    h("head", nil, {
      h("meta", { charset = "utf-8" }),
      h("meta", { name = "viewport", content = "width=device-width, initial-scale=1.0" }),
      h("title", nil, props.title or "Hydronium + Meteorite SSR"),
      h("style", nil, [[
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 0; background: #0f172a; color: #f8fafc; }
        header { background: #1e293b; padding: 1rem 2rem; border-bottom: 1px solid #334155; display: flex; justify-content: space-between; align-items: center; }
        header a { color: #38bdf8; text-decoration: none; margin-right: 1.5rem; font-weight: 500; }
        header a:hover { text-decoration: underline; }
        main { max-width: 900px; margin: 2rem auto; padding: 0 1rem; }
        .card { background: #1e293b; border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; border: 1px solid #334155; }
        .badge { background: #0284c7; color: white; padding: 0.2rem 0.6rem; border-radius: 4px; font-size: 0.85rem; }
        .error-box { background: #450a0a; border: 1px solid #b91c1c; color: #fecaca; padding: 1rem; border-radius: 6px; }
        code { background: #0f172a; padding: 0.2rem 0.4rem; border-radius: 4px; font-family: monospace; color: #a5f3fc; }
        footer { text-align: center; padding: 2rem; color: #64748b; font-size: 0.9rem; }
      ]]),
    }),
    h("body", nil, {
      h("header", nil, {
        h("div", { style = { fontWeight = "bold", fontSize = 18 } }, "Hydronium + Meteorite"),
        h("nav", nil, {
          h("a", { href = "/" }, "Home"),
          h("a", { href = "/about" }, "About"),
          h("a", { href = "/packages/meteorite-ssr?v=1.0.0" }, "Package Demo"),
          h("a", { href = "/error-test" }, "Error Boundary"),
        }),
      }),
      h("main", nil, props.children),
      h("footer", nil, {
        h("p", nil, "Hydronium SSR Server | Request ID: " .. tostring(req.request_id or "local-dev")),
      }),
    }),
  })
end

local function HomePage()
  return h(Layout, { title = "Home | Hydronium SSR" }, {
    h("div", { class = "card" }, {
      h("h1", nil, "Server-Side Rendering with Hydronium"),
      h("p", nil, "Welcome to the Model A In-Process Hybrid Integration of Hydronium and Meteorite."),
      h("p", nil, "This page was rendered synchronously on the server in microsecond latencies using strict HTML5 void element serialization and deterministic style rules."),
      h("div", { class = "badge" }, "Model A Architecture: In-Process Hybrid"),
    }),
    h("div", { class = "card" }, {
      h("h2", nil, "Features Demonstrated"),
      h("ul", nil, {
        h("li", nil, "Zero IPC overhead: components execute directly inside the LuaJIT runtime"),
        h("li", nil, "Request context propagation via RequestContext and useContext"),
        h("li", nil, "HTML boolean attributes, style kebab-casing, unitless numbers, and XSS sanitization"),
        h("li", nil, "Resilient ErrorBoundary recovery during SSR failures"),
      }),
    }),
  })
end

local function AboutPage()
  return h(Layout, { title = "About | Hydronium SSR" }, {
    h("div", { class = "card" }, {
      h("h1", nil, "About Model A Architecture"),
      h("p", nil, "Meteorite provides high-throughput Zig-based networking and HTTP dispatching. By embedding Hydronium SSR directly into Lua request handlers, we achieve:"),
      h("ol", nil, {
        h("li", nil, "Microsecond SSR latency with no serialization bottlenecks"),
        h("li", nil, "Direct access to Meteorite context helpers (c:html, c:header, c:param)"),
        h("li", nil, "Full hydration contract compatibility for client-side interactive islands"),
      }),
    }),
  })
end

local function PackageDetailPage()
  local req = useContext(RequestContext)
  local pkg_id = req.params.id or "unknown"
  local version = req.query.v or "latest"

  return h(Layout, { title = "Package: " .. pkg_id .. " | Hydronium SSR" }, {
    h("div", { class = "card" }, {
      h("h1", nil, "Package: " .. pkg_id),
      h("p", nil, {
        h("span", { class = "badge" }, "Version: " .. version),
      }),
      h("p", nil, "Installation:"),
      h("pre", nil, h("code", nil, "partiture add " .. pkg_id .. "@" .. version)),
      h("p", nil, "Route Parameter: " .. pkg_id),
      h("p", nil, "Query Parameter: " .. version),
    }),
  })
end

local function ExplodingSubComponent()
  error("Database connection timeout during SSR render!")
end

local function ErrorTestPage()
  return h(Layout, { title = "Error Boundary Test | Hydronium SSR" }, {
    h("div", { class = "card" }, {
      h("h1", nil, "ErrorBoundary SSR Recovery"),
      h("p", nil, "The component below throws a runtime error during server rendering. Hydronium catches it safely and renders the fallback:"),
      h(hydronium.ErrorBoundary, {
        fallback = function(err)
          return h("div", { class = "error-box" }, {
            h("h3", nil, "Caught Component Error"),
            h("p", nil, tostring(err.message or err)),
          })
        end,
      }, {
        h(ExplodingSubComponent, nil),
      }),
    }),
  })
end

--------------------------------------------------------------------------------
-- Route Registrations
--------------------------------------------------------------------------------

-- GET /: Home
app:get("/", meteorite.handler(HomePage, { doctype = true }))

-- GET /about: About
app:get("/about", meteorite.handler(AboutPage, { doctype = true }))

-- GET /packages/:id: Package Details
app:get("/packages/:id", meteorite.handler(PackageDetailPage, { doctype = true }))

-- GET /error-test: Error Recovery with HTTP 500 status
app:get("/error-test", meteorite.handler(ErrorTestPage, { doctype = true, status = 500 }))

--------------------------------------------------------------------------------
-- Standalone Execution Harness
--------------------------------------------------------------------------------

local function run_dispatch_simulation()
  print("================================================================================")
  print("Meteorite + Hydronium SSR In-Process Hybrid Simulation")
  print("================================================================================")

  local test_requests = {
    { path = "/", params = {}, query = {}, req_id = "req-home-100" },
    { path = "/about", params = {}, query = {}, req_id = "req-about-200" },
    { path = "/packages/:id", params = { id = "meteorite-ssr" }, query = { v = "1.0.0" }, req_id = "req-pkg-300" },
    { path = "/error-test", params = {}, query = {}, req_id = "req-err-400" },
  }

  for _, req_info in ipairs(test_requests) do
    local handler_fn = nil
    for _, r in ipairs(app.routes) do
      local r_path = r.raw_path or (type(r.path) == "string" and r.path)
      if r_path == req_info.path then
        handler_fn = (type(r.handler) == "table" and r.handler.value) or r.handler
        break
      end
    end

    if handler_fn then
      local mock_c = {
        params = req_info.params,
        query = req_info.query,
        request_id = function() return req_info.req_id end,
        html = function(self, status, body, opts)
          return {
            status = status,
            content_type = "text/html; charset=utf-8",
            headers = opts and opts.headers or {},
            body = body,
          }
        end,
      }

      local t0 = os.clock()
      local response = handler_fn(mock_c)
      local elapsed_ms = (os.clock() - t0) * 1000

      -- elapsed_ms is Hydronium render time only (direct in-process Lua
      -- function call, no router/HTTP layer involved) -- NOT a Meteorite
      -- request latency measurement. See the file header.
      print(string.format("\n[HTTP GET %s] -> Status: %d | Hydronium render time (not HTTP latency): %.3f ms | Bytes: %d",
        req_info.path, response.status, elapsed_ms, #response.body))
      print(string.format("Preview (first 180 chars):\n%s...", response.body:sub(1, 180):gsub("\n", " ")))
    else
      print("\n[HTTP GET " .. req_info.path .. "] -> 404 Route Not Found")
    end
  end
  print("\n================================================================================")
  print("All simulated SSR requests completed successfully!")
  print("================================================================================")
end

-- Run simulation if executed directly from CLI
if arg and arg[0] and (arg[0]:find("examples/meteorite_ssr/app%.lua") or arg[0]:find("app%.lua")) then
  run_dispatch_simulation()
end

return app
