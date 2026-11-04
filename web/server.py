#!/usr/bin/env python3
import argparse
import http.server
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description="nix-detour web dashboard server")
parser.add_argument("port_pos", nargs="?", type=str, help="Optional port (positional)")
parser.add_argument("static_dir_pos", nargs="?", type=str, help="Optional static dir (positional)")
parser.add_argument("--port", "-p", type=int, default=8080, help="Port to listen on (default: 8080)")
parser.add_argument("--static-dir", type=str, default="", help="Directory with built web static assets")
parser.add_argument("--data-dir", type=str, default="", help="Directory containing held-packages.json and nixpkgs-prs.json")
parser.add_argument("--holds", type=str, default="", help="Path to held-packages.json")
parser.add_argument("--prs", type=str, default="", help="Path to nixpkgs-prs.json")

args, unknown = parser.parse_known_args()

# Handle positional arguments if passed
PORT = int(args.port_pos) if args.port_pos and args.port_pos.isdigit() else args.port
STATIC_DIR = args.static_dir_pos if args.static_dir_pos else (args.static_dir or os.path.join(os.path.dirname(__file__), "dist"))

PR_CACHE = {}
CACHE_TTL = 60


def resolve_file(explicit_path, filename):
    if explicit_path:
        return os.path.abspath(explicit_path), False

    if args.data_dir:
        cand = os.path.join(args.data_dir, filename)
        return os.path.abspath(cand), False

    cwd = os.getcwd()
    if os.path.exists(os.path.join(cwd, filename)):
        return os.path.abspath(os.path.join(cwd, filename)), False

    # Auto-discovery in sibling repos across the workspace
    fleet_candidates = [
        os.path.join(cwd, "..", filename),
        os.path.join(cwd, "..", "nix-packages", filename),
        os.path.join(cwd, "..", "nix-detour-fleet", filename),
        os.path.join(cwd, "..", "..", filename),
        os.path.join(cwd, "..", "..", "nix-packages", filename),
        os.path.join(cwd, "..", "..", "nix-detour-fleet", filename),
    ]
    for c in fleet_candidates:
        if os.path.exists(c):
            return os.path.abspath(c), True

    return os.path.abspath(os.path.join(cwd, filename)), False


def fetch_pr_status(pr_number, upstream="NixOS/nixpkgs", channel="nixos-unstable"):
    cache_key = f"{upstream}:{pr_number}:{channel}"
    now = time.time()
    if cache_key in PR_CACHE:
        ts, cached_data = PR_CACHE[cache_key]
        if now - ts < CACHE_TTL:
            return cached_data

    pr_data = None
    try:
        res = subprocess.run(
            ["gh", "api", f"repos/{upstream}/pulls/{pr_number}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if res.returncode == 0:
            pr_data = json.loads(res.stdout)
    except Exception:
        pass

    if not pr_data:
        try:
            req = urllib.request.Request(
                f"https://api.github.com/repos/{upstream}/pulls/{pr_number}",
                headers={"Accept": "application/vnd.github+json", "User-Agent": "nix-detour"},
            )
            token = os.environ.get("GITHUB_TOKEN")
            if token:
                req.add_header("Authorization", f"Bearer {token}")
            with urllib.request.urlopen(req, timeout=5) as response:
                pr_data = json.loads(response.read().decode("utf-8"))
        except Exception:
            pass

    if not pr_data:
        result = {
            "pr": pr_number,
            "status": "unknown",
            "state": "unknown",
            "draft": False,
            "merged": False,
            "inChannel": False,
            "details": "GitHub API unavailable",
            "title": "",
            "url": f"https://github.com/{upstream}/pull/{pr_number}",
            "channel": channel,
        }
        PR_CACHE[cache_key] = (now, result)
        return result

    state = pr_data.get("state", "unknown")
    draft = pr_data.get("draft", False)
    merged = pr_data.get("merged", False)
    merge_commit = pr_data.get("merge_commit_sha")
    title = pr_data.get("title", "")
    html_url = pr_data.get("html_url", f"https://github.com/{upstream}/pull/{pr_number}")

    status = "open"
    details = "open upstream"
    in_channel = False

    if merged:
        comp_status = None
        if merge_commit:
            try:
                res = subprocess.run(
                    ["gh", "api", f"repos/{upstream}/compare/{channel}...{merge_commit}"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if res.returncode == 0:
                    comp_status = json.loads(res.stdout).get("status")
            except Exception:
                pass

            if not comp_status:
                try:
                    req = urllib.request.Request(
                        f"https://api.github.com/repos/{upstream}/compare/{channel}...{merge_commit}",
                        headers={"Accept": "application/vnd.github+json", "User-Agent": "nix-detour"},
                    )
                    token = os.environ.get("GITHUB_TOKEN")
                    if token:
                        req.add_header("Authorization", f"Bearer {token}")
                    with urllib.request.urlopen(req, timeout=5) as response:
                        comp_status = json.loads(response.read().decode("utf-8")).get("status")
                except Exception:
                    pass

        if comp_status in ("behind", "identical"):
            status = "in-channel"
            in_channel = True
            details = f"landed in {channel} (ready to release)"
        else:
            status = "merged"
            details = f"merged upstream (waiting for {channel})"
    elif draft:
        status = "draft"
        details = "draft PR"
    elif state == "closed":
        status = "closed"
        details = "closed without merge"
    else:
        status = "open"
        details = "open upstream"

    result = {
        "pr": pr_number,
        "status": status,
        "state": state,
        "draft": draft,
        "merged": merged,
        "inChannel": in_channel,
        "details": details,
        "title": title,
        "url": html_url,
        "channel": channel,
    }
    PR_CACHE[cache_key] = (now, result)
    return result


class DetourHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def end_headers(self):
        if not hasattr(self, "path"):
            super().end_headers()
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path in ("", "/", "/index.html") or parsed.path.startswith("/api/"):
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        parsed_url = urllib.parse.urlparse(self.path)
        if parsed_url.path == "/api/data":
            holds_file, holds_disc = resolve_file(args.holds, "held-packages.json")
            prs_file, prs_disc = resolve_file(args.prs, "nixpkgs-prs.json")

            holds = {}
            prs = {}
            if os.path.exists(holds_file):
                try:
                    with open(holds_file, "r") as f:
                        holds = json.load(f)
                except Exception:
                    pass
            if os.path.exists(prs_file):
                try:
                    with open(prs_file, "r") as f:
                        prs = json.load(f)
                except Exception:
                    pass

            source_info = {
                "holdsFile": holds_file if os.path.exists(holds_file) else None,
                "prsFile": prs_file if os.path.exists(prs_file) else None,
                "holdsDiscovered": holds_disc,
                "prsDiscovered": prs_disc,
            }

            data = json.dumps({"holds": holds, "prs": prs, "source": source_info}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if parsed_url.path == "/api/pr-status":
            qs = urllib.parse.parse_qs(parsed_url.query)
            pr_val = qs.get("pr", [""])[0]
            if not pr_val.isdigit():
                self.send_response(400)
                self.end_headers()
                return
            pr_num = int(pr_val)
            upstream = qs.get("upstream", ["NixOS/nixpkgs"])[0]
            channel = qs.get("channel", ["nixos-unstable"])[0]
            res = fetch_pr_status(pr_num, upstream, channel)
            data = json.dumps(res).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if parsed_url.path == "/api/pr-statuses":
            cached = {k: v[1] for k, v in PR_CACHE.items()}
            data = json.dumps(cached).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

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

            target, _ = resolve_file(args.prs if kind == "pr" else args.holds, "nixpkgs-prs.json" if kind == "pr" else "held-packages.json")
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

            target, _ = resolve_file(args.prs if kind == "pr" else args.holds, "nixpkgs-prs.json" if kind == "pr" else "held-packages.json")
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
