#!/usr/bin/env python3
"""
Hydronium LUAX LSP Client
Automated JSON-RPC LSP client driving lua-language-server over stdio with
Content-Length framing, asynchronous notification queuing, 1-based/0-based
coordinate translation, and lifecycle management.
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple, Union

def resolve_luals_path() -> Optional[str]:
    """Return a runnable LuaLS executable without assuming a developer home."""
    candidates = []
    if os.environ.get("LUA_LS_PATH"):
        candidates.append(os.environ["LUA_LS_PATH"])
    from_path = shutil.which("lua-language-server")
    if from_path:
        candidates.append(from_path)
    # Mason is a useful local fallback, not a requirement of the harness.
    candidates.append(os.path.expanduser("~/.local/share/nvim/mason/bin/lua-language-server"))
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None

class LspClient:
    def __init__(self, server_path: Optional[str] = None, cwd: Optional[str] = None):
        self.server_path = server_path or resolve_luals_path()
        self.cwd = cwd or os.getcwd()
        self.process: Optional[subprocess.Popen] = None
        self.reader_thread: Optional[threading.Thread] = None
        self.running = False
        self._request_id = 0
        self._lock = threading.Lock()
        self._pending_requests: Dict[int, Tuple[threading.Event, Dict[str, Any]]] = {}
        self._diagnostics: Dict[str, List[Dict[str, Any]]] = {}
        self._diagnostics_events: Dict[str, threading.Event] = {}
        self._notifications: List[Dict[str, Any]] = []
        self._log_messages: List[str] = []

    # -------------------------------------------------------------------------
    # Coordinate Translation Utilities
    # -------------------------------------------------------------------------

    @staticmethod
    def to_lsp_pos(line_1b: int, col_1b: int) -> Dict[str, int]:
        """Convert 1-based (line, col) to LSP 0-based position dict."""
        return {"line": max(0, line_1b - 1), "character": max(0, col_1b - 1)}

    @staticmethod
    def from_lsp_pos(pos: Dict[str, int]) -> Tuple[int, int]:
        """Convert LSP 0-based position dict to 1-based (line, col)."""
        return pos["line"] + 1, pos["character"] + 1

    @classmethod
    def to_lsp_range(cls, start_line: int, start_col: int, end_line: int, end_col: int) -> Dict[str, Any]:
        """Convert 1-based start and end to LSP 0-based range."""
        return {
            "start": cls.to_lsp_pos(start_line, start_col),
            "end": cls.to_lsp_pos(end_line, end_col)
        }

    @classmethod
    def from_lsp_range(cls, rng: Dict[str, Any]) -> Tuple[Tuple[int, int], Tuple[int, int]]:
        """Convert LSP 0-based range to 1-based ((start_l, start_c), (end_l, end_c))."""
        start = cls.from_lsp_pos(rng["start"])
        end = cls.from_lsp_pos(rng["end"])
        return start, end

    # -------------------------------------------------------------------------
    # Lifecycle & Transport
    # -------------------------------------------------------------------------

    def start(self):
        """Start the LuaLS subprocess and background reader thread."""
        if self.running:
            return
        if not self.server_path:
            raise RuntimeError(
                "lua-language-server is unavailable; set LUA_LS_PATH or add it to PATH"
            )

        cmd = [self.server_path]
        self.process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self.cwd,
            bufsize=0
        )
        self.running = True

        self.reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self.reader_thread.start()

    def _read_loop(self):
        """Read Content-Length framed JSON-RPC messages from server stdout."""
        stdout = self.process.stdout
        while self.running and stdout:
            try:
                # Read headers until empty line "\r\n"
                content_length = None
                while True:
                    line = stdout.readline()
                    if not line:
                        self.running = False
                        return
                    line_str = line.decode("utf-8", errors="replace").strip()
                    if not line_str:
                        # Blank line indicates end of headers
                        break
                    if line_str.lower().startswith("content-length:"):
                        content_length = int(line_str.split(":", 1)[1].strip())

                if content_length is None:
                    continue

                # Read JSON body of exact length
                body_bytes = stdout.read(content_length)
                if not body_bytes or len(body_bytes) < content_length:
                    self.running = False
                    return

                msg = json.loads(body_bytes.decode("utf-8", errors="replace"))
                self._handle_message(msg)

            except Exception as e:
                if self.running:
                    sys.stderr.write(f"[LSP Client Reader Error]: {e}\n")
                break

    def _handle_message(self, msg: Dict[str, Any]):
        """Route incoming JSON-RPC message to pending request or notification queue."""
        # 1. Server Request (has both id and method)
        if "id" in msg and "method" in msg:
            req_id = msg["id"]
            method = msg["method"]
            if method == "workspace/configuration":
                items = msg.get("params", {}).get("items", [])
                result = [{} for _ in items]
                self._send_raw({"jsonrpc": "2.0", "id": req_id, "result": result})
            elif method == "client/registerCapability":
                self._send_raw({"jsonrpc": "2.0", "id": req_id, "result": None})
            else:
                self._send_raw({"jsonrpc": "2.0", "id": req_id, "result": None})
            return

        # 2. Response to client request (has id, no method)
        if "id" in msg and msg["id"] is not None:
            req_id = msg["id"]
            with self._lock:
                pending = self._pending_requests.get(req_id)
            if pending:
                event, box = pending
                box["response"] = msg
                event.set()
            return

        # 3. Notification from server (no id, has method)
        if "method" in msg:
            method = msg["method"]
            params = msg.get("params", {})
            self._notifications.append(msg)

            if method == "textDocument/publishDiagnostics":
                uri = params.get("uri")
                diags = params.get("diagnostics", [])
                with self._lock:
                    self._diagnostics[uri] = diags
                    if uri in self._diagnostics_events:
                        self._diagnostics_events[uri].set()
            elif method == "window/logMessage":
                self._log_messages.append(params.get("message", ""))

    def _send_raw(self, payload: Dict[str, Any]):
        """Encode and write Content-Length framed JSON payload to server stdin."""
        if not self.process or not self.process.stdin:
            raise RuntimeError("LSP client process not running")

        encoded = json.dumps(payload).encode("utf-8")
        header = f"Content-Length: {len(encoded)}\r\n\r\n".encode("utf-8")
        with self._lock:
            try:
                self.process.stdin.write(header)
                self.process.stdin.write(encoded)
                self.process.stdin.flush()
            except BrokenPipeError:
                self.running = False
                raise RuntimeError("LSP client stdin pipe broken")

    def send_request(self, method: str, params: Optional[Dict[str, Any]] = None, timeout: float = 10.0) -> Any:
        """Send JSON-RPC request and synchronously await response."""
        with self._lock:
            self._request_id += 1
            req_id = self._request_id
            event = threading.Event()
            box: Dict[str, Any] = {}
            self._pending_requests[req_id] = (event, box)

        msg = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": method,
            "params": params or {}
        }
        self._send_raw(msg)

        if not event.wait(timeout):
            with self._lock:
                self._pending_requests.pop(req_id, None)
            raise TimeoutError(f"Request {method} (id={req_id}) timed out after {timeout}s")

        with self._lock:
            self._pending_requests.pop(req_id, None)

        response = box.get("response", {})
        if "error" in response:
            raise RuntimeError(f"LSP error in {method}: {response['error']}")
        return response.get("result")

    def send_notification(self, method: str, params: Optional[Dict[str, Any]] = None):
        """Send JSON-RPC notification (no response expected)."""
        msg = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {}
        }
        self._send_raw(msg)

    # -------------------------------------------------------------------------
    # Standard LSP Protocol Operations
    # -------------------------------------------------------------------------

    def initialize(self, root_path: str, trust_by_client: bool = True) -> Dict[str, Any]:
        """Send initialize request and initialized notification."""
        self.start()
        root_uri = f"file://{os.path.abspath(root_path)}"
        params = {
            "processId": os.getpid(),
            "rootPath": os.path.abspath(root_path),
            "rootUri": root_uri,
            "capabilities": {
                "workspace": {
                    "applyEdit": True,
                    "workspaceFolders": True,
                    "configuration": True,
                },
                "textDocument": {
                    "synchronization": {
                        "openClose": True,
                        "change": 1,  # Full sync
                    },
                    "completion": {
                        "completionItem": {
                            "snippetSupport": True,
                            "documentationFormat": ["markdown", "plaintext"],
                        }
                    },
                    "hover": {
                        "contentFormat": ["markdown", "plaintext"]
                    },
                    "definition": {
                        "linkSupport": True
                    },
                    "rename": {
                        "prepareSupport": True
                    },
                    "publishDiagnostics": {
                        "relatedInformation": True,
                        "tagSupport": {"valueSet": [1, 2]}
                    }
                }
            },
            "initializationOptions": {
                "trustByClient": trust_by_client,
            },
            "workspaceFolders": [
                {"name": os.path.basename(root_path), "uri": root_uri}
            ]
        }
        res = self.send_request("initialize", params, timeout=15.0)
        self.send_notification("initialized", {})
        return res

    def open_document(self, uri: str, text: str, language_id: str = "lua", version: int = 1):
        """Send textDocument/didOpen notification."""
        self.send_notification("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": language_id,
                "version": version,
                "text": text
            }
        })

    def change_document(self, uri: str, text: str, version: int = 2):
        """Send textDocument/didChange notification (full sync)."""
        self.send_notification("textDocument/didChange", {
            "textDocument": {
                "uri": uri,
                "version": version
            },
            "contentChanges": [
                {"text": text}
            ]
        })

    def close_document(self, uri: str):
        """Send textDocument/didClose notification."""
        self.send_notification("textDocument/didClose", {
            "textDocument": {
                "uri": uri
            }
        })

    def completion(self, uri: str, line_1b: int, col_1b: int, timeout: float = 10.0) -> Any:
        """Query textDocument/completion using 1-based coordinates."""
        params = {
            "textDocument": {"uri": uri},
            "position": self.to_lsp_pos(line_1b, col_1b)
        }
        return self.send_request("textDocument/completion", params, timeout=timeout)

    def hover(self, uri: str, line_1b: int, col_1b: int, timeout: float = 10.0) -> Any:
        """Query textDocument/hover using 1-based coordinates."""
        params = {
            "textDocument": {"uri": uri},
            "position": self.to_lsp_pos(line_1b, col_1b)
        }
        return self.send_request("textDocument/hover", params, timeout=timeout)

    def definition(self, uri: str, line_1b: int, col_1b: int, timeout: float = 10.0) -> Any:
        """Query textDocument/definition using 1-based coordinates."""
        params = {
            "textDocument": {"uri": uri},
            "position": self.to_lsp_pos(line_1b, col_1b)
        }
        return self.send_request("textDocument/definition", params, timeout=timeout)

    def rename(self, uri: str, line_1b: int, col_1b: int, new_name: str, timeout: float = 10.0) -> Any:
        """Query textDocument/rename using 1-based coordinates."""
        params = {
            "textDocument": {"uri": uri},
            "position": self.to_lsp_pos(line_1b, col_1b),
            "newName": new_name
        }
        return self.send_request("textDocument/rename", params, timeout=timeout)

    def get_diagnostics(self, uri: str) -> List[Dict[str, Any]]:
        """Get latest cached diagnostics for URI."""
        with self._lock:
            return list(self._diagnostics.get(uri, []))

    def wait_for_diagnostics(
        self,
        uri: str,
        timeout: float = 10.0,
        predicate: Optional[Callable[[List[Dict[str, Any]]], bool]] = None
    ) -> List[Dict[str, Any]]:
        """Block until diagnostics arrive for URI and optional predicate returns True."""
        start_time = time.time()
        with self._lock:
            if uri not in self._diagnostics_events:
                self._diagnostics_events[uri] = threading.Event()
            ev = self._diagnostics_events[uri]

        while time.time() - start_time < timeout:
            with self._lock:
                current = list(self._diagnostics.get(uri, []))
            if current and (predicate is None or predicate(current)):
                return current
            ev.wait(timeout=0.2)
            ev.clear()

        with self._lock:
            return list(self._diagnostics.get(uri, []))

    def clear_diagnostics(self, uri: Optional[str] = None):
        """Clear diagnostics cache."""
        with self._lock:
            if uri:
                self._diagnostics.pop(uri, None)
                if uri in self._diagnostics_events:
                    self._diagnostics_events[uri].clear()
            else:
                self._diagnostics.clear()
                for ev in self._diagnostics_events.values():
                    ev.clear()

    def shutdown(self):
        """Cleanly shutdown the language server."""
        if not self.running:
            return
        try:
            self.send_request("shutdown", None, timeout=3.0)
        except Exception:
            pass
        try:
            self.send_notification("exit", {})
        except Exception:
            pass
        self.running = False
        if self.process:
            try:
                self.process.terminate()
                self.process.wait(timeout=2.0)
            except Exception:
                try:
                    self.process.kill()
                except Exception:
                    pass
        if self.reader_thread and self.reader_thread.is_alive():
            self.reader_thread.join(timeout=1.0)
