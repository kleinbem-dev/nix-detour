#!/usr/bin/env python3
import http.server
import json
import os
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 8080
STATIC_DIR = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "dist")


class DetourHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def do_GET(self):
        if self.path == "/api/data":
            holds = {}
            prs = {}
            if os.path.exists("held-packages.json"):
                try:
                    with open("held-packages.json", "r") as f:
                        holds = json.load(f)
                except Exception:
                    pass
            if os.path.exists("nixpkgs-prs.json"):
                try:
                    with open("nixpkgs-prs.json", "r") as f:
                        prs = json.load(f)
                except Exception:
                    pass
            data = json.dumps({"holds": holds, "prs": prs}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            super().do_GET()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except Exception:
            payload = {}

        if self.path == "/api/detour":
            name = payload.get("name")
            kind = payload.get("kind")
            entry = payload.get("entry")
            if not name or not entry:
                self.send_response(400)
                self.end_headers()
                return

            target = "nixpkgs-prs.json" if kind == "pr" else "held-packages.json"
            cur = {}
            if os.path.exists(target):
                try:
                    with open(target, "r") as f:
                        cur = json.load(f)
                except Exception:
                    cur = {}
            cur[name] = entry
            with open(target, "w") as f:
                json.dump(cur, f, indent=2)
                f.write("\n")

            resp = json.dumps({"ok": True}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return

        if self.path == "/api/release":
            name = payload.get("name")
            kind = payload.get("kind")
            if not name:
                self.send_response(400)
                self.end_headers()
                return

            target = "nixpkgs-prs.json" if kind == "pr" else "held-packages.json"
            if os.path.exists(target):
                try:
                    with open(target, "r") as f:
                        cur = json.load(f)
                    if name in cur:
                        del cur[name]
                        with open(target, "w") as f:
                            json.dump(cur, f, indent=2)
                            f.write("\n")
                except Exception:
                    pass

            resp = json.dumps({"ok": True}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return

        self.send_response(404)
        self.end_headers()


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), DetourHandler)
    print(f"Serving nix-detour dashboard at http://127.0.0.1:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
