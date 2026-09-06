local h = require("tests.runner")
local H = require("hydronium")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Test Renderer & Host Simulation", function()

  describe("TestHost & Lifecycle audit log", function()
    it("creates host nodes and records operations in lifecycle audit log", function()
      local host = H.test.createTestHost()
      assert.is_table(host.log)
      assert.equal(#host:get_log(), 0)

      local root = H.create_test_root(host)
      root:render(H.h("div", { id = "app" },
        H.h("h1", nil, "Title"),
        H.h("p", nil, "Body text")
      ))

      local log = host:get_log()
      assert.truthy(#log > 0)

      -- Verify logged operations
      local ops = {}
      for _, entry in ipairs(log) do
        ops[entry.op] = true
      end

      assert.truthy(ops["create_node"])
      assert.truthy(ops["create_text_node"])
      assert.truthy(ops["append_child"])

      -- Clear log
      host:clear_log()
      assert.equal(#host:get_log(), 0)
    end)
  end)

  describe("TestRoot tree structural representation", function()
    it("returns clean JSON/table structural tree representation via root:tree()", function()
      local root = H.create_test_root()
      root:render(H.h("section", { class = "hero" },
        H.h("h1", { id = "heading" }, "Welcome to Hydronium"),
        H.h("button", { type = "button" }, "Get Started")
      ))

      local tree = root:tree()
      assert.is_table(tree)
      assert.equal(tree.type, "element")
      assert.equal(tree.tag, "section")
      assert.equal(tree.props.class, "hero")
      assert.equal(#tree.children, 2)

      local h1Tree = tree.children[1]
      assert.equal(h1Tree.tag, "h1")
      assert.equal(h1Tree.props.id, "heading")
      assert.equal(h1Tree.children[1].text, "Welcome to Hydronium")

      local btnTree = tree.children[2]
      assert.equal(btnTree.tag, "button")
      assert.equal(btnTree.props.type, "button")
      assert.equal(btnTree.children[1].text, "Get Started")
    end)
  end)

  describe("root:find and root:find_all query selectors", function()
    it("finds nodes by string tag name", function()
      local root = H.create_test_root()
      root:render(H.h("div", nil,
        H.h("header", nil, "Header"),
        H.h("main", nil, "Main Content"),
        H.h("footer", nil, "Footer")
      ))

      local header = root:find("header")
      assert.is_not_nil(header)
      assert.equal(header.tag, "header")

      local footer = root:find("footer")
      assert.is_not_nil(footer)
      assert.equal(footer.tag, "footer")

      assert.is_nil(root:find("nav"))
    end)

    it("finds nodes by property table", function()
      local root = H.create_test_root()
      root:render(H.h("form", nil,
        H.h("input", { type = "text", name = "username" }),
        H.h("input", { type = "password", name = "password" }),
        H.h("button", { type = "submit", id = "submit_btn" }, "Login")
      ))

      local submitBtn = root:find({ id = "submit_btn" })
      assert.is_not_nil(submitBtn)
      assert.equal(submitBtn.tag, "button")
      assert.equal(submitBtn.props.type, "submit")

      local passInput = root:find({ name = "password" })
      assert.is_not_nil(passInput)
      assert.equal(passInput.props.type, "password")
    end)

    it("finds all nodes matching query", function()
      local root = H.create_test_root()
      root:render(H.h("ul", nil,
        H.h("li", { class = "item" }, "Item 1"),
        H.h("li", { class = "item" }, "Item 2"),
        H.h("li", { class = "item" }, "Item 3")
      ))

      local items = root:find_all("li")
      assert.equal(#items, 3)
      assert.equal(items[1].props.class, "item")
      assert.equal(items[2].props.class, "item")
      assert.equal(items[3].props.class, "item")

      local byProp = root:find_all({ class = "item" })
      assert.equal(#byProp, 3)
    end)

    it("finds nodes using predicate function", function()
      local root = H.create_test_root()
      root:render(H.h("div", nil,
        H.h("span", { ["data-active"] = "true" }, "Active"),
        H.h("span", { ["data-active"] = "false" }, "Inactive")
      ))

      local activeSpan = root:find(function(node)
        return node.props and node.props["data-active"] == "true"
      end)
      assert.is_not_nil(activeSpan)
      assert.equal(activeSpan.children[1].text, "Active")
    end)
  end)

  describe("root:text extraction", function()
    it("extracts and concatenates all text content in tree", function()
      local root = H.create_test_root()
      root:render(H.h("div", nil,
        H.h("h1", nil, "Hello "),
        H.h("span", nil, "World"),
        "!"
      ))

      assert.equal(root:text(), "Hello World!")
    end)
  end)

  describe("root:update and root:unmount", function()
    it("updates root tree with new VNode", function()
      local root = H.create_test_root()
      root:render(H.h("div", { id = "v1" }, "Version 1"))
      assert.equal(root:text(), "Version 1")

      root:update(H.h("div", { id = "v2" }, "Version 2"))
      assert.equal(root:text(), "Version 2")
      assert.equal(root:find("div").props.id, "v2")
    end)

    it("unmounts tree and disposes all host nodes and scopes", function()
      local unmounted = false

      local function Child(props, scope)
        scope:defer(function()
          unmounted = true
        end)
        return H.h("span", nil, "Mounted")
      end

      local root = H.create_test_root()
      root:render(H.h(Child))

      assert.equal(root:text(), "Mounted")
      assert.falsy(unmounted)

      root:unmount()

      assert.truthy(unmounted)
      assert.equal(root:text(), "")
      assert.is_nil(root:tree())
    end)
  end)

  describe("test.act() synchronization", function()
    it("flushes signals and pending reactive effects synchronously inside act", function()
      local count, setCount = H.signal(0)

      local function ReactiveCounter()
        return H.h("div", { id = "count" }, "Count: " .. tostring(count()))
      end

      local root = H.create_test_root()
      root:render(H.h(ReactiveCounter))

      assert.equal(root:text(), "Count: 0")

      -- Multiple updates batched inside act
      H.act(function()
        setCount(1)
        setCount(2)
        setCount(5)
      end)

      -- Guaranteed to be updated synchronously upon act completion
      assert.equal(root:text(), "Count: 5")
    end)
  end)

end)
