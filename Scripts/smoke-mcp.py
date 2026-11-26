#!/usr/bin/env python3
"""End-to-end check of `troy mcp` over real pipes, in both protocol generations.

usage: python3 Scripts/smoke-mcp.py [path/to/troy]   (default: .build/debug/troy)

Starts the binary with a temporary database, speaks newline-delimited JSON-RPC to it,
calls every tool at least once and exits non-zero with a clear message on the first failure.
Never touches the real database or any client settings.
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile

TIMEOUT = 20
MODERN = "2026-07-28"
META = {
    "io.modelcontextprotocol/protocolVersion": MODERN,
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": {"name": "smoke-client", "version": "1"},
}


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def check(condition, message):
    if not condition:
        fail(message)


class Server:
    def __init__(self, binary, db, cwd, label):
        env = {k: v for k, v in os.environ.items() if not k.startswith("TROY_")}
        env["TROY_AGENT"] = label
        self.proc = subprocess.Popen(
            [binary, "--db", db, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=cwd, env=env)
        self.next_id = 1
        self.buffer = b""

    def send_line(self, text):
        self.proc.stdin.write(text.encode() + b"\n")
        self.proc.stdin.flush()

    def read_line(self):
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.buffer:
            ready, _, _ = select.select([fd], [], [], TIMEOUT)
            check(ready, "timed out waiting for a reply")
            chunk = os.read(fd, 65536)
            if not chunk:
                fail("the server closed stdout; stderr: " + self.proc.stderr.read().decode(errors="replace"))
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        text = line.decode()
        try:
            return json.loads(text)
        except ValueError:
            fail(f"stdout carried a line that is not JSON: {text!r}")

    def request(self, method, params=None):
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.next_id += 1
        self.send_line(json.dumps(message))
        reply = self.read_line()
        check(reply.get("id") == message["id"], f"{method}: reply id {reply.get('id')!r} != {message['id']!r}")
        return reply

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send_line(json.dumps(message))

    def close(self):
        self.proc.stdin.close()
        try:
            code = self.proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            fail("the server did not exit after stdin closed")
        check(code == 0, f"the server exited with status {code}")


def run_generation(binary, workdir, modern):
    name = "modern" if modern else "handshake"
    db = os.path.join(workdir, f"{name}.db")
    folder = os.path.join(workdir, f"repo-{name}")
    os.makedirs(os.path.join(folder, ".git"))
    with open(os.path.join(folder, ".git", "HEAD"), "w") as head:  # every git dir has one
        head.write("ref: refs/heads/main\n")
    server = Server(binary, db, folder, f"smoke/{name[:3]}")
    meta = {"_meta": META} if modern else {}

    # Handshake or discovery.
    if modern:
        reply = server.request("server/discover", {"_meta": META})
        result = reply["result"]
        check(result.get("resultType") == "complete", "discover: resultType is not complete")
        check(MODERN in result["supportedVersions"], "discover: supportedVersions lacks " + MODERN)
        check(list(result["capabilities"]) == ["tools"], f"discover: capabilities {result['capabilities']}")
        check(result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "troy", "discover: serverInfo")
        check("troy_context" in result["instructions"], "discover: instructions")
        bad = server.request("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "1900-01-01"}})
        check(bad["error"]["code"] == -32022, "unsupported version did not return -32022")
        check(MODERN in bad["error"]["data"]["supported"], "-32022 data lacks the supported list")
    else:
        reply = server.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke-client", "version": "1"}})
        result = reply["result"]
        check(result["protocolVersion"] == "2025-06-18", "initialize: version not echoed")
        check(result["serverInfo"]["name"] == "troy", "initialize: serverInfo")
        check(list(result["capabilities"]) == ["tools"], "initialize: capabilities")
        check("troy_context" in result["instructions"], "initialize: instructions")
        server.notify("notifications/initialized")
        server.notify("notifications/cancelled", {"requestId": 99})
        check(server.request("ping")["result"] == {}, "ping after notifications")

    # Tools.
    listing = server.request("tools/list", meta)["result"]
    names = [tool["name"] for tool in listing["tools"]]
    expected = ["troy_context", "troy_save", "troy_update", "troy_link", "troy_search", "troy_read", "troy_projects", "troy_new_project"]
    check(names == expected, f"tools/list names {names}")
    check(("resultType" in listing) == modern, "resultType presence does not match the generation")
    check(("ttlMs" in listing) == modern, "ttlMs presence does not match the generation")
    print(f"  {name}: tools/list is {len(json.dumps(listing, separators=(',', ':'), ensure_ascii=False))} characters")

    def call(tool, arguments, error=False):
        reply = server.request("tools/call", dict({"name": tool, "arguments": arguments}, **meta))
        check("error" not in reply, f"{tool}: protocol error {reply.get('error')}")
        result = reply["result"]
        check("structuredContent" not in result, f"{tool}: structuredContent present")
        check(result.get("isError", False) == error, f"{tool}: isError={result.get('isError')} text={result['content'][0]['text']!r}")
        if modern:
            check(result.get("resultType") == "complete", f"{tool}: resultType")
        return result["content"][0]["text"]

    text = call("troy_projects", {})
    check("No projects yet" in text, f"projects (empty): {text!r}")
    text = call("troy_save", {"kind": "note", "title": "No project"}, error=True)
    check("troy_context" in text, f"save without project: {text!r}")

    # The working folder is a repository without a project: context says how to start, creates nothing.
    repo = os.path.basename(folder)
    text = call("troy_context", {})
    first = text.split("\n")[0]
    check(first.startswith("No project yet for this repository: ") and first.endswith("/" + repo), f"pending context: {text!r}")
    check("There are no projects yet." in text, f"pending context lists projects: {text!r}")
    root = first[len("No project yet for this repository: "):]
    text = call("troy_projects", {})
    check("No projects yet" in text, f"reading created a project: {text!r}")

    # The first save with the repository folder creates the project, named after the folder.
    text = call("troy_save", {"project": root, "kind": "task", "title": "Write the exporter", "tags": ["cli"], "paths": ["Sources/Export"]})
    check(text.startswith(f'Created project #1 "{repo}", linked to {root}.\n'), f"creating save: {text!r}")
    check(f'Saved #1 [task/open] "Write the exporter" in project #1 {repo}.' in text, f"creating save: {text!r}")
    text = call("troy_context", {})  # resolves from the working folder
    check(text.startswith(f'Project #1 "{repo}"'), f"context from the working folder: {text!r}")

    # troy_new_project still links any folder, under a name of its own.
    other = os.path.join(workdir, f"plain-{name}")
    os.makedirs(other)
    text = call("troy_new_project", {"name": "Smoke", "summary": "Smoke test project", "path": other})
    check(text.startswith('Created project #2 "Smoke", linked to '), f"new_project: {text!r}")
    check(os.path.basename(other) in text, f"new_project did not link the path: {text!r}")
    text = call("troy_save", {"project": other, "kind": "note", "title": "In the plain folder"})
    check(text.startswith('Saved #2 [note/open] "In the plain folder" in project #2 Smoke.'), f"save by folder: {text!r}")

    text = call("troy_save", {
        "project": repo, "kind": "decision", "title": "Export format is Markdown", "body": "Because it diffs well.",
        "links": [{"to": 1, "relation": "relates_to", "note": "format"}]})
    check("Linked: relates to #1." in text, f"save with links: {text!r}")
    text = call("troy_save", {"project": 1, "kind": "task", "title": "Write the exporter docs", "parent": "#1", "tags": "docs, cli"})
    check(text.startswith("Saved #4 ") and "Linked: part of #1." in text and "Similar records" in text, f"save with parent: {text!r}")

    text = call("troy_update", {"id": 1, "status": "doing"})
    check("status open → doing" in text and "by smoke/" in text, f"claim: {text!r}")
    text = call("troy_link", {"from": 4, "to": [1, 3], "relation": "depends_on"})
    check("Linked #4 depends on #1" in text and "Linked #4 depends on #3" in text, f"link: {text!r}")
    text = call("troy_context", {"project": 1})
    for needle in ("IN PROGRESS", "#1 Write the exporter — smoke/", "BLOCKED", "waits on #1", "DECISIONS IN EFFECT", "#3 Export format is Markdown"):
        check(needle in text, f"context lacks {needle!r}: {text!r}")
    text = call("troy_search", {"query": "exporter"})
    check(text.startswith(f'2 results for "exporter" in project #1 {repo}:'), f"search: {text!r}")
    text = call("troy_search", {"query": "zzzz-nothing"})
    check(text.startswith("No results"), f"search with no results: {text!r}")
    text = call("troy_read", {"ids": [3, 4]})
    check("Because it diffs well." in text and "\n---\n" in text and "- depends on #1" in text, f"read: {text!r}")
    text = call("troy_update", {"id": 1, "status": "done"})
    check("Add a one-line outcome" in text, f"done reminder: {text!r}")
    text = call("troy_update", {"id": 4, "status": "done", "append": "Outcome: written."})
    check("outcome" not in text, f"done with append: {text!r}")
    text = call("troy_link", {"from": 4, "to": 1, "relation": "depends_on", "remove": True})
    check(text.startswith("Removed:"), f"unlink: {text!r}")
    text = call("troy_projects", {})
    check(f"#1 {repo}" in text and "#2 Smoke" in text and "← this folder" in text, f"projects: {text!r}")

    # Protocol errors leave the server running.
    server.send_line("{this is not json")
    reply = server.read_line()
    check(reply["error"]["code"] == -32700 and reply["id"] is None, f"parse error: {reply}")
    reply = server.request("no/such/method")
    check(reply["error"]["code"] == -32601, f"unknown method: {reply}")
    reply = server.request("tools/call", dict({"name": "troy_nothing", "arguments": {}}, **meta))
    check(reply["error"]["code"] == -32602, f"unknown tool: {reply}")
    server.send_line(json.dumps([{"jsonrpc": "2.0", "id": 501, "method": "ping"}, {"jsonrpc": "2.0", "method": "notifications/initialized"}]))
    batch = server.read_line()
    check(isinstance(batch, list) and len(batch) == 1 and batch[0]["id"] == 501, f"batch: {batch}")

    server.close()
    print(f"  {name}: ok")


def run_hook(binary, workdir):
    """`troy context --quiet` as a session-start hook: never fails, never creates the database."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("TROY_")}

    def hook(db, cwd, quiet=True):
        args = [binary, "--db", db, "context"] + (["--quiet"] if quiet else [])
        done = subprocess.run(args, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=TIMEOUT)
        check(done.returncode == 0, f"hook in {cwd} exited {done.returncode}: {done.stderr.decode(errors='replace')!r}")
        return done.stdout.decode()

    repo = os.path.join(workdir, "hook-repo")
    os.makedirs(os.path.join(repo, ".git", "objects"))
    with open(os.path.join(repo, ".git", "HEAD"), "w") as head:
        head.write("ref: refs/heads/main\n")
    plain = os.path.join(workdir, "hook-plain")
    os.makedirs(plain)
    missing = os.path.join(workdir, "hook-none.db")
    text = hook(missing, repo)
    check(text.startswith("No project yet for this repository: ") and "There are no projects yet." in text, f"hook without a database: {text!r}")
    check(not os.path.exists(missing), "the hook created the database")
    check(hook(missing, plain) == "", "the hook printed something outside a repository")
    db = os.path.join(workdir, "hook.db")
    text = hook(db, repo, quiet=False)
    check(text.startswith("No project yet for this repository: "), f"context in a repository without a project: {text!r}")
    check("Other projects" not in text, f"context: {text!r}")
    print("  hook: ok")


def main():
    binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/troy")
    check(os.access(binary, os.X_OK), f"{binary} is not an executable; build it first")
    workdir = tempfile.mkdtemp(prefix="troy-smoke-")
    try:
        print(f"smoke test against {binary}")
        run_generation(binary, workdir, modern=False)
        run_generation(binary, workdir, modern=True)
        run_hook(binary, workdir)
        print("PASS")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
