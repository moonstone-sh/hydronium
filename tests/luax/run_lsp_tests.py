#!/usr/bin/env python3
"""
Hydronium LUAX Real LSP Integration Tests & Latency Benchmarks
Drives lua-language-server (v3.18.2-dev) through tests/luax/lsp_client.py.

Verifies:
1. LSP initialize & didOpen on .luax files
2. Standard Lua expressions hover, completion, and definition in .luax
3. Typed component prop completion and definition resolution
4. Typed DOM intrinsic callbacks (HTMLButtonElement, HTMLInputElement on currentTarget)
5. Invalid symbol diagnostics with exact 1:1 .luax coordinate ranges
6. Real LSP latency benchmarking (p50, p95, max)
"""

import os
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

# Ensure project root is in sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from tests.luax.lsp_client import LspClient

WORKSPACE_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))

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

def run_tests():
    print("=== Running Hydronium LUAX Real LuaLS Integration Suite ===")
    runner = TestRunner()
    client = LspClient(cwd=WORKSPACE_PATH)

    try:
        # 1. Initialize
        t0 = time.time()
        init_res = client.initialize(WORKSPACE_PATH)
        init_time = (time.time() - t0) * 1000
        caps = init_res.get("capabilities", {})
        runner.check(
            "LSP Lifecycle > initialize responds with server capabilities",
            "completionProvider" in caps and "hoverProvider" in caps,
            f"Expected completion and hover capabilities, got {list(caps.keys())}"
        )
        print(f"    (Initialized in {init_time:.2f} ms)")

        # Wait briefly for workspace indexing
        time.sleep(1.0)

        # 2. didOpen & Lua Expressions in .luax
        doc1_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_expressions.luax"
        doc1_src = """local function UserProfileCard()
  local user = { profile = { name = "Ada Lovelace", role = "Mathematician", age = 36 } }
  local user_name = user.profile.name
  return (
    <div class="user-card">
      <h1>{user_name}</h1>
      <span>{user.profile.role}</span>
    </div>
  )
end
return UserProfileCard
"""
        client.open_document(doc1_uri, doc1_src, language_id="lua", version=1)

        def wait_for_hover_ready(uri: str, line: int, col: int, max_attempts: int = 10) -> Any:
            for _ in range(max_attempts):
                res = client.hover(uri, line, col, timeout=5.0)
                val = res.get("contents", {}).get("value", "") if res else ""
                if "Workspace loading" not in val and len(val) > 0:
                    return res
                time.sleep(0.3)
            return client.hover(uri, line, col, timeout=5.0)

        # Hover on user.profile.name at line 3, col 27 ('name')
        hov1 = wait_for_hover_ready(doc1_uri, 3, 27)
        hov1_val = hov1.get("contents", {}).get("value", "") if hov1 else ""
        runner.check(
            "Lua Expressions in .luax > hover infers variable field type",
            "string" in hov1_val or "Ada Lovelace" in hov1_val,
            f"Expected string / Ada Lovelace in hover, got: {hov1_val}"
        )

        # Completion on user.profile.
        doc1_change = """local function UserProfileCard()
  local user = { profile = { name = "Ada Lovelace", role = "Mathematician", age = 36 } }
  local prop = user.profile.
  return <div />
end
"""
        client.change_document(doc1_uri, doc1_change, version=2)
        time.sleep(0.4)
        comp1 = client.completion(doc1_uri, 3, 29, timeout=5.0)
        items1 = comp1.get("items", []) if isinstance(comp1, dict) else (comp1 or [])
        labels1 = set(it.get("label") for it in items1)
        runner.check(
            "Lua Expressions in .luax > completion suggests table fields",
            {"name", "role", "age"}.issubset(labels1),
            f"Expected name, role, age in labels, got: {labels1}"
        )

        client.close_document(doc1_uri)

        # 3. Typed Component Prop Completion & Definition
        doc2_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_props.luax"
        doc2_src = """---@class ButtonProps
---@field variant "primary" | "secondary" | "danger"
---@field size "sm" | "md" | "lg"
---@field disabled boolean?

---@param props ButtonProps
local function Button(props)
  return <button class={props.variant}>{props.children}</button>
end

local function App()
  return (
    <div>
      <Button variant="primary" size="md" />
    </div>
  )
end
return App
"""
        client.open_document(doc2_uri, doc2_src, language_id="lua", version=1)
        time.sleep(0.5)

        # Test hover on Button component: Line 14, Col 9
        hov_btn = wait_for_hover_ready(doc2_uri, 14, 9)
        hov_btn_val = hov_btn.get("contents", {}).get("value", "") if hov_btn else ""
        runner.check(
            "Typed Component Props > hover resolves component or lowering helper",
            "Button" in hov_btn_val or "__luax_component" in hov_btn_val,
            f"Expected Button or __luax_component in hover, got: {hov_btn_val}"
        )

        # Test definition jump from <Button to local function Button
        defn_btn = client.definition(doc2_uri, 14, 9, timeout=5.0)
        runner.check(
            "Typed Component Props > go-to-definition resolves component declaration",
            isinstance(defn_btn, list) and len(defn_btn) > 0,
            f"Expected definition locations, got {defn_btn}"
        )

        client.close_document(doc2_uri)

        # 4. Typed DOM Intrinsic Event Callbacks
        doc3_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_dom_callbacks.luax"
        doc3_src = """local function EventDemo()
  return (
    <div>
      <button onClick={function(ev)
        local btnTarget = ev.currentTarget
        print(btnTarget)
      end}>
        Click Me
      </button>

      <input onInput={function(ev)
        local inputTarget = ev.currentTarget
        print(inputTarget)
      end} />
    </div>
  )
end
return EventDemo
"""
        client.open_document(doc3_uri, doc3_src, language_id="lua", version=1)
        time.sleep(0.5)

        # Hover on button ev.currentTarget (Line 5, Col 28)
        hov_dom_btn = wait_for_hover_ready(doc3_uri, 5, 28)
        hov_dom_btn_val = hov_dom_btn.get("contents", {}).get("value", "") if hov_dom_btn else ""
        runner.check(
            "Typed DOM Callbacks > button onClick event.currentTarget is typed as HTMLButtonElement",
            "HTMLButtonElement" in hov_dom_btn_val,
            f"Expected HTMLButtonElement in hover, got: {hov_dom_btn_val}"
        )

        # Hover on input ev.currentTarget (Line 12, Col 30)
        hov_dom_inp = wait_for_hover_ready(doc3_uri, 12, 30)
        hov_dom_inp_val = hov_dom_inp.get("contents", {}).get("value", "") if hov_dom_inp else ""
        runner.check(
            "Typed DOM Callbacks > input onInput event.currentTarget is typed as HTMLInputElement",
            "HTMLInputElement" in hov_dom_inp_val,
            f"Expected HTMLInputElement in hover, got: {hov_dom_inp_val}"
        )

        client.close_document(doc3_uri)

        # 5. Invalid Prop & Symbol Diagnostics with Exact .luax Coordinates
        doc4_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/test_diagnostics.luax"
        doc4_src = """local function ComponentWithDiag()
  local valid = 42
  local bad = non_existent_symbol_err
  return <div class="container">{valid}</div>
end
return ComponentWithDiag
"""
        client.clear_diagnostics(doc4_uri)
        client.open_document(doc4_uri, doc4_src, language_id="lua", version=1)

        # Wait for diagnostic on non_existent_symbol_err
        diags = client.wait_for_diagnostics(
            doc4_uri,
            timeout=8.0,
            predicate=lambda d_list: any(d.get("code") == "undefined-global" for d in d_list)
        )

        target_diag = None
        for d in diags:
            if d.get("code") == "undefined-global" and "non_existent_symbol_err" in d.get("message", ""):
                target_diag = d
                break

        runner.check(
            "LSP Diagnostics > detects undefined symbol in .luax",
            target_diag is not None,
            f"Expected undefined-global diagnostic for non_existent_symbol_err, got: {diags}"
        )

        if target_diag:
            start_l, start_c = LspClient.from_lsp_pos(target_diag["range"]["start"])
            # In doc4_src:
            # Line 3 is '  local bad = non_existent_symbol_err + 10'
            # 'non_existent_symbol_err' starts at character index 15 (1-based)
            runner.check(
                "LSP Diagnostics > preserves exact 1:1 line coordinate in .luax",
                start_l == 3,
                f"Expected line 3, got line {start_l}"
            )
            runner.check(
                "LSP Diagnostics > preserves exact 1:1 column coordinate in .luax",
                start_c == 15,
                f"Expected column 15, got column {start_c}"
            )

        client.close_document(doc4_uri)

        # 6. Real LSP Latency Benchmarking
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

    finally:
        client.shutdown()

    print("\n============================================================")
    total = runner.passed + runner.failed
    print(f"SUMMARY: {total} Total | {runner.passed} Passed | {runner.failed} Failed")
    if runner.failed > 0:
        sys.exit(1)

if __name__ == "__main__":
    run_tests()
