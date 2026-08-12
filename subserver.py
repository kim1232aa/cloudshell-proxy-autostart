#!/usr/bin/env python3
# subserver.py — serve the Clash subscription YAML at exactly one secret path;
# everything else gets a bare 404 (no directory listing, no hints).
# Runs on the Cloud Shell instance, behind the named tunnel's catch-all ingress.
#
# Files (both in ~/proxy-bin):
#   sub-path   — one line, the secret URL path, e.g. /sub-0123456789abcdef...
#   sub.yaml   — the subscription content
import http.server
import pathlib

BASE = pathlib.Path.home() / "proxy-bin"
SUB_PORT = 38081

class Handler(http.server.BaseHTTPRequestHandler):
    token_path = None
    yaml_file = None

    def do_GET(self):
        if self.path == self.token_path and self.yaml_file.exists():
            body = self.yaml_file.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/yaml; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            # Clash shows an info bar off this header; we have no real counters
            self.send_header("Subscription-Userinfo",
                             "upload=0; download=0; total=107374182400; expire=0")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, *args):
        pass

def main():
    Handler.token_path = (BASE / "sub-path").read_text().strip()
    Handler.yaml_file = BASE / "sub.yaml"
    if not Handler.token_path.startswith("/"):
        raise SystemExit("sub-path must start with /")
    http.server.HTTPServer(("127.0.0.1", SUB_PORT), Handler).serve_forever()

if __name__ == "__main__":
    main()
