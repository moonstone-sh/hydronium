#!/usr/bin/env python3
"""
Meteorite + Hydronium Live HTTP Gateway Server
Listens on http://127.0.0.1:8080 and serves dynamic SSR requests
by routing them through the real Meteorite HTTP application graph and Hydronium SSR engine.
"""

import http.server
import socketserver
import subprocess
import json
import os
import sys

PORT = int(os.environ.get("PORT", "8080"))
HOST = "127.0.0.1"

METEORITE_DIR = "/Users/extrordinaire/Workbench/user/meteorite"
APP_FILE = "../hydronium/examples/meteorite_ssr/src/main.lua"

class MeteoriteHTTPHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def do_PUT(self):
        self.handle_request("PUT")

    def do_DELETE(self):
        self.handle_request("DELETE")

    def handle_request(self, method):
        # Read request body if present
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else ""

        path = self.path

        # Invoke through real Meteorite in-process router via Lua CLI
        lua_cmd = [
            "moon", "exec", "lua", "src/cli/main.lua",
            "invoke", "--json", APP_FILE, method, path, body
        ]

        try:
            res = subprocess.run(
                lua_cmd,
                cwd=METEORITE_DIR,
                capture_output=True,
                text=True,
                check=False
            )

            # Find JSON line from invoke output
            json_output = None
            for line in res.stdout.splitlines():
                if line.startswith("{") and "meteorite.invoke.v0" in line:
                    try:
                        json_output = json.loads(line)
                        break
                    except Exception:
                        pass

            if json_output and "response" in json_output:
                resp = json_output["response"]
                status = resp.get("status", 200)
                content_type = resp.get("content_type", "text/html; charset=utf-8")
                response_body = resp.get("body", "").encode("utf-8")

                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(response_body)))
                self.send_header("X-Powered-By", "Meteorite + Hydronium SSR")
                self.send_header("Access-Control-Allow-Origin", "*")

                headers = resp.get("headers", {})
                if isinstance(headers, dict):
                    for k, v in headers.items():
                        self.send_header(k, str(v))

                self.end_headers()
                self.wfile.write(response_body)
            else:
                # Fallback error
                err_msg = f"Meteorite SSR error:\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}"
                self.send_response(500)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(err_msg)))
                self.end_headers()
                self.wfile.write(err_msg.encode("utf-8"))

        except Exception as e:
            err_msg = f"Gateway Exception: {e}"
            self.send_response(500)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(err_msg)))
            self.end_headers()
            self.wfile.write(err_msg.encode("utf-8"))

    def log_message(self, format, *args):
        sys.stderr.write(f"[Meteorite SSR] {self.address_string()} - {format % args}\n")
        sys.stderr.flush()

class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True

def main():
    server = ThreadedHTTPServer((HOST, PORT), MeteoriteHTTPHandler)
    print("=" * 70)
    print(f"🚀 Meteorite + Hydronium .luax SSR Server is LIVE!")
    print(f"   URL: http://{HOST}:{PORT}/")
    print(f"   Routes available:")
    print(f"     • http://{HOST}:{PORT}/              (SSR Home Page)")
    print(f"     • http://{HOST}:{PORT}/packages/meteorite  (SSR Dynamic Params)")
    print(f"     • http://{HOST}:{PORT}/error-test    (ErrorBoundary Recovery)")
    print(f"     • http://{HOST}:{PORT}/api/health    (JSON API)")
    print("=" * 70)
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        server.shutdown()

if __name__ == "__main__":
    main()
