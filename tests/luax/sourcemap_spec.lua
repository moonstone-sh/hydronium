-- SourceMap V3 and Base64 VLQ Test Suite
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local sourcemap = require("hydronium.luax.sourcemap")
local luax = require("hydronium.luax")

describe("LUAX: Source Map V3 & Base64 VLQ", function()

  describe("Base64 VLQ Encoding & Decoding", function()
    it("encodes and decodes positive numbers including 0 and boundaries", function()
      local test_numbers = { 0, 1, 15, 16, 31, 32, 63, 64, 127, 255, 1000, 65535, 1000000 }
      for _, num in ipairs(test_numbers) do
        local encoded = sourcemap.encode_vlq(num)
        assert.is_string(encoded)
        assert.truthy(#encoded > 0)
        local decoded = sourcemap.decode_vlq(encoded)
        assert.equal(decoded, num, "VLQ round-trip mismatch for positive number: " .. num)
      end
    end)

    it("encodes and decodes negative numbers accurately", function()
      local test_numbers = { -1, -15, -16, -31, -32, -63, -64, -127, -255, -1000, -65535, -1000000 }
      for _, num in ipairs(test_numbers) do
        local encoded = sourcemap.encode_vlq(num)
        assert.is_string(encoded)
        assert.truthy(#encoded > 0)
        local decoded = sourcemap.decode_vlq(encoded)
        assert.equal(decoded, num, "VLQ round-trip mismatch for negative number: " .. num)
      end
    end)

    it("handles multiple VLQ numbers in a contiguous sequence", function()
      local nums = { 0, 0, 5, 12, -3 }
      local encoded_parts = {}
      for _, n in ipairs(nums) do
        table.insert(encoded_parts, sourcemap.encode_vlq(n))
      end
      local combined = table.concat(encoded_parts)

      local decoded_nums = {}
      local pos = 1
      while pos <= #combined do
        local val, next_pos = sourcemap.decode_vlq(combined, pos)
        table.insert(decoded_nums, val)
        pos = next_pos
      end

      assert.equal(#decoded_nums, #nums)
      for i = 1, #nums do
        assert.equal(decoded_nums[i], nums[i])
      end
    end)
  end)

  describe("SourceMap Coordinate Round-Tripping", function()
    it("encodes and decodes coordinate mappings correctly", function()
      local sm = sourcemap.create({
        file = "bundle.lua",
        sources = { "component.luax" },
      })

      -- Add a series of line/column coordinates
      -- gen_line, gen_col, orig_line, orig_col, source_index
      sm:add_mapping(1, 1, 1, 1, 0)
      sm:add_mapping(1, 15, 1, 10, 0)
      sm:add_mapping(2, 5, 3, 7, 0)
      sm:add_mapping(3, 10, 5, 2, 0)

      local mappings_str = sm:encode_mappings()
      assert.is_string(mappings_str)
      assert.truthy(#mappings_str > 0)

      -- Decode mappings
      local decoded = sourcemap.decode_mappings(mappings_str)
      assert.is_table(decoded)
      assert.truthy(decoded[1])
      assert.truthy(decoded[2])
      assert.truthy(decoded[3])

      -- Lookup line 1, col 1
      local pt1 = sourcemap.lookup(decoded, 1, 1)
      assert.truthy(pt1)
      assert.equal(pt1.orig_line, 1)
      assert.equal(pt1.orig_col, 1)

      -- Lookup line 1, col 18 (should map to segment at col 15)
      local pt1_b = sourcemap.lookup(decoded, 1, 18)
      assert.truthy(pt1_b)
      assert.equal(pt1_b.orig_line, 1)
      assert.equal(pt1_b.orig_col, 10)

      -- Lookup line 2, col 8 (should map to segment at line 3, col 7)
      local pt2 = sourcemap.lookup(decoded, 2, 8)
      assert.truthy(pt2)
      assert.equal(pt2.orig_line, 3)
      assert.equal(pt2.orig_col, 7)

      -- Lookup line 3, col 12
      local pt3 = sourcemap.lookup(decoded, 3, 12)
      assert.truthy(pt3)
      assert.equal(pt3.orig_line, 5)
      assert.equal(pt3.orig_col, 2)
    end)
  end)

  describe("Compiler Source Map Integration", function()
    it("generates valid SourceMap V3 on full compilation", function()
      local src = [[
        local function Card(props)
          return <div class="card">
            <span>{props.title}</span>
          </div>
        end
      ]]

      local res = luax.compile(src, { filename = "Card.luax" })

      assert.truthy(res.sourcemap)
      assert.is_string(res.map_json or res.json_map)

      local map_table = res.sourcemap:to_table()
      assert.equal(map_table.version, 3)
      assert.truthy(map_table.mappings)
      assert.truthy(#map_table.mappings > 0)
      assert.equal(map_table.sources[1], "Card.luax")

      -- Decode compiler mappings and verify roundtrip
      local decoded = sourcemap.decode_mappings(map_table.mappings)
      assert.truthy(#decoded > 0)

      -- Ensure that some generated lines map back to original lines
      local mapped_count = 0
      for _, line_segs in pairs(decoded) do
        for _, seg in ipairs(line_segs) do
          if seg.orig_line then
            mapped_count = mapped_count + 1
          end
        end
      end
      assert.truthy(mapped_count >= 1)
    end)
  end)

end)
