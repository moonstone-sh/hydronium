#!/usr/bin/env python3
"""
Hydronium Developer Experience (DX) Benchmark Suite
Compares Lexical `d` DOM descriptor approach against legacy Global `__luax_intrinsic` catalog:
- LuaLS Workspace Memory (RSS in MB)
- Member Completion Latency: <d.| vs __luax_intrinsic.|
- Prop Completion Latency: <d.button | vs __luax_intrinsic.button |
- Percentiles: p50, p95, max
"""

import os
import subprocess
import sys
import time
from typing import Any, Callable, Dict, List, Tuple

# Ensure project root is in sys.path
WORKSPACE_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, WORKSPACE_PATH)

from tests.luax.lsp_client import LspClient

def get_process_rss_mb(pid: int) -> float:
    """Return process Resident Set Size (RSS) in megabytes."""
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]).decode().strip()
        return int(out) / 1024.0
    except Exception:
        return 0.0

def compute_percentiles(samples: List[float]) -> Tuple[float, float, float]:
    """Return (p50, p95, max) from a list of latencies."""
    sorted_samples = sorted(samples)
    n = len(sorted_samples)
    p50 = sorted_samples[int(n * 0.50)]
    p95 = sorted_samples[int(n * 0.95)]
    max_val = max(sorted_samples)
    return p50, p95, max_val

def measure_operation(op_fn: Callable[[], Any], iterations: int = 40) -> Tuple[float, float, float]:
    """Measure latency distribution across N iterations."""
    latencies = []
    # Warmup
    for _ in range(5):
        op_fn()

    for _ in range(iterations):
        t0 = time.perf_counter()
        op_fn()
        t1 = time.perf_counter()
        latencies.append((t1 - t0) * 1000.0)  # ms
    return compute_percentiles(latencies)

def main():
    print("==================================================================")
    print("      Hydronium LUAX DX Benchmark: Lexical d vs Global Intrinsic  ")
    print("==================================================================")

    client = LspClient(cwd=WORKSPACE_PATH)
    try:
        t0 = time.time()
        client.initialize(WORKSPACE_PATH)
        init_dur_ms = (time.time() - t0) * 1000.0
        time.sleep(1.0)
        pid = client.process.pid
        baseline_mem_mb = get_process_rss_mb(pid)
        print(f"Server Initialized: {init_dur_ms:.2f} ms | Baseline LuaLS Memory: {baseline_mem_mb:.2f} MB\n")

        # -------------------------------------------------------------
        # 1. Lexical `d` Approach
        # -------------------------------------------------------------
        doc_lexical_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/bench_lexical_d.luax"
        doc_lexical_src = """local hydronium = require("hydronium")
local d = hydronium.d

local function LexicalComponent()
  return (
    <d.main class="app-root">
      <d.
    </d.main>
  )
end
return LexicalComponent
"""
        client.open_document(doc_lexical_uri, doc_lexical_src, language_id="lua", version=1)
        time.sleep(0.4)

        # Measure member completion on <d.| (Line 7, Col 10)
        p50_lex_mem, p95_lex_mem, max_lex_mem = measure_operation(
            lambda: client.completion(doc_lexical_uri, 7, 10, timeout=5.0),
            iterations=30
        )

        # Update to prop completion: <d.button 
        doc_lexical_props = """local hydronium = require("hydronium")
local d = hydronium.d

local function LexicalComponent()
  return (
    <d.main class="app-root">
      <d.button 
    </d.main>
  )
end
return LexicalComponent
"""
        client.change_document(doc_lexical_uri, doc_lexical_props, version=2)
        time.sleep(0.4)

        # Measure prop completion on <d.button | (Line 7, Col 17)
        p50_lex_prop, p95_lex_prop, max_lex_prop = measure_operation(
            lambda: client.completion(doc_lexical_uri, 7, 17, timeout=5.0),
            iterations=30
        )

        lexical_mem_mb = get_process_rss_mb(pid)
        client.close_document(doc_lexical_uri)

        # -------------------------------------------------------------
        # 2. Legacy Global `__luax_intrinsic` Catalog Approach
        # -------------------------------------------------------------
        doc_global_uri = f"file://{WORKSPACE_PATH}/tests/fixtures/bench_global_catalog.lua"
        doc_global_src = """local function GlobalComponent()
  return (
    __luax_intrinsic.
  )
end
return GlobalComponent
"""
        client.open_document(doc_global_uri, doc_global_src, language_id="lua", version=1)
        time.sleep(0.4)

        # Measure member completion on __luax_intrinsic.| (Line 3, Col 22)
        p50_glob_mem, p95_glob_mem, max_glob_mem = measure_operation(
            lambda: client.completion(doc_global_uri, 3, 22, timeout=5.0),
            iterations=30
        )

        # Update to prop completion: __luax_intrinsic.button({ 
        doc_global_props = """local function GlobalComponent()
  return (
    __luax_intrinsic.button({ 
  )
end
return GlobalComponent
"""
        client.change_document(doc_global_uri, doc_global_props, version=2)
        time.sleep(0.4)

        # Measure prop completion on __luax_intrinsic.button({ | (Line 3, Col 31)
        p50_glob_prop, p95_glob_prop, max_glob_prop = measure_operation(
            lambda: client.completion(doc_global_uri, 3, 31, timeout=5.0),
            iterations=30
        )

        global_mem_mb = get_process_rss_mb(pid)
        client.close_document(doc_global_uri)

        # -------------------------------------------------------------
        # 3. Comparative Summary Table
        # -------------------------------------------------------------
        print("### Comparative Performance Summary")
        print("| Metric / Operation                 | Lexical `d` Namespace | Global `__luax_intrinsic` | Delta / Status |")
        print("|------------------------------------|-----------------------|---------------------------|----------------|")
        print(f"| Workspace Memory (RSS)             | {lexical_mem_mb:19.2f} MB | {global_mem_mb:23.2f} MB | {lexical_mem_mb - global_mem_mb:+12.2f} MB |")
        print(f"| Member Completion p50              | {p50_lex_mem:19.2f} ms | {p50_glob_mem:23.2f} ms | {p50_lex_mem - p50_glob_mem:+12.2f} ms |")
        print(f"| Member Completion p95              | {p95_lex_mem:19.2f} ms | {p95_glob_mem:23.2f} ms | {p95_lex_mem - p95_glob_mem:+12.2f} ms |")
        print(f"| Member Completion Max              | {max_lex_mem:19.2f} ms | {max_glob_mem:23.2f} ms | {max_lex_mem - max_glob_mem:+12.2f} ms |")
        print(f"| Prop Completion p50                | {p50_lex_prop:19.2f} ms | {p50_glob_prop:23.2f} ms | {p50_lex_prop - p50_glob_prop:+12.2f} ms |")
        print(f"| Prop Completion p95                | {p95_lex_prop:19.2f} ms | {p95_glob_prop:23.2f} ms | {p95_lex_prop - p95_glob_prop:+12.2f} ms |")
        print(f"| Prop Completion Max                | {max_lex_prop:19.2f} ms | {max_glob_prop:23.2f} ms | {max_lex_prop - max_glob_prop:+12.2f} ms |")

        print("\n### Budget & Responsiveness Validation")
        ok = True
        if p50_lex_mem < 50.0:
            print(f"  ✓ PASS Lexical member completion p50 ({p50_lex_mem:.2f} ms) < 50 ms")
        else:
            print(f"  ✗ FAIL Lexical member completion p50 ({p50_lex_mem:.2f} ms) >= 50 ms")
            ok = False

        if p50_lex_prop < 50.0:
            print(f"  ✓ PASS Lexical prop completion p50 ({p50_lex_prop:.2f} ms) < 50 ms")
        else:
            print(f"  ✗ FAIL Lexical prop completion p50 ({p50_lex_prop:.2f} ms) >= 50 ms")
            ok = False

        if lexical_mem_mb < 300.0:
            print(f"  ✓ PASS Workspace memory ({lexical_mem_mb:.2f} MB) < 300 MB limit")
        else:
            print(f"  ✗ FAIL Workspace memory ({lexical_mem_mb:.2f} MB) >= 300 MB limit")
            ok = False

        if not ok:
            sys.exit(1)
        print("\nDX benchmarks PASSED successfully.")

    finally:
        client.shutdown()

if __name__ == "__main__":
    main()
