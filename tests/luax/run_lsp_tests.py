#!/usr/bin/env python3
"""
Hydronium LUAX Real LSP Integration Tests & Latency Benchmarks
Drives lua-language-server through tests/luax/lsp_client.py.

Verifies:
1. LSP Lifecycle: initialize & server capabilities
2. Member completion: <d.| suggests button, input, div, h1, span, etc.
3. Prop completion: <d.button | suggests onClick, disabled, type, etc.
4. Contextual callback typing:
   - <d.button onClick={function(ev) ...}> -> ev.currentTarget is HTMLButtonElement
   - <d.input onInput={function(ev) ...}> -> ev.currentTarget is HTMLInputElement
5. Ref typing: <d.input ref={ref}> -> ref prop is typed with HTMLInputElement
6. Go-to-Definition: <d.button jumps to types/dom/init.d.lua
7. Rename: renaming 'd' -> 'dom' updates occurrences across the document
8. Diagnostics: undefined symbol preserves exact 1:1 line & column coordinates
9. LSP Latency: p50, p95, max benchmark for hover, completion, definition
"""

import os
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

# Ensure project root is in sys.path
WORKSPACE_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, WORKSPACE_PATH)

from tests.luax.lsp_client import LspClient, resolve_luals_path

class TestRunner:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.results: List[Tuple[str, bool, Optional[str]]] = []

    def check(self, name: str, condition: bool, err_msg: str = ""):
        if condition:
            self.passed += 1
            print(f"  ✓ PASS {name}")
            self.results.append((name, True, None))
        else:
            self.failed += 1
            print(f"  ✗ FAIL {name} - {err_msg}")
            self.results.append((name, False, err_msg))

def wait_for_hover_ready(client: LspClient, uri: str, line: int, col: int, max_attempts: int = 15) -> Any:
    for _ in range(max_attempts):
        res = client.hover(uri, line, col, timeout=5.0)
        val = res.get("contents", {}).get("value", "") if res else ""
        if "Workspace loading" not in val and len(val) > 0:
            return res
        time.sleep(0.3)
    return client.hover(uri, line, col, timeout=5.0)

def run_tests():
    print("=== Running Hydronium LUAX Real LuaLS Integration Suite ===")
    server_path = resolve_luals_path()
    if not server_path:
        print("SKIP: lua-language-server is unavailable. Set LUA_LS_PATH or add it to PATH.")
        return 0
    print(f"LuaLS executable: {server_path}")
    runner = TestRunner()
    client = LspClient(server_path=server_path, cwd=WORKSPACE_PATH)

    try:
        # 1. Initialize
        t0 = time.time()
        init_res = client.initialize(WORKSPACE_PATH)
        init_time = (time.time() - t0) * 1000
        caps = init_res.get("capabilities", {})
        runner.check(
            "LSP Lifecycle > initialize responds with server capabilities",
            "completionProvider" in caps and "hoverProvider" in caps and "definitionProvider" in caps,
            f"Expected completion, hover, and definition capabilities, got {list(caps.keys())}"
        )
        print(f"    (Initialized in {init_time:.2f} ms)")

        # Wait briefly for workspace indexing
        time.sleep(1.0)

        # 2. Member completion on <d.|
        doc_member_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_member_comp.luax"
        doc_member_src = """local function App()
  return (
    <d.
  )
end
return App
"""
        client.open_document(doc_member_uri, doc_member_src, language_id="lua", version=1)
        time.sleep(0.5)
        # Line 3 is '    <d.' -> column 8 is right after '.'
        comp_member = client.completion(doc_member_uri, 3, 8, timeout=5.0)
        items_member = comp_member.get("items", []) if isinstance(comp_member, dict) else (comp_member or [])
        labels_member = set(it.get("label") for it in items_member)
        expected_members = {"button", "input", "div", "h1", "span"}
        runner.check(
            "Member Completion > <d.| suggests DOM intrinsic tags",
            expected_members.issubset(labels_member),
            f"Expected {expected_members} in member labels, got sample: {list(labels_member)[:10]}"
        )
        client.close_document(doc_member_uri)

        # 3. Prop completion on <d.button |
        doc_prop_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_prop_comp.luax"
        doc_prop_src = """local function App()
  return (
    <d.button""" + " \n" + """  )
end
return App
"""
        client.open_document(doc_prop_uri, doc_prop_src, language_id="lua", version=1)
        time.sleep(0.5)
        # Line 3 is '    <d.button ' -> column 15 is right after the space
        comp_prop = client.completion(doc_prop_uri, 3, 15, timeout=5.0)
        items_prop = comp_prop.get("items", []) if isinstance(comp_prop, dict) else (comp_prop or [])
        labels_prop = set(it.get("label", "").rstrip("?") for it in items_prop)
        expected_props = {"onClick", "disabled", "type"}
        runner.check(
            "Prop Completion > <d.button | suggests HTMLButtonProps attributes",
            expected_props.issubset(labels_prop),
            f"Expected {expected_props} in prop labels, got sample: {list(labels_prop)[:10]}"
        )
        client.close_document(doc_prop_uri)

        # 3b. Member completion on <d.lua.| and <d.js.| (islands -- see
        # docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md). Inserted before the
        # Contextual Typing block below because a pre-existing, unrelated
        # failure there (ev.currentTarget hover resolves to `unknown`
        # instead of HTMLButtonElement/HTMLInputElement, then a
        # subsequent hover request times out and aborts the whole
        # process) would otherwise prevent these from ever running.
        # Flagged, not fixed here -- out of scope for islands/d.lua/d.js
        # typing work.
        doc_lua_ns_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_lua_ns_comp.luax"
        doc_lua_ns_src = """local function App()
  return (
    <d.lua.
  )
end
return App
"""
        client.open_document(doc_lua_ns_uri, doc_lua_ns_src, language_id="lua", version=1)
        time.sleep(0.5)
        # Line 3 is '    <d.lua.' -> column 12 is right after the second '.'
        comp_lua_ns = client.completion(doc_lua_ns_uri, 3, 12, timeout=5.0)
        items_lua_ns = comp_lua_ns.get("items", []) if isinstance(comp_lua_ns, dict) else (comp_lua_ns or [])
        labels_lua_ns = set(it.get("label") for it in items_lua_ns)
        runner.check(
            "Island Member Completion > <d.lua.| suggests island and mount",
            {"island", "mount"}.issubset(labels_lua_ns),
            f"Expected island/mount in member labels, got: {list(labels_lua_ns)[:10]}"
        )
        client.close_document(doc_lua_ns_uri)

        doc_js_ns_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_js_ns_comp.luax"
        doc_js_ns_src = """local function App()
  return (
    <d.js.
  )
end
return App
"""
        client.open_document(doc_js_ns_uri, doc_js_ns_src, language_id="lua", version=1)
        time.sleep(0.5)
        # Line 3 is '    <d.js.' -> column 11 is right after the second '.'
        comp_js_ns = client.completion(doc_js_ns_uri, 3, 11, timeout=5.0)
        items_js_ns = comp_js_ns.get("items", []) if isinstance(comp_js_ns, dict) else (comp_js_ns or [])
        labels_js_ns = set(it.get("label") for it in items_js_ns)
        runner.check(
            "Island Member Completion > <d.js.| suggests island and script",
            {"island", "script"}.issubset(labels_js_ns),
            f"Expected island/script in member labels, got: {list(labels_js_ns)[:10]}"
        )
        client.close_document(doc_js_ns_uri)

        # 3c. Prop completion on <d.lua.island |> and <d.js.island |>
        doc_lua_island_prop_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_lua_island_prop_comp.luax"
        doc_lua_island_prop_src = """local function App()
  return (
    <d.lua.island""" + " \n" + """  )
end
return App
"""
        client.open_document(doc_lua_island_prop_uri, doc_lua_island_prop_src, language_id="lua", version=1)
        time.sleep(0.5)
        # Line 3 is '    <d.lua.island ' -> column 19 is right after the space
        comp_lua_island_prop = client.completion(doc_lua_island_prop_uri, 3, 19, timeout=5.0)
        items_lua_island_prop = comp_lua_island_prop.get("items", []) if isinstance(comp_lua_island_prop, dict) else (comp_lua_island_prop or [])
        labels_lua_island_prop = set(it.get("label", "").rstrip("?") for it in items_lua_island_prop)
        runner.check(
            "Island Prop Completion > <d.lua.island | suggests hydrate/root/key",
            {"hydrate", "root", "key"}.issubset(labels_lua_island_prop),
            f"Expected hydrate/root/key in prop labels, got: {list(labels_lua_island_prop)[:10]}"
        )
        client.close_document(doc_lua_island_prop_uri)

        doc_js_island_prop_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_js_island_prop_comp.luax"
        doc_js_island_prop_src = """local function App()
  return (
    <d.js.island""" + " \n" + """  )
end
return App
"""
        client.open_document(doc_js_island_prop_uri, doc_js_island_prop_src, language_id="lua", version=1)
        time.sleep(0.5)
        # Line 3 is '    <d.js.island ' -> column 18 is right after the space
        comp_js_island_prop = client.completion(doc_js_island_prop_uri, 3, 18, timeout=5.0)
        items_js_island_prop = comp_js_island_prop.get("items", []) if isinstance(comp_js_island_prop, dict) else (comp_js_island_prop or [])
        labels_js_island_prop = set(it.get("label", "").rstrip("?") for it in items_js_island_prop)
        runner.check(
            "Island Prop Completion > <d.js.island | suggests module/mode/hydrate/props/binds",
            {"module", "mode", "hydrate", "props", "binds"}.issubset(labels_js_island_prop),
            f"Expected module/mode/hydrate/props/binds in prop labels, got: {list(labels_js_island_prop)[:10]}"
        )
        client.close_document(doc_js_island_prop_uri)

        # 4. Contextual callback typing
        doc_cb_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_dom_callbacks.luax"
        doc_cb_src = """local function EventDemo()
  return (
    <div>
      <d.button onClick={function(ev)
        local btnTarget = ev.currentTarget
        print(btnTarget)
      end}>
        Click Me
      </d.button>

      <d.input onInput={function(ev)
        local inputTarget = ev.currentTarget
        print(inputTarget)
      end} />
    </div>
  )
end
return EventDemo
"""
        client.open_document(doc_cb_uri, doc_cb_src, language_id="lua", version=1)
        time.sleep(0.5)

        # Hover on button ev.currentTarget: Line 5, Col 30
        hov_dom_btn = wait_for_hover_ready(client, doc_cb_uri, 5, 30)
        hov_dom_btn_val = hov_dom_btn.get("contents", {}).get("value", "") if hov_dom_btn else ""
        runner.check(
            "Contextual Typing > <d.button onClick={...}> ev.currentTarget is typed as HTMLButtonElement",
            "HTMLButtonElement" in hov_dom_btn_val,
            f"Expected HTMLButtonElement in hover, got: {hov_dom_btn_val}"
        )

        # Hover on input ev.currentTarget: Line 12, Col 15
        hov_dom_inp = wait_for_hover_ready(client, doc_cb_uri, 12, 15)
        hov_dom_inp_val = hov_dom_inp.get("contents", {}).get("value", "") if hov_dom_inp else ""
        runner.check(
            "Contextual Typing > <d.input onInput={...}> ev.currentTarget is typed as HTMLInputElement",
            "HTMLInputElement" in hov_dom_inp_val,
            f"Expected HTMLInputElement in hover, got: {hov_dom_inp_val}"
        )
        client.close_document(doc_cb_uri)

        # 5. Ref typing on <d.input ref={...}>
        doc_ref_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_ref_demo.luax"
        doc_ref_src = """local function RefDemo()
  return (
    <d.input ref={function(el)
      local inputEl = el
    end} />
  )
end
return RefDemo
"""
        client.open_document(doc_ref_uri, doc_ref_src, language_id="lua", version=1)
        time.sleep(0.5)

        # Hover on inputEl at Line 4, Col 21
        hov_ref_el = wait_for_hover_ready(client, doc_ref_uri, 4, 21)
        hov_ref_el_val = hov_ref_el.get("contents", {}).get("value", "") if hov_ref_el else ""

        # Hover on ref prop at Line 3, Col 15
        hov_ref_prop = wait_for_hover_ready(client, doc_ref_uri, 3, 15)
        hov_ref_prop_val = hov_ref_prop.get("contents", {}).get("value", "") if hov_ref_prop else ""

        runner.check(
            "Ref Typing > <d.input ref={...}> resolves HTMLInputElement for ref attribute or callback",
            "HTMLInputElement" in hov_ref_el_val or "HTMLInputElement" in hov_ref_prop_val,
            f"Expected HTMLInputElement in ref hover, got el: {hov_ref_el_val}, prop: {hov_ref_prop_val}"
        )
        client.close_document(doc_ref_uri)

        # 6. Go to Definition on <d.button jumping to types/dom/init.d.lua
        doc_def_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_def_jump.luax"
        doc_def_src = """local function App()
  return (
    <d.button class="btn">
      Save
    </d.button>
  )
end
return App
"""
        client.open_document(doc_def_uri, doc_def_src, language_id="lua", version=1)
        time.sleep(0.5)
        # Line 3 is '    <d.button class="btn">' -> col 9 is inside 'button'
        defn_res = client.definition(doc_def_uri, 3, 9, timeout=5.0)
        target_uris = []
        if isinstance(defn_res, list):
            for loc in defn_res:
                target_uris.append(loc.get("targetUri") or loc.get("uri", ""))
        runner.check(
            "Go to Definition > <d.button jumps to dom/init.d.lua",
            any("dom/init.d.lua" in u for u in target_uris),
            f"Expected targetUri containing dom/init.d.lua, got: {target_uris}"
        )
        client.close_document(doc_def_uri)

        # 7. Rename 'd' -> 'dom' across document
        doc_ren_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_rename.luax"
        doc_ren_src = """local d = require("hydronium.dom")
local function App()
  return (
    <div>
      <d.button>Click</d.button>
      <d.input />
    </div>
  )
end
return App
"""
        client.open_document(doc_ren_uri, doc_ren_src, language_id="lua", version=1)
        time.sleep(0.5)
        # Line 1, Col 7 is 'd'
        ren_res = client.rename(doc_ren_uri, 1, 7, "dom", timeout=5.0)
        doc_changes = ren_res.get("changes", {}).get(doc_ren_uri, []) if ren_res else []
        runner.check(
            "Rename > 'd' -> 'dom' targets multiple occurrences across document",
            len(doc_changes) >= 3,
            f"Expected >= 3 rename changes for 'd', got {len(doc_changes)}: {doc_changes}"
        )
        client.close_document(doc_ren_uri)

        # 8. 1:1 Diagnostic coordinates
        doc_diag_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_diagnostics.luax"
        doc_diag_src = """local function ComponentWithDiag()
  local valid = 42
  local bad = non_existent_symbol_err
  return <div class="container">{valid}</div>
end
return ComponentWithDiag
"""
        client.clear_diagnostics(doc_diag_uri)
        client.open_document(doc_diag_uri, doc_diag_src, language_id="lua", version=1)

        diags = client.wait_for_diagnostics(
            doc_diag_uri,
            timeout=8.0,
            predicate=lambda d_list: any(d.get("code") == "undefined-global" for d in d_list)
        )

        target_diag = None
        for d in diags:
            if d.get("code") == "undefined-global" and "non_existent_symbol_err" in d.get("message", ""):
                target_diag = d
                break

        runner.check(
            "Diagnostics > detects undefined symbol in .luax",
            target_diag is not None,
            f"Expected undefined-global diagnostic for non_existent_symbol_err, got: {diags}"
        )

        if target_diag:
            start_l, start_c = LspClient.from_lsp_pos(target_diag["range"]["start"])
            runner.check(
                "Diagnostics > preserves exact 1:1 line coordinate in .luax",
                start_l == 3,
                f"Expected line 3, got line {start_l}"
            )
            runner.check(
                "Diagnostics > preserves exact 1:1 column coordinate in .luax",
                start_c == 15,
                f"Expected column 15, got column {start_c}"
            )
        client.close_document(doc_diag_uri)

        # 9. Real LSP Latency Benchmarking
        print("\n--- LSP Real-Time Latency Benchmarks ---")
        bench_doc_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_bench.luax"
        bench_doc_src = """local function BenchView()
  local title = "Hydronium Benchmark"
  local count = 100
  return (
    <div class="bench-view">
      <h1>{title}</h1>
      <span>Count: {count}</span>
    </div>
  )
end
return BenchView
"""
        client.open_document(bench_doc_uri, bench_doc_src, language_id="lua", version=1)
        time.sleep(0.5)

        num_samples = 25

        def measure_latencies(name: str, op_fn) -> Tuple[float, float, float]:
            latencies = []
            for _ in range(num_samples):
                t_start = time.perf_counter()
                op_fn()
                t_dur = (time.perf_counter() - t_start) * 1000.0  # ms
                latencies.append(t_dur)
            latencies.sort()
            p50 = latencies[int(len(latencies) * 0.50)]
            p95 = latencies[int(len(latencies) * 0.95)]
            max_lat = max(latencies)
            return p50, p95, max_lat

        p50_hov, p95_hov, max_hov = measure_latencies(
            "hover",
            lambda: client.hover(bench_doc_uri, 2, 10, timeout=5.0)
        )
        p50_comp, p95_comp, max_comp = measure_latencies(
            "completion",
            lambda: client.completion(bench_doc_uri, 2, 10, timeout=5.0)
        )
        p50_def, p95_def, max_def = measure_latencies(
            "definition",
            lambda: client.definition(bench_doc_uri, 2, 10, timeout=5.0)
        )

        client.close_document(bench_doc_uri)

        print(f"  Operation        | Samples | p50 Latency | p95 Latency | Max Latency")
        print(f"  -----------------+---------+-------------+-------------+------------")
        print(f"  textDoc/hover    | {num_samples:7d} | {p50_hov:9.2f} ms | {p95_hov:9.2f} ms | {max_hov:8.2f} ms")
        print(f"  textDoc/complete | {num_samples:7d} | {p50_comp:9.2f} ms | {p95_comp:9.2f} ms | {max_comp:8.2f} ms")
        print(f"  textDoc/def      | {num_samples:7d} | {p50_def:9.2f} ms | {p95_def:9.2f} ms | {max_def:8.2f} ms")

        runner.check(
            "LSP Latency > hover p50 is responsive (< 100ms)",
            p50_hov < 100.0,
            f"p50 was {p50_hov:.2f} ms"
        )
        runner.check(
            "LSP Latency > completion p50 is responsive (< 100ms)",
            p50_comp < 100.0,
            f"p50 was {p50_comp:.2f} ms"
        )
        runner.check(
            "LSP Latency > definition p50 is responsive (< 100ms)",
            p50_def < 100.0,
            f"p50 was {p50_def:.2f} ms"
        )

    except Exception as exc:
        runner.check("LSP harness > completes without transport failure", False, repr(exc))
    finally:
        client.shutdown()

    print("\n============================================================")
    total = runner.passed + runner.failed
    print(f"SUMMARY: {total} Total | {runner.passed} Passed | {runner.failed} Failed")
    if runner.failed > 0:
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(run_tests())
