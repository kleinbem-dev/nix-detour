#!/usr/bin/env python3
import argparse
import http.server
import json
import logging
import os
import re
import shutil
import subprocess
import threading
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
parser.add_argument("--cli", type=str, default="", help="The nix-detour CLI, which adds holds and fixes (default: from PATH)")

args, unknown = parser.parse_known_args()

# Handle positional arguments if passed
PORT = int(args.port_pos) if args.port_pos and args.port_pos.isdigit() else args.port
STATIC_DIR = args.static_dir_pos if args.static_dir_pos else (args.static_dir or os.path.join(os.path.dirname(__file__), "dist"))

CLI = args.cli or shutil.which("nix-detour")

log = logging.getLogger("nix-detour")

PR_CACHE = {}
# Request threads write the same holds and PR files: one at a time.
FILE_LOCK = threading.Lock()
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


def github_pr(upstream, pr_number):
    """The GitHub API's pull request object, or None."""
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
    except Exception as e:
        log.debug("gh api failed for %r#%s, falling back to urllib: %s", upstream, pr_number, e)

    if not pr_data:
        try:
            req = urllib.request.Request(
                f"https://api.github.com/repos/{upstream}/pulls/{pr_number}",
                headers={"Accept": "application/vnd.github+json", "User-Agent": "nix-detour"},
            )
            token = os.environ.get("GITHUB_TOKEN")
            if token:
                req.add_header("Authorization", f"Bearer {token}")
            # The scheme and host are fixed (https://api.github.com); only the path varies.
            with urllib.request.urlopen(req, timeout=5) as response:  # noqa: S310
                pr_data = json.loads(response.read().decode("utf-8"))
        except Exception as e:
            log.warning("GitHub API request failed for %r#%s: %s", upstream, pr_number, e)
    return pr_data


def fetch_pr_status(pr_number, upstream="NixOS/nixpkgs", channel="nixos-unstable"):
    cache_key = f"{upstream}:{pr_number}:{channel}"
    now = time.time()
    if cache_key in PR_CACHE:
        ts, cached_data = PR_CACHE[cache_key]
        if now - ts < CACHE_TTL:
            return cached_data

    pr_data = github_pr(upstream, pr_number)

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
            except Exception as e:
                log.debug("gh api compare failed for %s, falling back to urllib: %s", merge_commit, e)

            if not comp_status:
                try:
                    req = urllib.request.Request(
                        f"https://api.github.com/repos/{upstream}/compare/{channel}...{merge_commit}",
                        headers={"Accept": "application/vnd.github+json", "User-Agent": "nix-detour"},
                    )
                    token = os.environ.get("GITHUB_TOKEN")
                    if token:
                        req.add_header("Authorization", f"Bearer {token}")
                    # The scheme and host are fixed (https://api.github.com); only the path varies.
                    with urllib.request.urlopen(req, timeout=5) as response:  # noqa: S310
                        comp_status = json.loads(response.read().decode("utf-8")).get("status")
                except Exception as e:
                    log.warning("GitHub compare request failed for %s: %s", merge_commit, e)

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


def hold_add_argv(name, kind, entry, target):
    """The CLI call that adds a hold or fix, so it pins revisions and patch URLs by their hash."""
    src = entry.get("from", "current")
    if isinstance(src, dict):
        src = src.get("rev", "")
    if not isinstance(src, str) or not src:
        raise ValueError("from must be stable, current or a nixpkgs revision")
    argv = [CLI, "fix" if kind == "fix" else "hold", "add", name, "--file", target, "--from", src]
    options = {
        "reason": "--reason",
        "link": "--link",
        "releaseWhen": "--release-when",
        "untilVersion": "--until-version",
        "override": "--override",
    }
    for key, flag in options.items():
        value = entry.get(key)
        if value:
            if not isinstance(value, str):
                raise ValueError(f"{key} must be a string")
            argv += [flag, value]
    tests = entry.get("tests") or []
    if tests:
        argv += ["--tests", ",".join(str(t) for t in tests)]
    for patch in entry.get("patches") or []:
        if isinstance(patch, dict):
            patch = patch.get("url", "")
        if not isinstance(patch, str) or not patch:
            raise ValueError("a patch must be a URL or a file next to the holds file")
        argv += ["--patch", patch]
    return argv


def pr_add_argv(name, entry, target):
    """The CLI call that adds a PR entry pinned to the PR's head commit, so it evaluates."""
    pr = entry.get("pr")
    if isinstance(pr, bool) or not isinstance(pr, int) or pr <= 0:
        raise ValueError("pr must be a PR number")
    owner, repo = entry.get("owner"), entry.get("repo")
    if not isinstance(owner, str) or not owner or not isinstance(repo, str) or not repo:
        raise ValueError("owner and repo name where the PR's branch is")
    attrs = entry.get("attrs") or []
    if not isinstance(attrs, list) or not attrs or not all(isinstance(a, str) and a for a in attrs):
        raise ValueError("attrs must list the packages to take from the PR")
    rev = entry.get("rev") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", rev):
        # The head commit is in nixpkgs too (refs/pull/N/head), also for a fork's branch.
        data = github_pr("NixOS/nixpkgs", pr) or {}
        rev = (data.get("head") or {}).get("sha") or ""
        if not re.fullmatch(r"[0-9a-f]{40}", rev):
            raise ValueError(f"cannot find the head commit of NixOS/nixpkgs#{pr}")
    return [CLI, "pr", "add", name, "--file", target, "--pr", str(pr), "--repo", f"{owner}/{repo}", "--attrs", ",".join(attrs), "--rev", rev]


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

    def _allowed_hosts(self):
        port = self.server.server_port
        return {f"127.0.0.1:{port}", f"localhost:{port}"}

    def _forbidden(self, post):
        """Requests from other sites: a DNS-rebound Host, a foreign Origin, or a
        form-style POST that skips the CORS preflight."""
        hosts = self._allowed_hosts()
        if self.headers.get("Host", "") not in hosts:
            return True
        if not post:
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in {f"http://{h}" for h in hosts}:
            return True
        ctype = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
        return ctype != "application/json"

    def _send_json(self, status, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle_api_get(self, send_body=True):
        """Handle GET and HEAD requests for API endpoints."""
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
                except Exception as e:
                    log.warning("could not read %s: %s", holds_file, e)
            if os.path.exists(prs_file):
                try:
                    with open(prs_file, "r") as f:
                        prs = json.load(f)
                except Exception as e:
                    log.warning("could not read %s: %s", prs_file, e)

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
            if send_body:
                self.wfile.write(data)
            return True

        if parsed_url.path == "/api/pr-status":
            qs = urllib.parse.parse_qs(parsed_url.query)
            pr_val = qs.get("pr", [""])[0]
            if not pr_val.isdigit():
                self.send_response(400)
                self.end_headers()
                return True
            pr_num = int(pr_val)
            upstream = qs.get("upstream", ["NixOS/nixpkgs"])[0]
            channel = qs.get("channel", ["nixos-unstable"])[0]
            res = fetch_pr_status(pr_num, upstream, channel)
            data = json.dumps(res).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if send_body:
                self.wfile.write(data)
            return True

        if parsed_url.path == "/api/pr-statuses":
            cached = {k: v[1] for k, v in list(PR_CACHE.items())}
            data = json.dumps(cached).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if send_body:
                self.wfile.write(data)
            return True

        return False

    def do_GET(self):
        """Handle HTTP GET requests for API routes and static assets."""
        if self._forbidden(post=False):
            self.send_response(403)
            self.end_headers()
            return
        if self._handle_api_get(send_body=True):
            return
        super().do_GET()

    def do_HEAD(self):
        """Handle HTTP HEAD requests for API routes and static assets."""
        if self._forbidden(post=False):
            self.send_response(403)
            self.end_headers()
            return
        if self._handle_api_get(send_body=False):
            return
        super().do_HEAD()

    def do_POST(self):
        if self._forbidden(post=True):
            self.send_response(403)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except Exception:
            payload = {}
        if not isinstance(payload, dict):
            payload = {}

        if self.path == "/api/detour":
            name = payload.get("name")
            kind = payload.get("kind")
            entry = payload.get("entry")
            if not isinstance(name, str) or not name or not isinstance(entry, dict):
                self.send_response(400)
                self.end_headers()
                return

            target, _ = resolve_file(args.prs if kind == "pr" else args.holds, "nixpkgs-prs.json" if kind == "pr" else "held-packages.json")
            if not CLI:
                self._send_json(501, {"ok": False, "error": "adding detours needs the nix-detour CLI: run `nix-detour web`"})
                return
            try:
                argv = pr_add_argv(name, entry, target) if kind == "pr" else hold_add_argv(name, kind, entry, target)
            except ValueError as e:
                self._send_json(400, {"ok": False, "error": str(e)})
                return
            # Prefetching a nixpkgs revision takes a while.
            try:
                with FILE_LOCK:
                    res = subprocess.run(argv, cwd=os.path.dirname(target), capture_output=True, text=True, timeout=900, check=False)
                    channel = entry.get("untilChannel")
                    if res.returncode == 0 and kind == "pr" and isinstance(channel, str) and channel:
                        # Only the dashboard reads it, so the CLI doesn't take it.
                        with open(target, "r") as f:
                            cur = json.load(f)
                        cur[name]["untilChannel"] = channel
                        with open(target, "w") as f:
                            json.dump(cur, f, indent=2)
                            f.write("\n")
            except subprocess.TimeoutExpired:
                self._send_json(500, {"ok": False, "error": "nix-detour timed out"})
                return
            if res.returncode != 0:
                self._send_json(400, {"ok": False, "error": res.stderr.strip() or f"nix-detour exited with {res.returncode}"})
                return
            self._send_json(200, {"ok": True})
            return

        if self.path == "/api/release":
            name = payload.get("name")
            kind = payload.get("kind")
            if not isinstance(name, str) or not name:
                self.send_response(400)
                self.end_headers()
                return

            target, _ = resolve_file(args.prs if kind == "pr" else args.holds, "nixpkgs-prs.json" if kind == "pr" else "held-packages.json")
            with FILE_LOCK:
                if os.path.exists(target):
                    try:
                        with open(target, "r") as f:
                            cur = json.load(f)
                        if name in cur:
                            del cur[name]
                            with open(target, "w") as f:
                                json.dump(cur, f, indent=2)
                                f.write("\n")
                    except Exception as e:
                        log.warning("could not release %r from %s: %s", name, target, e)
                        self._send_json(500, {"ok": False, "error": f"could not update {target}: {e}"})
                        return

            self._send_json(200, {"ok": True})
            return

        self.send_response(404)
        self.end_headers()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    # Threads: adding a hold can prefetch nixpkgs for minutes.
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), DetourHandler)
    print(f"Serving nix-detour dashboard at http://127.0.0.1:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
