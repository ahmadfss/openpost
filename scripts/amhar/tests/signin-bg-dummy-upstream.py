#!/usr/bin/env python3
"""Tiny upstream used by signin-bg-overlay.sh. Not used in production."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import os

HTML = b"""<!doctype html><html><head><meta charset="utf-8"><title>OpenPost</title></head>
<body><main data-slot="standalone-shell"><div data-slot="card">form</div></main></body></html>"""
JS = b"console.log('app');"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path.startswith("/api/v1/ready"):
            body = b'{"status":"ok","echo":"</head>"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.endswith(".js"):
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript")
            self.send_header("Content-Length", str(len(JS)))
            self.end_headers()
            self.wfile.write(JS)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(HTML)))
        self.send_header("X-Upstream-Fwd-Proto", self.headers.get("X-Forwarded-Proto", ""))
        self.send_header("X-Upstream-Fwd-Host", self.headers.get("X-Forwarded-Host", ""))
        self.end_headers()
        self.wfile.write(HTML)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ["OPENPOST_INTERNAL_PORT"])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
