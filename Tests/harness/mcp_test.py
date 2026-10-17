"""Offline integration tests for BridgeKitCore's MCP server over real loopback sockets.

Generalized from EK Bridge's Tests/mcp_test.py (9c726f2): the protocol, HTTP
and security checks, run against the reference server (Tests/harness/
ReferenceServer: status, echo and write_note tools, a fake approval panel).
App-specific checks (tool outputs, grants, journals, Remote Access) stay in
each app's own harness. Standard library only.

Usage: mcp_test.py SERVER_BINARY TOOLS_JSON
"""

import base64
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

LEGACY = "2025-11-25"
MODERN = "2026-07-28"
META_VERSION = "io.modelcontextprotocol/protocolVersion"
META_CAPS = "io.modelcontextprotocol/clientCapabilities"
META_INFO = "io.modelcontextprotocol/clientInfo"
PREFIX = "ref_mcp_v1_"
APP = "Reference Bridge"
HARNESS = None

failures = []
checks = 0


def check(name, condition, detail=""):
    global checks
    checks += 1
    if not condition:
        failures.append(f"{name}: {detail}")


class Harness:
    def __init__(self, binary, **env_extra):
        self.dir = tempfile.mkdtemp(prefix="bridgekit-mcp-test-")
        os.chmod(self.dir, 0o700)
        env = dict(os.environ, BRIDGEKIT_TEST_DIR=self.dir, **{k: str(v) for k, v in env_extra.items()})
        self.proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env, text=True)
        first = json.loads(self.proc.stdout.readline())
        self.port = first["port"]
        self.agents = first["agents"]
        self.lock = threading.Lock()

    def control(self, **command):
        with self.lock:
            self.proc.stdin.write(json.dumps(command) + "\n")
            self.proc.stdin.flush()
            return json.loads(self.proc.stdout.readline())

    def key(self, name):
        return self.agents[name]["key"]

    def activity(self):
        return self.control(cmd="activity")["activity"]

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


class Client:
    """One keep-alive HTTP connection."""

    def __init__(self, harness, key=None, host=None):
        self.h = harness
        self.key = key
        self.host = host or f"127.0.0.1:{harness.port}"
        self.conn = http.client.HTTPConnection("127.0.0.1", harness.port, timeout=70)
        self.next_id = 1

    def raw(self, method="POST", path="/mcp", body=b"", headers=None, auth=True,
            content_type="application/json"):
        all_headers = {"Host": self.host}
        if content_type:
            all_headers["Content-Type"] = content_type
        all_headers["Accept"] = "application/json, text/event-stream"
        if auth and self.key:
            all_headers["Authorization"] = "Bearer " + self.key
        all_headers.update(headers or {})
        if isinstance(body, (dict, list, str)):
            body = json.dumps(body).encode()
        if method in ("POST", "PUT") or body:
            all_headers.setdefault("Content-Length", str(len(body)))
        self.conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for key, value in all_headers.items():
            if value is not None:
                self.conn.putheader(key, value)
        self.conn.endheaders(body if body else None)
        response = self.conn.getresponse()
        data = response.read()
        parsed = None
        if data and response.getheader("Content-Type", "").startswith("application/json"):
            parsed = json.loads(data)
        return response.status, dict(response.getheaders()), parsed, data

    def legacy(self, method, params=None, version=LEGACY, notify=False, rid=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            message["id"] = rid if rid is not None else self._id()
        headers = {"MCP-Protocol-Version": version} if version else {}
        return self.raw(body=message, headers=headers)

    def modern(self, method, params=None, name=None, rid=None, info=None, extra=None):
        params = dict(params or {})
        meta = {META_VERSION: MODERN, META_CAPS: {}}
        if info:
            meta[META_INFO] = info
        params["_meta"] = meta
        message = {"jsonrpc": "2.0", "id": rid if rid is not None else self._id(),
                   "method": method, "params": params}
        headers = {"MCP-Protocol-Version": MODERN, "Mcp-Method": method}
        if name is not None:
            headers["Mcp-Name"] = name
        headers.update(extra or {})
        return self.raw(body=message, headers=headers)

    def call(self, tool, arguments, modern=False, info=None):
        params = {"name": tool, "arguments": arguments}
        if modern:
            status, _, body, _ = self.modern("tools/call", params, name=tool, info=info)
        else:
            status, _, body, _ = self.legacy("tools/call", params)
        return status, body

    def _id(self):
        self.next_id += 1
        return self.next_id

    def close(self):
        self.conn.close()


def inline(value, shared):
    if isinstance(value, dict):
        if len(value) == 1 and isinstance(value.get("$ref"), str) and value["$ref"].startswith("#/$defs/"):
            name = value["$ref"][len("#/$defs/"):]
            if name in shared:
                return inline(shared[name], shared)
        return {k: inline(v, shared) for k, v in value.items() if k != "$comment"}
    if isinstance(value, list):
        return [inline(v, shared) for v in value]
    return value


def text_of(result):
    return result["content"][0]["text"]


def wait_for(condition, seconds=10):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


def main():
    global HARNESS
    HARNESS, tools_path = sys.argv[1], sys.argv[2]
    with open(tools_path) as f:
        contract = json.load(f)
    shared = {k: v for k, v in contract["$defs"].items() if k != "$comment"}
    catalog = {t["name"]: inline(t, shared) for t in contract["tools"]}

    h = Harness(HARNESS)
    try:
        run_core(h, catalog, contract)
        run_agent_state(h)
        run_limits(h)
    finally:
        h.close()

    a = Harness(HARNESS)
    try:
        a.control(cmd="approval", mode="none")
        run_approvals(a)
    finally:
        a.close()

    t = Harness(HARNESS, BRIDGEKIT_TEST_CALL_TIMEOUT=2)
    try:
        run_timeout(t)
    finally:
        t.close()

    t = Harness(HARNESS)
    try:
        run_auth_lockout(t)
    finally:
        t.close()

    if failures:
        print("MCP integration tests failed:")
        for failure in failures:
            print("  " + failure)
        sys.exit(1)
    print(f"BridgeKitCore MCP server: {checks} checks over loopback (both eras, HTTP statuses, Host/Origin, "
          "concurrency, slow-loris, approvals, cancellation, timeouts, limits, lockout) passed")


def run_core(h, catalog, contract):
    c = Client(h, h.key("agent"))
    # Legacy handshake. No session header, the version echoed.
    status, headers, body, _ = c.legacy("initialize", {
        "protocolVersion": LEGACY, "capabilities": {},
        "clientInfo": {"name": "claude-code", "version": "2.4.1"}}, version=None, rid=0)
    result = body["result"]
    check("initialize status", status == 200, status)
    check("initialize version", result["protocolVersion"] == LEGACY, result)
    check("initialize no session", "Mcp-Session-Id" not in headers, headers)
    check("initialize tools capability", result["capabilities"] == {"tools": {"listChanged": False}})
    check("initialize serverInfo", result["serverInfo"] == {
        "name": "reference", "title": APP, "version": "0.1.0",
        "description": "BridgeKitCore's reference server."}, result)
    check("initialize instructions", result["instructions"] == contract["serverInstructions"])
    check("legacy has no resultType", "resultType" not in result)
    check("legacy no-store", headers.get("Cache-Control") == "no-store", headers)
    check("nosniff", headers.get("X-Content-Type-Options") == "nosniff", headers)
    check("no CORS", not any(k.lower().startswith("access-control") for k in headers), headers)
    for asked, answered in [("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"),
                            (MODERN, LEGACY), ("1999-01-01", LEGACY)]:
        _, _, body, _ = c.legacy("initialize", {"protocolVersion": asked, "capabilities": {}}, version=None)
        check(f"negotiate {asked}", body["result"]["protocolVersion"] == answered, body)
    status, _, body, data = c.legacy("notifications/initialized", notify=True)
    check("initialized notification 202", status == 202 and data == b"", (status, data))
    status, _, body, _ = c.legacy("ping")
    check("ping", status == 200 and body["result"] == {}, body)

    # tools/list follows the app's visibility, definitions exactly as the contract.
    _, _, body, _ = c.legacy("tools/list")
    names = [t["name"] for t in body["result"]["tools"]]
    check("visible tools", names == ["status", "echo", "write_note"], names)
    for tool in body["result"]["tools"]:
        check(f"definition {tool['name']}", tool == catalog[tool["name"]], tool["name"])
    check("legacy list has no ttl", "ttlMs" not in body["result"] and "nextCursor" not in body["result"])
    for name, expected in [("none", ["status"]), ("reader", ["status", "echo"])]:
        other = Client(h, h.key(name))
        _, _, body, _ = other.legacy("tools/list")
        got = [t["name"] for t in body["result"]["tools"]]
        check(f"visibility {name}", got == expected, got)
        other.close()

    status, body = c.call("echo", {"text": "héllo"})
    result = body["result"]
    check("echo", status == 200 and result["isError"] is False and result["structuredContent"] == {"text": "héllo"},
          body)
    check("text mirrors structured", json.loads(text_of(result)) == result["structuredContent"])

    # Argument problems are tool errors and never reach the app.
    before = len(h.activity())
    _, body = c.call("echo", {"text": ""})
    check("invalid arguments", text_of(body["result"]) ==
          "Invalid arguments: text: must not be empty. (code: invalid_arguments)", body)
    _, body = c.call("echo", {"text": "x" * 201})
    check("maxLength in UTF-8 bytes", "at most 200 bytes" in text_of(body["result"]), body)
    _, body = c.call("echo", {"text": "a", "colour": "red"})
    check("unknown argument", body["result"]["isError"] and "colour: isn't a known argument" in
          text_of(body["result"]), body)
    _, body = c.call("echo", {})
    check("required argument", "text: is required" in text_of(body["result"]), body)
    _, body = c.call("echo", {"text": "a", "delay_ms": 1.5})
    check("integer type", "delay_ms: expected a whole number" in text_of(body["result"]), body)
    _, body = c.call("echo", "nope")
    check("arguments not an object", body["result"]["isError"] and
          "arguments: expected an object" in text_of(body["result"]), body)
    _, body = c.call("echo", None)
    check("null arguments are {}", "text: is required" in text_of(body["result"]), body)
    check("validation not in activity", len(h.activity()) == before)

    # A known tool the agent can't see is the app's decision, recorded by it.
    reader = Client(h, h.key("reader"))
    _, body = reader.call("write_note", {"note": "hi"})
    check("hidden tool refused by the app", text_of(body["result"]).endswith("(code: forbidden)"), body)
    check("refusal recorded", h.activity()[0]["outcome"] == "error:forbidden", h.activity()[0])
    reader.close()
    # Unknown tool: a protocol error.
    status, body = c.call("make_coffee", {})
    check("unknown tool -32602", status == 200 and body["error"]["code"] == -32602 and
          body["error"]["message"] == "Unknown tool: make_coffee", body)

    # The agent's self-reported name reaches the app.
    row = next(r for r in h.activity() if r["command"] == "echo" and r["outcome"] == "success")
    check("activity agent name", row.get("agent") == "claude-code 2.4.1", row)
    check("connection status", h.control(cmd="connection", agent="agent")["connection"]["agent"] ==
          "claude-code 2.4.1")

    # Modern era: stateless, _meta on every request, headers must match.
    m = Client(h, h.key("agent"))
    status, _, body, _ = m.modern("server/discover", info={"name": "codex", "version": "0.98.0"})
    result = body["result"]
    check("discover", status == 200 and result["resultType"] == "complete" and
          result["supportedVersions"] == [MODERN, "2025-11-25", "2025-06-18", "2025-03-26"], body)
    check("discover names the agent", result["_meta"]["dev.bridgekit.reference/agent"]["name"] == "agent", result)
    check("modern serverInfo", result["_meta"]["io.modelcontextprotocol/serverInfo"] ==
          {"name": "reference", "version": "0.1.0"}, result)
    _, _, body, _ = m.modern("tools/list")
    check("modern list ttl", body["result"]["ttlMs"] == 30000 and body["result"]["cacheScope"] == "private", body)
    status, _, body, _ = m.modern("tools/call", {"name": "status", "arguments": {}}, name="status")
    check("modern call", status == 200 and body["result"]["resultType"] == "complete", body)
    status, _, body, _ = m.modern("tools/call", {"name": "status", "arguments": {}},
                                  name="=?base64?" + base64.b64encode(b"status").decode() + "?=")
    check("base64 Mcp-Name", status == 200 and "result" in body, body)
    status, _, body, _ = m.modern("tools/call", {"name": "status", "arguments": {}}, name="echo")
    check("Mcp-Name mismatch", status == 400 and body["error"]["code"] == -32020, body)
    status, _, body, _ = m.modern("tools/list", extra={"Mcp-Method": "tools/call"})
    check("Mcp-Method mismatch", status == 400 and body["error"]["code"] == -32020, body)
    status, _, body, _ = m.modern("tools/list", extra={"MCP-Protocol-Version": LEGACY})
    check("version header mismatch", status == 400 and body["error"]["code"] == -32020, body)
    message = {"jsonrpc": "2.0", "id": 9, "method": "tools/list",
               "params": {"_meta": {META_VERSION: "2099-01-01", META_CAPS: {}}}}
    status, _, body, _ = m.raw(body=message, headers={"MCP-Protocol-Version": "2099-01-01", "Mcp-Method": "tools/list"})
    check("unsupported modern", status == 400 and body["error"]["code"] == -32022 and
          "2025-11-25" in body["error"]["data"]["supported"], body)
    message = {"jsonrpc": "2.0", "id": 10, "method": "tools/list", "params": {"_meta": {META_VERSION: MODERN}}}
    status, _, body, _ = m.raw(body=message, headers={"MCP-Protocol-Version": MODERN, "Mcp-Method": "tools/list"})
    check("missing capabilities", status == 400 and body["error"]["code"] == -32602, body)
    status, _, body, _ = m.modern("resources/list")
    check("modern unknown method 404", status == 404 and body["error"]["code"] == -32601, body)
    status, _, body, _ = c.legacy("resources/list")
    check("legacy unknown method 200", status == 200 and body["error"]["code"] == -32601, body)
    status, _, body, _ = c.legacy("tools/list", version=MODERN)
    check("legacy with modern header", status == 400 and body["error"]["code"] == -32602, body)
    status, _, body, _ = c.legacy("tools/list", version="2024-11-05")
    check("legacy unsupported header", status == 400 and body["error"]["code"] == -32022, body)
    status, _, body, _ = c.legacy("tools/list", version=None)
    check("no header is 2025-03-26", status == 200 and "result" in body, body)
    # IDs echo with their type.
    _, _, body, _ = c.legacy("ping", rid="abc")
    check("string id echo", body["id"] == "abc")
    _, _, body, _ = c.legacy("ping", rid=7)
    check("int id echo", body["id"] == 7 and isinstance(body["id"], int))
    status, _, body, _ = c.raw(body=b'{"jsonrpc":"2.0","id":1.5,"method":"ping"}')
    check("fractional id invalid", status == 400 and body["error"]["code"] == -32600, body)
    status, _, body, _ = c.raw(body=b'{"jsonrpc":"2.0","id":null,"method":"ping"}')
    check("null id invalid", status == 400 and body["error"]["code"] == -32600, body)
    status, _, body, _ = c.raw(body=b"[{}]")
    check("batch rejected", status == 400 and body["error"]["code"] == -32600 and body["id"] is None, body)
    status, _, body, _ = c.raw(body=b"{nope")
    check("parse error", status == 400 and body["error"]["code"] == -32700, body)
    status, _, _, data = c.raw(body={"jsonrpc": "2.0", "id": 1, "result": {}})
    check("client response 202", status == 202 and data == b"", status)
    m.close()

    run_http_statuses(h)
    run_concurrency(h)
    c.close()


def run_http_statuses(h):
    c = Client(h, h.key("agent"))
    ping = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
    status, _, _, data = c.raw(path="/other", body=ping)
    check("404 path", status == 404 and b"/mcp" in data, status)
    status, _, _, _ = Client(h, h.key("agent"), host="evil.example").raw(body=ping)
    check("421 host", status == 421, status)
    status, _, _, _ = Client(h, h.key("agent"), host=f"127.0.0.1:{h.port + 1}").raw(body=ping)
    check("421 wrong port", status == 421, status)
    status, _, _, _ = Client(h, h.key("agent"), host=f"localhost:{h.port}").raw(body=ping)
    check("localhost host ok", status == 200, status)
    status, _, body, _ = c.raw(body=ping, headers={"Origin": "https://evil.example"})
    check("403 origin", status == 403 and "id" not in body, body)
    for header in ["Tailscale-Funnel-Request", "CF-Connecting-IP", "CF-Ray", "X-Forwarded-Host",
                   "X-Forwarded-For", "Forwarded", "Tailscale-User-Login"]:
        status, _, body, _ = c.raw(body=ping, headers={header: "?1"})
        check(f"403 forwarded {header}", status == 403 and "tunnels aren't accepted" in body["error"]["message"],
              body)
    for method in ["GET", "DELETE", "OPTIONS", "PUT"]:
        status, headers, _, _ = c.raw(method=method, body=b"")
        check(f"405 {method}", status == 405 and headers.get("Allow") == "POST", (method, status))
    status, _, _, _ = c.raw(body=ping, content_type="text/plain")
    check("415", status == 415, status)
    status, _, _, _ = c.raw(body=ping, content_type="application/json; charset=utf-8")
    check("charset ok", status == 200, status)
    status, _, _, _ = c.raw(body=ping, headers={"Accept": "text/html"})
    check("406", status == 406, status)
    status, _, _, _ = c.raw(body=ping, headers={"Accept": "*/*"})
    check("accept */*", status == 200, status)
    status, headers, body, _ = Client(h).raw(body=ping)
    check("401 missing", status == 401 and body["error"]["code"] == -32001 and body["id"] is None and
          headers.get("WWW-Authenticate") == f'Bearer realm="{APP}"' and "resource_metadata" not in
          headers.get("WWW-Authenticate", ""), (status, headers))
    status, _, body2, _ = Client(h, PREFIX + "0" * 64).raw(body=ping)
    check("401 same body", status == 401 and body2 == body, body2)
    status, _, _, _ = Client(h, "garbage").raw(body=ping)
    check("401 malformed", status == 401, status)
    status, _, _, _ = Client(h, PREFIX + h.key("agent")[len(PREFIX):].upper()).raw(body=ping)
    check("401 uppercase hex", status == 401, status)
    # Oversize body → 413 and close.
    raw = socket.create_connection(("127.0.0.1", h.port))
    raw.sendall(f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nContent-Type: application/json\r\n"
                f"Content-Length: 70000\r\n\r\n".encode())
    reply = raw.recv(1024)
    check("413", reply.startswith(b"HTTP/1.1 413"), reply[:40])
    raw.close()
    # Duplicate Host → 400.
    raw = socket.create_connection(("127.0.0.1", h.port))
    raw.sendall(f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nHost: evil\r\n"
                f"Content-Length: 0\r\n\r\n".encode())
    check("400 duplicate host", raw.recv(1024).startswith(b"HTTP/1.1 400"))
    raw.close()
    # Keep-alive: several requests on one connection, then Connection: close.
    k = Client(h, h.key("agent"))
    statuses = [k.legacy("ping")[0] for _ in range(5)]
    sock = k.conn.sock
    check("keep-alive reuse", statuses == [200] * 5 and sock is not None and k.conn.sock is sock, statuses)
    status, headers, _, _ = k.raw(body=ping, headers={"Connection": "close"})
    check("connection close honored", status == 200 and headers.get("Connection") == "close", headers)
    # Pipelining: two requests in one write, answered in order.
    raw = socket.create_connection(("127.0.0.1", h.port))
    body = json.dumps(ping).encode()
    one = (f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nContent-Type: application/json\r\n"
           f"Authorization: Bearer {h.key('agent')}\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body
    raw.sendall(one + one)
    time.sleep(0.5)
    data = raw.recv(65536)
    check("pipelined", data.count(b"HTTP/1.1 200") == 2, data[:80])
    raw.close()
    # Slow loris: headers that never finish are cut off after 10 s with 408.
    raw = socket.create_connection(("127.0.0.1", h.port))
    raw.sendall(b"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n")
    raw.settimeout(14)
    started = time.time()
    try:
        data = raw.recv(1024)
    except socket.timeout:
        data = b""
    elapsed = time.time() - started
    check("slow loris 408", data.startswith(b"HTTP/1.1 408") and 9 <= elapsed <= 13, (data[:30], elapsed))
    raw.close()
    run_hardening(h)
    c.close()


def rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(out.strip() or 0)


def run_hardening(h):
    # A client that pipelines without reading replies can't grow memory:
    # the server stops reading while a few requests wait.
    before = rss_kb(h.proc.pid)
    raw = socket.create_connection(("127.0.0.1", h.port))
    raw.setblocking(False)
    chunk = b"GET /x HTTP/1.1\r\nHost: a\r\n\r\n" * 2000
    sent, deadline = 0, time.time() + 3
    while time.time() < deadline:
        try:
            sent += raw.send(chunk)
        except BlockingIOError:
            time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            break  # The server may drop a client that floods it; also bounded.
    grown = rss_kb(h.proc.pid) - before
    raw.close()
    check("pipelined flood is bounded", grown < 50_000, f"sent {sent} bytes, RSS grew {grown} KB")
    # A trickle of one byte every 3 s doesn't extend the 10 s header deadline.
    raw = socket.create_connection(("127.0.0.1", h.port))
    started = time.time()
    data = b""
    for byte in b"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n":
        try:
            raw.sendall(bytes([byte]))
        except OSError:
            break
        raw.settimeout(3)
        try:
            data = raw.recv(1024)
            if data:
                break
        except socket.timeout:
            pass
    elapsed = time.time() - started
    check("trickle cut off at 10 s", data.startswith(b"HTTP/1.1 408") and elapsed < 14, (data[:30], elapsed))
    raw.close()
    # A malformed request pipelined behind a good one is answered after it.
    raw = socket.create_connection(("127.0.0.1", h.port))
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}).encode()
    good = (f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nContent-Type: application/json\r\n"
            f"Authorization: Bearer {h.key('agent')}\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body
    raw.sendall(good + b"BROKEN\r\n\r\n")
    raw.settimeout(5)
    data = b""
    try:
        while b"HTTP/1.1 400" not in data:
            more = raw.recv(65536)
            if not more:
                break
            data += more
    except socket.timeout:
        pass
    check("errors answered in order", data.startswith(b"HTTP/1.1 200") and b"HTTP/1.1 400" in data, data[:60])
    raw.close()
    # A second instance that can't bind leaves the running one's endpoint file alone.
    endpoint = os.path.join(h.dir, "mcp-endpoint.json")
    with open(endpoint) as f:
        written = json.load(f)
    check("endpoint file", written["url"] == f"http://127.0.0.1:{h.port}/mcp" and written["version"] == 1 and
          oct(os.stat(endpoint).st_mode & 0o777) == "0o600", written)
    second = subprocess.run([HARNESS], env=dict(os.environ, BRIDGEKIT_TEST_DIR=h.dir,
                                                BRIDGEKIT_TEST_PORT=str(h.port)),
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
    with open(endpoint) as f:
        owner = json.load(f)["pid"]
    check("second instance keeps the endpoint file", second.returncode != 0 and owner == h.proc.pid,
          (second.returncode, owner))


def run_concurrency(h):
    # Two agents, 25 calls each: under each agent's burst of 30.
    def one(index):
        client = Client(h, h.key("none" if index % 2 else "reader"))
        try:
            if index % 4 < 2:
                status, body = client.call("status", {}, modern=True)
            else:
                client.legacy("initialize", {"protocolVersion": LEGACY, "capabilities": {}}, version=None)
                status, body = client.call("status", {})
            return status == 200 and body["result"]["isError"] is False
        finally:
            client.close()
    with ThreadPoolExecutor(max_workers=25) as pool:
        results = list(pool.map(one, range(50)))
    check("50 concurrent mixed-era calls", all(results), results.count(False))


def run_agent_state(h):
    c = Client(h, h.key("full"))
    _, body = c.call("write_note", {"note": "hello"})
    check("write", body["result"]["isError"] is False and body["result"]["structuredContent"] ==
          {"written": "hello"}, body)
    h.control(cmd="bridge", on=False)
    _, body = c.call("status", {})
    check("app off is the app's answer", text_of(body["result"]).endswith("(code: bridge_off)"), body)
    h.control(cmd="bridge", on=True)
    check("pause", h.control(cmd="pause", agent="full", on=True)["ok"] is True)
    _, body = c.call("status", {})
    check("paused agent still authenticated", text_of(body["result"]).endswith("(code: agent_paused)"), body)
    check("resume", h.control(cmd="pause", agent="full", on=False)["ok"] is True)
    # Key reset: the old key stops working at once.
    old = h.key("full")
    new = h.control(cmd="reset_key", agent="full")["key"]
    status, _, _, _ = Client(h, old).legacy("ping")
    check("old key refused after reset", status == 401, status)
    status, _, _, _ = Client(h, new).legacy("ping")
    check("new key works", status == 200, status)
    check("key file replaced", open(os.path.join(h.dir, "agent-keys",
                                                 h.agents["full"]["id"] + ".mcp-token")).read() == new)
    # Revoked: 401, key file gone.
    h.control(cmd="revoke", agent="reader")
    status, _, _, _ = Client(h, h.key("reader")).legacy("ping")
    check("revoked agent 401", status == 401, status)
    check("revoked key file removed", not os.path.exists(
        os.path.join(h.dir, "agent-keys", h.agents["reader"]["id"] + ".mcp-token")))
    c.close()


def run_limits(h):
    # 120/min with a burst of 30: the 31st quick call is limited, with a wait.
    c = Client(h, h.key("agent"))
    limited = None
    for _ in range(40):
        _, body = c.call("status", {})
        if body["result"]["isError"] and "rate_limited" in text_of(body["result"]):
            limited = text_of(body["result"])
            break
    check("rate limited", limited is not None and "Wait" in limited, limited)
    check("rate_limited recorded", h.activity()[0]["outcome"] == "error:rate_limited")
    c.close()


def run_approvals(h):
    c = Client(h, h.key("ask"))
    note = {"note": "Buy oat milk"}
    result = {}

    def call():
        result["body"] = c.call("write_note", note)[1]
    # Allow.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    h.control(cmd="answer", decision="allow")
    thread.join(10)
    check("approved write", result["body"]["result"]["isError"] is False, result)
    # Reads never ask.
    _, body = c.call("echo", {"text": "a"})
    check("reads never ask", body["result"]["isError"] is False, body)
    # Deny.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    h.control(cmd="answer", decision="deny")
    thread.join(10)
    check("declined", text_of(result["body"]["result"]).endswith("(code: approval_denied)"), result)
    # Disconnect while waiting → cancelled, the panel withdrawn.
    raw = socket.create_connection(("127.0.0.1", h.port))
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": "write_note", "arguments": note}}).encode()
    raw.sendall((f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nContent-Type: application/json\r\n"
                 f"Authorization: Bearer {h.key('ask')}\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body)
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    raw.close()
    check("disconnect withdraws the panel", wait_for(lambda: h.control(cmd="pending")["pending"] == 0))
    wait_for(lambda: h.activity()[0]["outcome"] == "error:cancelled")
    check("disconnect cancels", h.activity()[0]["outcome"] == "error:cancelled", h.activity()[0])
    # Legacy notifications/cancelled withdraws a waiting approval.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    rid = c.next_id
    other = Client(h, h.key("ask"))
    status, _, _, _ = other.legacy("notifications/cancelled", {"requestId": rid}, notify=True)
    thread.join(10)
    check("notifications/cancelled", status == 202 and "cancelled" in text_of(result["body"]["result"]), result)
    # Another agent can't cancel this agent's call.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    rid = c.next_id
    stranger = Client(h, h.key("agent"))
    stranger.legacy("notifications/cancelled", {"requestId": rid}, notify=True)
    time.sleep(0.3)
    check("cancellation is per agent", h.control(cmd="pending")["pending"] == 1)
    h.control(cmd="answer", decision="allow")
    thread.join(10)
    check("still answered", result["body"]["result"]["isError"] is False, result)
    # App turned off while waiting → the app's answer.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    h.control(cmd="bridge", on=False)
    thread.join(10)
    check("app off while waiting", "scope_changed" in text_of(result["body"]["result"]), result)
    h.control(cmd="bridge", on=True)
    other.close()
    stranger.close()
    c.close()


def run_timeout(h):
    # The server answers with its own timeout result before the agent's
    # timeout, without cancelling the call.
    c = Client(h, h.key("agent"))
    started = time.time()
    _, body = c.call("echo", {"text": "late", "delay_ms": 4000})
    elapsed = time.time() - started
    check("timeout answered", text_of(body["result"]).endswith("(code: timeout)") and 1.5 < elapsed < 3.5,
          (body, elapsed))
    check("timed-out call not cancelled", wait_for(lambda: any(
        r["command"] == "echo" and r["outcome"] == "success" for r in h.activity()), 5), h.activity())
    _, body = c.call("echo", {"text": "quick"})
    check("connection usable after a timeout", body["result"]["structuredContent"] == {"text": "quick"}, body)
    c.close()


def run_auth_lockout(h):
    # Over 120 failed authentications a minute: unauthenticated requests get
    # 429 and a closed connection; valid keys are never affected.
    ping = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
    statuses = []
    for _ in range(125):
        statuses.append(Client(h, PREFIX + "1" * 64).raw(body=ping)[0])
    check("lockout 429", statuses[-1] == 429 and statuses[0] == 401, statuses[-5:])
    status, headers, _, _ = Client(h).raw(body=ping)
    check("missing key locked out", status == 429 and "Retry-After" in headers, status)
    status, _, _, _ = Client(h, h.key("agent")).legacy("ping")
    check("valid key unaffected", status == 200, status)
    counters = h.control(cmd="counters")
    check("counters", counters["authFailures"] >= 125 and counters["requests"] > 125, counters)


if __name__ == "__main__":
    main()
