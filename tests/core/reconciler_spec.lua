local h = require("tests.runner")
local H = require("hydronium")

local describe, it = h.describe, h.it
local assert = h.assert

describe("Core: Reconciler & Child Diffing", function()

  describe("Keyed child diffing & host node reuse", function()
    it("preserves host node identity when reordering items", function()
      local root = H.create_test_root()

      root:render(H.h("ul", nil,
        H.h("li", { key = "a", id = "node_a" }, "A"),
        H.h("li", { key = "b", id = "node_b" }, "B")
      ))

      local hostA1 = root:find({ id = "node_a" })
      local hostB1 = root:find({ id = "node_b" })
      assert.is_not_nil(hostA1)
      assert.is_not_nil(hostB1)

      -- Swap order
      root:update(H.h("ul", nil,
        H.h("li", { key = "b", id = "node_b" }, "B"),
        H.h("li", { key = "a", id = "node_a" }, "A")
      ))

      local hostA2 = root:find({ id = "node_a" })
      local hostB2 = root:find({ id = "node_b" })

      -- Host node instances MUST be reused (identity preserved)
      assert.equal(hostA1.id, hostA2.id)
      assert.equal(hostB1.id, hostB2.id)

      -- Host DOM order must reflect swap
      local ul = root:find("ul")
      assert.equal(ul.children[1].id, hostB1.id)
      assert.equal(ul.children[2].id, hostA1.id)
    end)

    it("handles keyed child insertion (head, middle, tail)", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h("span", { key = "b", id = "B" }, "B")
      ))
      assert.equal(root:text(), "B")

      -- Insert at head and tail
      root:update(H.h("div", nil,
        H.h("span", { key = "a", id = "A" }, "A"),
        H.h("span", { key = "b", id = "B" }, "B"),
        H.h("span", { key = "d", id = "D" }, "D")
      ))
      assert.equal(root:text(), "ABD")

      -- Insert in middle
      root:update(H.h("div", nil,
        H.h("span", { key = "a", id = "A" }, "A"),
        H.h("span", { key = "b", id = "B" }, "B"),
        H.h("span", { key = "c", id = "C" }, "C"),
        H.h("span", { key = "d", id = "D" }, "D")
      ))
      assert.equal(root:text(), "ABCD")
    end)

    it("handles keyed child removal (head, middle, tail)", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h("span", { key = "a" }, "A"),
        H.h("span", { key = "b" }, "B"),
        H.h("span", { key = "c" }, "C"),
        H.h("span", { key = "d" }, "D")
      ))
      assert.equal(root:text(), "ABCD")

      -- Remove head ("a") and tail ("d")
      root:update(H.h("div", nil,
        H.h("span", { key = "b" }, "B"),
        H.h("span", { key = "c" }, "C")
      ))
      assert.equal(root:text(), "BC")

      -- Remove middle ("b")
      root:update(H.h("div", nil,
        H.h("span", { key = "c" }, "C")
      ))
      assert.equal(root:text(), "C")

      -- Remove all
      root:update(H.h("div", nil))
      assert.equal(root:text(), "")
    end)

    it("handles keyed reversing", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h("span", { key = "1", id = "n1" }, "1"),
        H.h("span", { key = "2", id = "n2" }, "2"),
        H.h("span", { key = "3", id = "n3" }, "3"),
        H.h("span", { key = "4", id = "n4" }, "4"),
        H.h("span", { key = "5", id = "n5" }, "5")
      ))
      assert.equal(root:text(), "12345")

      local n1 = root:find({ id = "n1" })
      local n5 = root:find({ id = "n5" })

      root:update(H.h("div", nil,
        H.h("span", { key = "5", id = "n5" }, "5"),
        H.h("span", { key = "4", id = "n4" }, "4"),
        H.h("span", { key = "3", id = "n3" }, "3"),
        H.h("span", { key = "2", id = "n2" }, "2"),
        H.h("span", { key = "1", id = "n1" }, "1")
      ))
      assert.equal(root:text(), "54321")

      -- Confirm node instances were reused
      assert.equal(root:find({ id = "n1" }).id, n1.id)
      assert.equal(root:find({ id = "n5" }).id, n5.id)
    end)

    it("handles mixed complex operations (inserts, removals, reorders)", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h("span", { key = "a", id = "A" }, "A"),
        H.h("span", { key = "b", id = "B" }, "B"),
        H.h("span", { key = "c", id = "C" }, "C"),
        H.h("span", { key = "d", id = "D" }, "D")
      ))
      assert.equal(root:text(), "ABCD")

      -- b and d removed; x and y added; c moved before a
      root:update(H.h("div", nil,
        H.h("span", { key = "x", id = "X" }, "X"),
        H.h("span", { key = "c", id = "C" }, "C"),
        H.h("span", { key = "a", id = "A" }, "A"),
        H.h("span", { key = "y", id = "Y" }, "Y")
      ))

      assert.equal(root:text(), "XCAY")
      assert.is_nil(root:find({ id = "B" }))
      assert.is_nil(root:find({ id = "D" }))
      assert.is_not_nil(root:find({ id = "X" }))
      assert.is_not_nil(root:find({ id = "Y" }))
    end)
  end)

  describe("Unkeyed diffing", function()
    it("updates existing host node in-place when tag matches", function()
      local root = H.create_test_root()

      root:render(H.h("div", { class = "old" }, "Initial Text"))
      local initialDiv = root:find("div")

      root:update(H.h("div", { class = "new" }, "Updated Text"))
      local updatedDiv = root:find("div")

      assert.equal(initialDiv.id, updatedDiv.id)
      assert.equal(updatedDiv.props.class, "new")
      assert.equal(root:text(), "Updated Text")
    end)

    it("replaces host node when tag differs", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil, H.h("p", { id = "para" }, "Paragraph")))
      local oldP = root:find({ id = "para" })

      root:update(H.h("div", nil, H.h("span", { id = "span" }, "Span")))
      local newSpan = root:find({ id = "span" })

      assert.is_nil(root:find({ id = "para" }))
      assert.is_not_nil(newSpan)
      assert.not_equal(oldP.id, newSpan.id)
      assert.equal(root:text(), "Span")
    end)

    it("handles list growth and shrink by index", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil, "one", "two"))
      assert.equal(root:text(), "onetwo")

      -- Grow
      root:update(H.h("div", nil, "one", "two", "three", "four"))
      assert.equal(root:text(), "onetwothreefour")

      -- Shrink
      root:update(H.h("div", nil, "one"))
      assert.equal(root:text(), "one")
    end)
  end)

  describe("Fragment unwrapping", function()
    it("unwraps fragment children directly into host container", function()
      local root = H.create_test_root()

      root:render(H.h("div", { id = "parent" },
        H.h(H.Fragment, nil,
          H.h("span", { id = "c1" }, "First"),
          H.h("span", { id = "c2" }, "Second")
        )
      ))

      local parentNode = root:find({ id = "parent" })
      assert.equal(#parentNode.children, 2)
      assert.equal(parentNode.children[1].props.id, "c1")
      assert.equal(parentNode.children[2].props.id, "c2")
    end)

    it("handles fragment expanding and shrinking", function()
      local root = H.create_test_root()

      root:render(H.h("div", nil,
        H.h(H.Fragment, nil, "A")
      ))
      assert.equal(root:text(), "A")

      root:update(H.h("div", nil,
        H.h(H.Fragment, nil, "A", "B", "C")
      ))
      assert.equal(root:text(), "ABC")

      root:update(H.h("div", nil,
        H.h(H.Fragment, nil, "C")
      ))
      assert.equal(root:text(), "C")
    end)
  end)

  describe("Ref binding and unbinding", function()
    it("binds object ref on commit and unbinds on unmount", function()
      local refObj = H.create_ref()
      local root = H.create_test_root()

      assert.is_nil(refObj.current)

      root:render(H.h("button", { ref = refObj, id = "btn" }, "Click"))
      local btnNode = root:find({ id = "btn" })

      assert.is_not_nil(refObj.current)
      assert.equal(refObj.current.id, btnNode.id)

      root:unmount()
      assert.is_nil(refObj.current)
    end)

    it("invokes callback ref with host node on mount and nil on unmount", function()
      local calls = {}
      local callbackRef = function(node)
        table.insert(calls, node and node.id or nil)
      end

      local root = H.create_test_root()
      root:render(H.h("input", { ref = callbackRef, id = "input" }))

      local inputNode = root:find({ id = "input" })
      assert.same(calls, { inputNode.id })

      root:unmount()
      assert.same(calls, { inputNode.id, nil })
    end)

    it("swaps ref bindings when element ref changes across renders", function()
      local refA = H.create_ref()
      local refB = H.create_ref()

      local root = H.create_test_root()
      root:render(H.h("div", { ref = refA, id = "d" }))

      local divNode = root:find({ id = "d" })
      assert.equal(refA.current.id, divNode.id)
      assert.is_nil(refB.current)

      -- Switch to refB
      root:update(H.h("div", { ref = refB, id = "d" }))

      assert.is_nil(refA.current)
      assert.equal(refB.current.id, divNode.id)
    end)
  end)

  describe("Duplicate key resilience", function()
    it("reconciles sibling elements with duplicate keys without crashing", function()
      local root = H.create_test_root()

      -- Intentionally provide duplicate keys among siblings
      root:render(H.h("ul", nil,
        H.h("li", { key = "dup", id = "item1" }, "First Dup"),
        H.h("li", { key = "dup", id = "item2" }, "Second Dup"),
        H.h("li", { key = "unique", id = "item3" }, "Unique")
      ))

      assert.equal(root:text(), "First DupSecond DupUnique")

      -- Re-render with updated duplicate keys
      root:update(H.h("ul", nil,
        H.h("li", { key = "unique", id = "item3" }, "Unique"),
        H.h("li", { key = "dup", id = "item1" }, "First Dup Updated"),
        H.h("li", { key = "dup", id = "item2" }, "Second Dup Updated")
      ))

      assert.equal(root:text(), "UniqueFirst Dup UpdatedSecond Dup Updated")
    end)
  end)

end)
