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

MAX_BODY_BYTES = 1_048_576
MAX_CACHE_ENTRIES = 256
CACHE_TTL = 60

RE_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_+.-]*$")
RE_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
RE_CHANNEL = re.compile(r"^[A-Za-z0-9_./-]+$")

parser = argparse.ArgumentParser(description="nix-detour web dashboard server")
parser.add_argument("port_pos", nargs="?", type=str, help="Optional port (positional)")
parser.add_argument("static_dir_pos", nargs="?", type=str, help="Optional static dir (positional)")
parser.add_argument("--port", "-p", type=int, default=8080, help="Port to listen on (default: 8080)")
parser.add_argument("--static-dir", type=str, default="", help="Directory with built web static assets")
parser.add_argument("--data-dir", type=str, default="", help="Directory containing held-packages.json and nixpkgs-prs.json")
parser.add_argument("--holds", type=str, default="", help="Path to held-packages.json")
parser.add_argument("--prs", type=str, default="", help="Path to nixpkgs-prs.json")
parser.add_argument("--cli", type=str, default="", help="Path to nix-detour CLI (default: from PATH)")

args, _ = parser.parse_known_args()

PORT = int(args.port_pos) if args.port_pos and args.port_pos.isdigit() else args.port
STATIC_DIR = args.static_dir_pos or args.static_dir or os.path.join(os.path.dirname(__file__), "dist")
CLI = args.cli or shutil.which("nix-detour")
GH_BIN = shutil.which("gh")
GIT_BIN = shutil.which("git")

log = logging.getLogger("nix-detour")
PR_CACHE: dict[str, tuple[float, dict]] = {}
CACHE_LOCK = threading.Lock()
FILE_LOCK = threading.Lock()


def _detect_git_root() -> str | None:
    if not GIT_BIN:
        return None
    try:
        res = subprocess.run([GIT_BIN, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=2, check=False)
        if res.returncode == 0 and res.stdout.strip():
            return os.path.abspath(res.stdout.strip())
    except OSError:
        pass
    return None


GIT_ROOT = _detect_git_root()


def valid_name(val: object) -> bool:
    return isinstance(val, str) and bool(RE_NAME.fullmatch(val))


def valid_repo(val: object) -> bool:
    return isinstance(val, str) and bool(RE_REPO.fullmatch(val)) and ".." not in val.split("/")


def valid_channel(val: object) -> bool:
    return isinstance(val, str) and bool(RE_CHANNEL.fullmatch(val)) and ".." not in val


def resolve_file(explicit_path: str, filename: str) -> tuple[str, bool]:
    if explicit_path:
        return os.path.abspath(explicit_path), False
    if args.data_dir:
        return os.path.abspath(os.path.join(args.data_dir, filename)), False
    cwd = os.path.abspath(os.getcwd())
    cwd_candidate = os.path.join(cwd, filename)
    if os.path.exists(cwd_candidate):
        return cwd_candidate, False
    if GIT_ROOT and GIT_ROOT != cwd:
        root_candidate = os.path.join(GIT_ROOT, filename)
        if os.path.exists(root_candidate):
            return root_candidate, True
    return cwd_candidate, False


def github_api_get(endpoint: str) -> dict | None:
    if GH_BIN:
        try:
            res = subprocess.run([GH_BIN, "api", endpoint], capture_output=True, text=True, timeout=5, check=False)
            if res.returncode == 0 and res.stdout.strip():
                parsed = json.loads(res.stdout)
                if isinstance(parsed, dict):
                    return parsed
        except Exception as e:
            log.debug("gh api failed for %s: %s", endpoint, e)

    try:
        req = urllib.request.Request(
            f"https://api.github.com/{endpoint}",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "nix-detour"},
        )
        token = os.environ.get("GITHUB_TOKEN")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        # Fixed https://api.github.com origin; endpoint components are validated by callers.
        with urllib.request.urlopen(req, timeout=5) as response:  # noqa: S310
            parsed = json.loads(response.read().decode("utf-8"))
            if isinstance(parsed, dict):
                return parsed
    except Exception as e:
        log.debug("GitHub API request failed for %s: %s", endpoint, e)
    return None


def _cache_put(key: str, ts: float, value: dict) -> None:
    with CACHE_LOCK:
        if len(PR_CACHE) >= MAX_CACHE_ENTRIES and key not in PR_CACHE:
            for k in [k for k, (t, _) in PR_CACHE.items() if ts - t >= CACHE_TTL]:
                del PR_CACHE[k]
            if len(PR_CACHE) >= MAX_CACHE_ENTRIES:
                del PR_CACHE[min(PR_CACHE, key=lambda k: PR_CACHE[k][0])]
        PR_CACHE[key] = (ts, value)


def fetch_pr_status(pr_number: int, upstream: str = "NixOS/nixpkgs", channel: str = "nixos-unstable") -> dict:
    if channel.startswith("github:"):
        parts = channel.split("/", 2)
        if len(parts) == 3:
            channel = parts[2]
    cache_key = f"{upstream}:{pr_number}:{channel}"
    now = time.time()
    with CACHE_LOCK:
        cached = PR_CACHE.get(cache_key)
        if cached and now - cached[0] < CACHE_TTL:
            return cached[1]

    default_url = f"https://github.com/{upstream}/pull/{pr_number}"
    pr_data = github_api_get(f"repos/{upstream}/pulls/{pr_number}")
    if not pr_data:
        result = {
            "pr": pr_number, "status": "unknown", "state": "unknown",
            "draft": False, "merged": False, "inChannel": False,
            "details": "GitHub API unavailable", "title": "", "url": default_url, "channel": channel,
        }
        _cache_put(cache_key, now, result)
        return result

    state = str(pr_data.get("state") or "unknown")
    draft = bool(pr_data.get("draft", False))
    merged = bool(pr_data.get("merged", False))
    merge_commit = pr_data.get("merge_commit_sha")
    title = str(pr_data.get("title") or "")
    html_url = str(pr_data.get("html_url") or default_url)

    in_channel = False
    if merged:
        comp_status = None
        if isinstance(merge_commit, str) and re.fullmatch(r"[0-9a-f]{7,40}", merge_commit):
            comp = github_api_get(f"repos/{upstream}/compare/{channel}...{merge_commit}")
            comp_status = comp.get("status") if comp else None
        if comp_status in ("behind", "identical"):
            status, in_channel, details = "in-channel", True, f"landed in {channel} (ready to release)"
        else:
            status, details = "merged", f"merged upstream (waiting for {channel})"
    elif draft:
        status, details = "draft", "draft PR"
    elif state == "closed":
        status, details = "closed", "closed without merge"
    else:
        status, details = "open", "open upstream"

    result = {
        "pr": pr_number, "status": status, "state": state, "draft": draft,
        "merged": merged, "inChannel": in_channel, "details": details,
        "title": title, "url": html_url, "channel": channel,
    }
    _cache_put(cache_key, now, result)
    return result


def hold_add_argv(name: str, kind: str, entry: dict, target: str) -> list[str]:
    if not valid_name(name):
        raise ValueError(f"invalid package name {name!r}")
    src = entry.get("from", "current")
    if isinstance(src, dict):
        src = src.get("rev", "")
    if not isinstance(src, str) or not src or src.startswith("-"):
        raise ValueError("from must be stable, current, previous, or a nixpkgs revision")

    until_ver = entry.get("untilVersion")
    if until_ver is not None and (not isinstance(until_ver, str) or until_ver.lstrip().startswith(("<", ">", "="))):
        raise ValueError("untilVersion must be a bare version string (e.g. 2.31.0)")

    argv = [CLI, "fix" if kind == "fix" else "hold", "add", "--file", target, "--from", src]
    for key, flag in (
        ("reason", "--reason"), ("link", "--link"), ("releaseWhen", "--release-when"),
        ("untilVersion", "--until-version"), ("override", "--override"),
    ):
        value = entry.get(key)
        if value:
            if not isinstance(value, str):
                raise ValueError(f"{key} must be a string")
            argv += [flag, value]

    tests = entry.get("tests") or []
    if tests:
        if not isinstance(tests, list) or not all(isinstance(t, str) and t for t in tests):
            raise ValueError("tests must be a list of test names")
        argv += ["--tests", ",".join(tests)]

    for patch in entry.get("patches") or []:
        if isinstance(patch, dict):
            patch = patch.get("url", "")
        if not isinstance(patch, str) or not patch:
            raise ValueError("a patch must be a URL or a file next to the holds file")
        argv += ["--patch", patch]

    return [*argv, "--", name]


def pr_add_argv(name: str, entry: dict, target: str) -> list[str]:
    pr = entry.get("pr")
    if isinstance(pr, bool) or not isinstance(pr, int) or pr <= 0:
        raise ValueError("pr must be a PR number")
    upstream = entry.get("upstream") or "NixOS/nixpkgs"
    if not valid_repo(upstream):
        raise ValueError("upstream must be OWNER/REPO")
    until_channel = entry.get("untilChannel")
    if until_channel and not valid_channel(until_channel):
        raise ValueError("untilChannel is invalid")

    auto = bool(entry.get("auto")) or (not entry.get("owner") and not entry.get("repo"))
    argv = [CLI, "pr", "add", "--file", target, "--pr", str(pr)]
    if upstream != "NixOS/nixpkgs":
        argv += ["--upstream", upstream]
    if until_channel:
        argv += ["--channel", until_channel]

    if auto:
        if name and not valid_name(name):
            raise ValueError(f"invalid entry name {name!r}")
        argv.append("--auto")
    else:
        if not valid_name(name):
            raise ValueError(f"invalid entry name {name!r}")
        owner, repo = entry.get("owner"), entry.get("repo")
        if not isinstance(owner, str) or not isinstance(repo, str) or not valid_repo(f"{owner}/{repo}"):
            raise ValueError("owner and repo name where the PR's branch is")
        argv += ["--repo", f"{owner}/{repo}"]

    attrs = entry.get("attrs") or []
    python_pkgs = entry.get("pythonPackages") or []
    if not auto:
        if (not isinstance(attrs, list) or not all(isinstance(a, str) and a for a in attrs)) or (
            not isinstance(python_pkgs, list) or not all(isinstance(p, str) and p for p in python_pkgs)
        ):
            raise ValueError("attrs and pythonPackages must be lists of package names")
        if not attrs and not python_pkgs:
            raise ValueError("attrs must list the packages to take from the PR")

    if isinstance(attrs, list) and attrs:
        argv += ["--attrs", ",".join(str(a) for a in attrs)]
    if isinstance(python_pkgs, list):
        for py in python_pkgs:
            if isinstance(py, str) and py:
                argv += ["--python", py]
    scope = entry.get("scope") or []
    if isinstance(scope, list) and scope:
        argv += ["--scope", ",".join(str(s) for s in scope)]
    if isinstance(entry.get("paths"), dict):
        for attr_name, rel_path in entry["paths"].items():
            argv += ["--path", f"{attr_name}={rel_path}"]
    if isinstance(entry.get("modules"), dict):
        for mod_name, rel_path in entry["modules"].items():
            argv += ["--module", f"{mod_name}={rel_path}"]

    rev = entry.get("rev") or ""
    if rev:
        if not isinstance(rev, str) or not re.fullmatch(r"[0-9a-f]{40}", rev):
            raise ValueError("rev must be a full 40-character commit SHA")
        argv += ["--rev", rev]
    elif not auto:
        data = github_api_get(f"repos/{upstream}/pulls/{pr}") or {}
        head_sha = (data.get("head") or {}).get("sha") or ""
        if not re.fullmatch(r"[0-9a-f]{40}", head_sha):
            raise ValueError(f"cannot find the head commit of {upstream}#{pr}")
        argv += ["--rev", head_sha]

    return [*argv, "--", name] if name else argv


def _read_json_dict(path: str) -> tuple[dict, str | None]:
    if not os.path.exists(path):
        return {}, None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return (data, None) if isinstance(data, dict) else ({}, f"{os.path.basename(path)} must contain a JSON object")
    except Exception as e:
        log.warning("could not read %s: %s", path, e)
        return {}, f"{os.path.basename(path)}: {e}"


class DetourHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def end_headers(self):
        if hasattr(self, "path"):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path in ("", "/", "/index.html") or parsed.path.startswith("/api/"):
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.send_header("Pragma", "no-cache")
                self.send_header("Expires", "0")
        super().end_headers()

    def _forbidden(self, post: bool) -> bool:
        hosts = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
        if self.headers.get("Host", "") not in hosts:
            return True
        if not post:
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in {f"http://{h}" for h in hosts}:
            return True
        return self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json"

    def _send_empty(self, status: int) -> None:
        self.send_response(status)
        self.end_headers()

    def _send_json(self, status: int, obj: object, send_body: bool = True) -> None:
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if send_body:
            self.wfile.write(data)

    def _run_cli(self, argv: list[str], target: str, timeout: int) -> None:
        try:
            with FILE_LOCK:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                res = subprocess.run(argv, cwd=os.path.dirname(target), capture_output=True, text=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            self._send_json(500, {"ok": False, "error": "nix-detour timed out"})
            return
        except OSError as e:
            self._send_json(500, {"ok": False, "error": f"could not update {target}: {e}"})
            return
        if res.returncode != 0:
            self._send_json(400, {"ok": False, "error": res.stderr.strip() or f"nix-detour exited with {res.returncode}"})
            return
        self._send_json(200, {"ok": True, "message": res.stdout.strip()})

    def _handle_api_get(self, send_body: bool = True) -> bool:
        parsed_url = urllib.parse.urlparse(self.path)
        if parsed_url.path == "/api/data":
            holds_file, holds_disc = resolve_file(args.holds, "held-packages.json")
            prs_file, prs_disc = resolve_file(args.prs, "nixpkgs-prs.json")
            with FILE_LOCK:
                holds, holds_err = _read_json_dict(holds_file)
                prs, prs_err = _read_json_dict(prs_file)
            errors = {k: v for k, v in (("holds", holds_err), ("prs", prs_err)) if v}
            source_info = {
                "holdsFile": holds_file if os.path.exists(holds_file) else None,
                "prsFile": prs_file if os.path.exists(prs_file) else None,
                "dataDir": os.path.dirname(holds_file),
                "holdsDiscovered": holds_disc,
                "prsDiscovered": prs_disc,
            }
            self._send_json(200, {"holds": holds, "prs": prs, "source": source_info, "errors": errors}, send_body=send_body)
            return True

        if parsed_url.path == "/api/pr-status":
            qs = urllib.parse.parse_qs(parsed_url.query)
            pr_val = qs.get("pr", [""])[0]
            upstream = qs.get("upstream", ["NixOS/nixpkgs"])[0]
            channel = qs.get("channel", ["nixos-unstable"])[0]
            if not pr_val.isdigit() or int(pr_val) <= 0 or not valid_repo(upstream) or not valid_channel(channel):
                self._send_json(400, {"error": "invalid pr, upstream, or channel parameter"}, send_body=send_body)
                return True
            self._send_json(200, fetch_pr_status(int(pr_val), upstream, channel), send_body=send_body)
            return True

        if parsed_url.path == "/api/pr-statuses":
            with CACHE_LOCK:
                cached = {k: v[1] for k, v in PR_CACHE.items()}
            self._send_json(200, cached, send_body=send_body)
            return True
        return False

    def do_GET(self):
        if self._forbidden(post=False):
            return self._send_empty(403)
        if not self._handle_api_get(send_body=True):
            super().do_GET()

    def do_HEAD(self):
        if self._forbidden(post=False):
            return self._send_empty(403)
        if not self._handle_api_get(send_body=False):
            super().do_HEAD()

    def do_POST(self):
        if self._forbidden(post=True):
            return self._send_empty(403)
        if self.path not in ("/api/detour", "/api/release"):
            return self._send_empty(404)

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0:
            self._send_json(400, {"ok": False, "error": "invalid Content-Length"})
            return
        if length > MAX_BODY_BYTES:
            self._send_json(413, {"ok": False, "error": "request body too large"})
            return

        body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"ok": False, "error": "invalid JSON body"})
            return
        if not isinstance(payload, dict):
            self._send_json(400, {"ok": False, "error": "JSON body must be an object"})
            return
        if not CLI:
            self._send_json(501, {"ok": False, "error": "nix-detour CLI unavailable; run `nix-detour web`"})
            return

        if self.path == "/api/detour":
            name = payload.get("name") or ""
            kind = payload.get("kind")
            entry = payload.get("entry")
            if kind not in ("hold", "fix", "pr") or not isinstance(name, str) or not isinstance(entry, dict):
                self._send_json(400, {"ok": False, "error": "invalid detour payload"})
                return
            if kind != "pr" and not name:
                self._send_json(400, {"ok": False, "error": "name is required"})
                return
            target, _ = resolve_file(args.prs if kind == "pr" else args.holds, "nixpkgs-prs.json" if kind == "pr" else "held-packages.json")
            try:
                argv = pr_add_argv(name, entry, target) if kind == "pr" else hold_add_argv(name, kind, entry, target)
            except ValueError as e:
                self._send_json(400, {"ok": False, "error": str(e)})
                return
            self._run_cli(argv, target, timeout=900)
            return

        name, kind = payload.get("name"), payload.get("kind")
        if not valid_name(name):
            self._send_json(400, {"ok": False, "error": "invalid package name"})
            return
        if kind == "pr":
            target, _ = resolve_file(args.prs, "nixpkgs-prs.json")
            argv = [CLI, "pr", "remove", "--file", target, "--", name]
        elif kind in ("hold", "fix"):
            target, _ = resolve_file(args.holds, "held-packages.json")
            argv = [CLI, "hold", "remove", "--file", target, "--", name]
        else:
            target, _ = resolve_file(args.holds, "held-packages.json")
            argv = [CLI, "release", "--", name, os.path.dirname(target)]
        self._run_cli(argv, target, timeout=30)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), DetourHandler)
    print(f"Serving nix-detour dashboard at http://127.0.0.1:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
