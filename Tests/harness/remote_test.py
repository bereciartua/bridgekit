"""Offline integration tests for BridgeKitRemote over real loopback sockets.

Generalized from EK Bridge's Tests/mcp_test.py `run_remote` and `run_oauth`
(e753b22): the Remote Access listener (secret path, Host, Origin, credentials,
health nonces, the candidate address, the per-address lockout, remote limits)
and the OAuth authorization server (discovery, dynamic registration, pairing,
PKCE, code exchange, refresh rotation and reuse detection, revocation), run
against the reference server's remote listener and fake sign-in approver.
Standard library only.

Usage: remote_test.py SERVER_BINARY
"""

import base64
import hashlib
import json
import os
import re
import sys
import time
from urllib.parse import parse_qs, urlencode, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcp_test  # noqa: E402
from mcp_test import Client, Harness, check, text_of, wait_for  # noqa: E402

LOCAL_PREFIX = "ref_mcp_v1_"
REMOTE_PREFIX = "ref_mcpr_v1_"
ACCESS_PREFIX = "ref_oat_v1_"
SECRET = "q7Zk2vN4bXwP9sL1mT6hYa"
PREFIX = "/r/" + SECRET
REMOTE_HOST = "remote.test"
PING = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}


class Remote(Client):
    """A client of the Remote Access port, as a tunnel would forward it."""

    def __init__(self, harness, port, key=None, host=REMOTE_HOST, forwarded="203.0.113.7"):
        import http.client
        self.h = harness
        self.key = key
        self.host = host
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        self.next_id = 1
        self.forwarded = forwarded

    def raw(self, method="POST", path=PREFIX + "/mcp", body=b"", headers=None, auth=True,
            content_type="application/json"):
        all_headers = {"X-Forwarded-For": self.forwarded, "Tailscale-Funnel-Request": "?1"}
        all_headers.update(headers or {})
        return Client.raw(self, method, path, body, all_headers, auth, content_type)


def form(fields):
    return urlencode(fields).encode()


def start_remote(h):
    h.control(cmd="remote_start")
    wait_for(lambda: h.control(cmd="remote_port")["port"] is not None)
    return h.control(cmd="remote_port")["port"]


def run_remote(h):
    port = start_remote(h)
    token = h.agents["cloud"]["remote"]

    # The secret path comes first: anything else is 404, even with a bad Host.
    for path in ["/", "/mcp", "/r/wrong/mcp", "/r/" + SECRET + "x/mcp", "/.well-known/oauth-authorization-server",
                 "/.well-known/oauth-protected-resource", PREFIX + "/other"]:
        status, _, _, _ = Remote(h, port, token, host="evil.example").raw(path=path, body=PING)
        check(f"remote 404 {path}", status == 404, status)
    status, _, _, _ = Remote(h, port, token, host="evil.example").raw(body=PING)
    check("remote 421 host", status == 421, status)
    for host in [REMOTE_HOST, f"127.0.0.1:{port}", f"localhost:{port}"]:
        status, _, body, _ = Remote(h, port, token, host=host).raw(body=PING)
        check(f"remote host {host}", status == 200 and "result" in body, (status, body))
    status, _, _, _ = Remote(h, port, token).raw(body=PING, headers={"Origin": "https://evil.example"})
    check("remote 403 origin", status == 403, status)
    status, _, _, _ = Remote(h, port, token).raw(method="GET", body=b"")
    check("remote 405 GET", status == 405, status)
    status, _, _, _ = Remote(h, port, token).raw(body=PING, content_type="text/plain")
    check("remote 415", status == 415, status)
    status, _, _, _ = Remote(h, port, token).raw(body=PING, headers={"Accept": "text/html"})
    check("remote 406", status == 406, status)

    # Credentials stay apart: local keys are refused remotely and vice versa.
    status, headers, body, _ = Remote(h, port, h.key("cloud")).raw(body=PING)
    challenge = headers.get("WWW-Authenticate", "")
    check("local key refused remotely", status == 401 and
          f'resource_metadata="https://{REMOTE_HOST}/.well-known/oauth-protected-resource{PREFIX}/mcp"' in challenge
          and 'scope="notes"' in challenge, (status, challenge))
    check("401 wording", "Reference Bridge doesn't recognize this credential" in json.dumps(body), body)
    status, _, _, _ = Client(h, token).raw(body=PING)
    check("remote token refused locally", status == 401, status)
    status, _, _, _ = Remote(h, port, h.agents["agent"]["key"].replace(LOCAL_PREFIX, REMOTE_PREFIX)).raw(body=PING)
    check("a local key with the remote prefix is still refused", status == 401, status)

    # A remote call: same server and pipeline, marked remote.
    remote = Remote(h, port, token)
    _, _, body, _ = remote.raw(body=PING)
    names = sorted(t["name"] for t in body["result"]["tools"])
    check("remote tools as for the agent", names == ["echo", "status", "write_note"], names)
    status, body = remote.call("echo", {"text": "hi"})
    check("remote call", status == 200 and body["result"]["structuredContent"] == {"text": "hi"}, body)
    row = h.activity()[0]
    check("activity via remote", row["via"] == "remote" and row["outcome"] == "success", row)
    status, body = Client(h, h.key("cloud")).call("echo", {"text": "local"})
    check("the same agent locally", status == 200 and h.activity()[0]["via"] == "mcp", h.activity()[0])
    notes = h.control(cmd="remote_notes")["notes"]
    check("remote note: tunnel and forwarded address", notes and notes[0]["tunnel"] == "Tailscale Funnel" and
          notes[0]["address"] == "203.0.113.7" and notes[0]["agentID"] == h.agents["cloud"]["id"], notes[:1])
    # Pausing refuses remote calls too, without touching the remote token.
    h.control(cmd="pause", agent="cloud", on=True)
    status, body = remote.call("status", {})
    check("remote paused", status == 200 and "agent_paused" in text_of(body["result"]), body)
    h.control(cmd="pause", agent="cloud", on=False)

    # Cloud access off: the remote token stops working at once.
    h.control(cmd="set_cloud", agent="cloud", on=False)
    status, _, _, _ = Remote(h, port, token).raw(body=PING)
    check("cloud access off refuses", status == 401, status)
    h.control(cmd="set_cloud", agent="cloud", on=True)
    status, _, _, _ = Remote(h, port, token).raw(body=PING)
    check("turning cloud access off deleted the token", status == 401, status)
    token = h.control(cmd="issue_remote_token", agent="cloud")["token"]
    remote = Remote(h, port, token)
    status, _, _, _ = remote.raw(body=PING)
    check("new remote token works", status == 200, status)
    # A removed agent's credentials stop at once.
    h.control(cmd="set_cloud", agent="agent", on=True)
    removed_token = h.control(cmd="issue_remote_token", agent="agent")["token"]
    status, _, _, _ = Remote(h, port, removed_token).raw(body=PING)
    check("second agent's remote token", status == 200, status)
    h.control(cmd="revoke", agent="agent")
    status, _, _, _ = Remote(h, port, removed_token).raw(body=PING)
    check("removed agent refused", status == 401, status)

    # Health: only for a nonce the app issued in the last 30 s, once.
    status, _, _, _ = Remote(h, port).raw(method="GET", path=PREFIX + "/health?nonce=madeup", body=b"")
    check("health unknown nonce 404", status == 404, status)
    nonce = h.control(cmd="nonce")["nonce"]
    status, _, body, _ = Remote(h, port).raw(method="GET", path=PREFIX + "/health?nonce=" + nonce, body=b"")
    check("health ok", status == 200 and body["nonce"] == nonce and body["tunnel"] == "Tailscale Funnel", body)
    status, _, _, _ = Remote(h, port).raw(method="GET", path=PREFIX + "/health?nonce=" + nonce, body=b"")
    check("health nonce single use", status == 404, status)

    # A candidate address being tested (Switch Tunnel…): its Host gets the
    # health check only, never MCP, OAuth or discovery, and only while set.
    candidate = "quiet-river-1234.trycloudflare.com"

    def candidate_health():
        nonce = h.control(cmd="nonce")["nonce"]
        status, _, body, _ = Remote(h, port, host=candidate).raw(
            method="GET", path=PREFIX + "/health?nonce=" + nonce, body=b"")
        return status, body, nonce
    check("candidate host 421 before the test", candidate_health()[0] == 421)
    h.control(cmd="remote_candidate", origin="https://" + candidate)
    status, body, nonce = candidate_health()
    check("candidate health", status == 200 and body["nonce"] == nonce, (status, body))
    for method, path in [("POST", PREFIX + "/mcp"), ("GET", PREFIX + "/oauth/authorize?client_id=x"),
                         ("POST", PREFIX + "/oauth/token"), ("POST", PREFIX + "/oauth/register"),
                         ("GET", "/.well-known/oauth-protected-resource" + PREFIX + "/mcp"),
                         ("GET", "/.well-known/oauth-authorization-server" + PREFIX)]:
        status, _, _, _ = Remote(h, port, token, host=candidate).raw(method=method, path=path,
                                                                    body=json.dumps(PING).encode())
        check(f"candidate host 421 {method} {path}", status == 421, status)
    status, _, body, _ = Remote(h, port, token).raw(body=PING)
    check("the address in use keeps working", status == 200 and "result" in body, status)
    h.control(cmd="remote_candidate", origin=None)
    check("candidate host 421 after", candidate_health()[0] == 421)

    run_oauth(h, port)
    # run_oauth turned the agent's cloud access off and on, which deleted its token.
    token = h.control(cmd="issue_remote_token", agent="cloud")["token"]
    remote = Remote(h, port, token)

    # The reference app uses the limiter's remote buckets for remote calls: 15 in a burst.
    limited = None
    for _ in range(30):
        _, body = remote.call("status", {})
        if body["result"]["isError"]:
            limited = text_of(body["result"])
            break
    check("remote rate limit", limited is not None and "rate_limited" in limited, limited)

    # Failed authentication locks out one forwarded address, not others.
    statuses = [Remote(h, port, REMOTE_PREFIX + "0" * 64, forwarded="198.51.100.9").raw(body=PING)[0]
                for _ in range(32)]
    check("remote lockout per address", statuses[0] == 401 and statuses[-1] == 429, statuses[-3:])
    status, _, _, _ = Remote(h, port, REMOTE_PREFIX + "0" * 64, forwarded="198.51.100.10").raw(body=PING)
    check("other address unaffected", status == 401, status)
    # A valid credential is never locked out, even from a locked address (anyone can claim one).
    status, _, _, _ = Remote(h, port, token, forwarded="198.51.100.9").raw(body=PING)
    check("valid token bypasses lockout", status == 200, status)
    status, _, _, _ = Remote(h, port, None, forwarded="198.51.100.9").raw(body=PING, auth=False)
    check("no token from locked address", status == 429, status)
    # Only the last X-Forwarded-For entry (the one the tunnel appended) counts.
    status, _, _, _ = Remote(h, port, REMOTE_PREFIX + "0" * 64,
                             forwarded="198.51.100.9, 198.51.100.11").raw(body=PING)
    check("spoofed leading X-Forwarded-For ignored", status == 401, status)
    check("refusals reach the app", h.control(cmd="remote_failures")["failures"] > 0)

    # Reset Path…: the old URL is 404, OAuth connections for it are gone.
    reset = h.control(cmd="remote_secret", secret="Zz9Yy8Xx7Ww6Vv5Uu4Tt3S")
    status, _, _, _ = Remote(h, port, token).raw(body=PING)
    check("old path 404 after reset", status == 404 and reset["ok"], status)
    status, _, _, _ = Remote(h, port, token).raw(path="/r/Zz9Yy8Xx7Ww6Vv5Uu4Tt3S/mcp", body=PING)
    check("new path works", status == 200, status)

    # Turning Remote Access off closes the port and ends pairing.
    h.control(cmd="open_pairing", agent="cloud")
    h.control(cmd="remote_stop")
    check("pairing ends with Remote Access", h.control(cmd="pairings")["open"] is None)
    try:
        Remote(h, port, token).raw(body=PING)
        closed = False
    except OSError:
        closed = True
    check("remote port closed when off", closed)


def status_url(page):
    """The page polls `authorize/status?request=<id>` relative to itself."""
    found = re.search(rb'data-request="([0-9A-Za-z-]+)"', page)
    return PREFIX + "/oauth/authorize/status?request=" + found.group(1).decode() if found else None


def run_oauth(h, port):
    resource = f"https://{REMOTE_HOST}{PREFIX}/mcp"
    issuer = f"https://{REMOTE_HOST}{PREFIX}"
    o = Remote(h, port)
    status, _, prm, _ = o.raw(method="GET", path=f"/.well-known/oauth-protected-resource{PREFIX}/mcp", body=b"")
    check("PRM", status == 200 and prm["resource"] == resource and prm["authorization_servers"] == [issuer] and
          prm["scopes_supported"] == ["notes"], prm)
    status, _, asm, _ = o.raw(method="GET", path=f"/.well-known/oauth-authorization-server{PREFIX}", body=b"")
    check("AS metadata", status == 200 and asm["issuer"] == issuer and
          asm["code_challenge_methods_supported"] == ["S256"], asm)
    callback = "https://claude.ai/api/mcp/auth_callback"

    def register():
        return o.raw(path=PREFIX + "/oauth/register", body={"redirect_uris": [callback], "client_name": "claude.ai"})
    status, _, body, _ = register()
    check("DCR needs pairing", status == 403 and "open the agent" in body.get("error_description", ""),
          (status, body))
    verifier = "v" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")

    def query(client_id):
        return urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": callback,
                          "code_challenge": challenge, "code_challenge_method": "S256", "state": "xyz",
                          "resource": resource})
    # Pairing closed: the page says so and nothing is shown on the Mac.
    status, _, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + query("dcr_x"), body=b"",
                               content_type=None)
    check("pairing closed page", status == 403 and b"Pairing isn" in page and
          h.control(cmd="pairings")["pending"] == [], (status, page[:120]))
    h.control(cmd="open_pairing", agent="cloud")
    status, _, reg, _ = register()
    check("DCR", status == 201 and reg["client_id"].startswith("dcr_"), (status, reg))
    status, headers, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + query(reg["client_id"]),
                                     body=b"", content_type=None)
    pending = h.control(cmd="pairings")["pending"]
    check("authorize page", status == 200 and len(pending) == 1 and
          pending[0]["code"].replace(" ", "").encode() in page.replace(b" ", b"") and
          pending[0]["agentID"] == h.agents["cloud"]["id"] and pending[0]["redirectHost"] == "claude.ai",
          (status, pending))
    check("authorize page names the agent", b"<dt>Agent</dt><dd>cloud</dd>" in page, page[:400])
    check("authorize page headers", "DENY" in headers.get("X-Frame-Options", "") and
          "no-store" in headers.get("Cache-Control", "") and
          "default-src 'none'" in headers.get("Content-Security-Policy", ""), headers)
    status_path = status_url(page)
    check("status URL in page", status_path is not None, page[:200])
    _, _, body, _ = o.raw(method="GET", path=status_path, body=b"", content_type=None)
    check("status pending", body == {"status": "pending"}, body)
    h.control(cmd="answer_pairing", allow=True)
    _, _, body, _ = o.raw(method="GET", path=status_path, body=b"", content_type=None)
    redirect = body.get("redirect", "") if isinstance(body, dict) else ""
    params = parse_qs(urlparse(redirect).query)
    check("redirect with code", redirect.startswith(callback) and params.get("state") == ["xyz"] and
          params.get("iss") == [issuer] and "code" in params, body)
    check("one app per window", h.control(cmd="pairings")["open"] is None)
    code = params.get("code", [""])[0]

    def token_request(fields, headers=None):
        return o.raw(path=PREFIX + "/oauth/token", body=form(fields), headers=headers,
                     content_type="application/x-www-form-urlencoded")
    status, _, bad, _ = token_request({"grant_type": "authorization_code", "code": code,
                                       "client_id": reg["client_id"], "redirect_uri": callback,
                                       "code_verifier": "w" * 64})
    check("PKCE mismatch", status == 400 and bad["error"] == "invalid_grant", bad)
    # The code was spent by the failed attempt; start again.
    h.control(cmd="open_pairing", agent="cloud")
    _, _, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + query(reg["client_id"]), body=b"",
                          content_type=None)
    status_path = status_url(page)
    h.control(cmd="answer_pairing", allow=True)
    _, _, body, _ = o.raw(method="GET", path=status_path, body=b"", content_type=None)
    code = parse_qs(urlparse(body["redirect"]).query)["code"][0]
    exchange = {"grant_type": "authorization_code", "code": code, "client_id": reg["client_id"],
                "redirect_uri": callback, "code_verifier": verifier, "resource": resource}
    status, _, tokens, _ = token_request(exchange)
    check("token exchange", status == 200 and tokens["access_token"].startswith(ACCESS_PREFIX) and
          tokens["refresh_token"].startswith("ref_ort_v1_") and tokens["scope"] == "notes" and
          tokens["token_type"].lower() == "bearer", tokens)
    check("connection listed", h.control(cmd="oauth_connections", agent="cloud")["count"] == 1)
    m = Remote(h, port, tokens["access_token"])
    status, body = m.call("status", {})
    check("MCP with OAuth token", status == 200 and body["result"]["isError"] is False, body)
    check("OAuth call via remote", h.activity()[0]["via"] == "remote", h.activity()[0])
    status, _, _, _ = Client(h, tokens["access_token"]).raw(body=PING)
    check("OAuth token refused locally", status == 401, status)
    # A replayed code revokes what it produced.
    status, _, replay, _ = token_request(exchange)
    check("code replay refused", status == 400 and replay["error"] == "invalid_grant", replay)
    status, _, _, _ = m.raw(body=PING)
    check("code replay revoked the connection", status == 401, status)

    # Again, then refresh rotation and reuse detection.
    h.control(cmd="open_pairing", agent="cloud")
    _, _, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + query(reg["client_id"]), body=b"",
                          content_type=None)
    status_path = status_url(page)
    h.control(cmd="answer_pairing", allow=True)
    _, _, body, _ = o.raw(method="GET", path=status_path, body=b"", content_type=None)
    exchange["code"] = parse_qs(urlparse(body["redirect"]).query)["code"][0]
    status, _, tokens, _ = token_request(exchange)
    check("second token exchange", status == 200, tokens)
    status, _, rotated, _ = token_request({"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
                                           "client_id": reg["client_id"]})
    check("refresh", status == 200 and rotated["refresh_token"] != tokens["refresh_token"], rotated)
    status, _, _, _ = Remote(h, port, rotated["access_token"]).raw(body=PING)
    check("rotated access works", status == 200, status)
    status, _, reuse, _ = token_request({"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
                                         "client_id": reg["client_id"]})
    check("refresh reuse detected", status == 400 and reuse["error"] == "invalid_grant", reuse)
    status, _, _, _ = Remote(h, port, rotated["access_token"]).raw(body=PING)
    check("reuse revoked the connection", status == 401, status)
    check("no connections left", h.control(cmd="oauth_connections", agent="cloud")["count"] == 0)

    # Deny sends access_denied back to the app.
    h.control(cmd="open_pairing", agent="cloud")
    _, _, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + query(reg["client_id"]), body=b"",
                          content_type=None)
    status_path = status_url(page)
    h.control(cmd="answer_pairing", allow=False)
    _, _, body, _ = o.raw(method="GET", path=status_path, body=b"", content_type=None)
    params = parse_qs(urlparse(body.get("redirect", "")).query)
    check("deny", params.get("error") == ["access_denied"] and
          params.get("error_description") == ["The connection was declined in Reference Bridge."], body)

    # A client set up ahead (Gemini Enterprise): secret in a Basic header, bound to its agent.
    gemini = "https://vertexaisearch.cloud.google.com/oauth-redirect"
    client = h.control(cmd="confidential_client", agent="cloud", redirect_uri=gemini)
    check("confidential client", client["ok"] and client["client_id"].startswith("cfg_") and
          client["secret"].startswith("ref_ocs_v1_"), client)
    h.control(cmd="open_pairing", agent="cloud")
    gemini_query = urlencode({"response_type": "code", "client_id": client["client_id"], "redirect_uri": gemini,
                              "code_challenge": challenge, "code_challenge_method": "S256"})
    _, _, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + gemini_query, body=b"",
                          content_type=None)
    status_path = status_url(page)
    h.control(cmd="answer_pairing", allow=True)
    _, _, body, _ = o.raw(method="GET", path=status_path, body=b"", content_type=None)
    code = parse_qs(urlparse(body["redirect"]).query)["code"][0]
    fields = {"grant_type": "authorization_code", "code": code, "redirect_uri": gemini, "code_verifier": verifier}
    status, _, wrong, _ = token_request(fields, headers={
        "Authorization": "Basic " + base64.b64encode((client["client_id"] + ":wrong").encode()).decode()})
    check("confidential client: wrong secret", status == 401 and wrong["error"] == "invalid_client", wrong)
    # The failed attempt didn't spend the code (the secret is checked first).
    status, _, gemini_tokens, _ = token_request(fields, headers={
        "Authorization": "Basic " + base64.b64encode((client["client_id"] + ":" + client["secret"]).encode()).decode()})
    check("confidential client: token", status == 200 and gemini_tokens["access_token"].startswith(ACCESS_PREFIX),
          gemini_tokens)

    # Turning the agent's cloud access off revokes its apps at once.
    h.control(cmd="set_cloud", agent="cloud", on=False)
    status, _, _, _ = Remote(h, port, gemini_tokens["access_token"]).raw(body=PING)
    check("cloud access off revokes OAuth", status == 401 and
          h.control(cmd="oauth_connections", agent="cloud")["count"] == 0, status)
    h.control(cmd="set_cloud", agent="cloud", on=True)
    # Pairing for an agent without cloud access shows the page, not a prompt.
    h.control(cmd="set_cloud", agent="reader", on=False)
    h.control(cmd="open_pairing", agent="reader")
    status, _, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + query(reg["client_id"]), body=b"",
                               content_type=None)
    check("cloud access off: no prompt", status == 403 and b"no longer allows cloud access" in page and
          h.control(cmd="pairings")["pending"] == [], (status, page[:160]))
    h.control(cmd="close_pairing")


def main():
    binary = sys.argv[1]
    h = Harness(binary)
    try:
        run_remote(h)
    finally:
        h.close()
    if mcp_test.failures:
        print("Remote Access tests failed:")
        for failure in mcp_test.failures:
            print("  " + failure)
        sys.exit(1)
    print(f"BridgeKitRemote: {mcp_test.checks} checks over loopback (secret path, Host, Origin, credentials, "
          "health nonces, candidate address, lockout, OAuth pairing, PKCE, refresh rotation, revocation) passed")


if __name__ == "__main__":
    main()
