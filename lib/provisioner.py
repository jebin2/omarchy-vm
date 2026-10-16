#!/usr/bin/env python3
"""
Local HTTP provisioning server for Omarchy VM guest onboarding.
Serves the setup script, host public key, and clipboard bridge to the guest over QEMU SLIRP.
"""
import http.server
import os
import re
import socketserver
import sys
import urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else "."
USER_OUT_FILE = sys.argv[3] if len(sys.argv) > 3 else ".guest_user"
# Linux login names; the value is later used in ssh/runuser invocations.
USERNAME_RE = re.compile(r"[a-z_][a-z0-9_-]{0,31}")

class ProvisionHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        # Root path serves the guest setup script
        if parsed.path in ("/", ""):
            self.path = "/setup.sh"
            return super().do_GET()

        # Guest registration callback: /done?user=<username>
        if parsed.path == "/done":
            query = urllib.parse.parse_qs(parsed.query)
            user = query.get("user", [""])[0].strip()
            if not USERNAME_RE.fullmatch(user):
                self.send_error(400, "missing or invalid user")
                return
            with open(USER_OUT_FILE, "w") as f:
                f.write(user + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK\n")
            return

        return super().do_GET()

    def log_message(self, format, *args):
        pass  # Silent logging to keep terminal output clean

class ReusableServer(socketserver.TCPServer):
    allow_reuse_address = True

if __name__ == "__main__":
    with ReusableServer(("127.0.0.1", PORT), ProvisionHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
