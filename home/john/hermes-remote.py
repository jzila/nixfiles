"""Sign-in and attach tickets for the remote Hermes TUI (hermes.nix).

`login`: the dashboard's native-app sign-in (RFC 8252, through its OIDC provider) with a loopback
redirect; the tokens go to a 0600 file. `ticket`: a fresh single-use WebSocket ticket, refreshing
the tokens when they are near expiry or rejected.
"""

import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

BASE = os.environ["HERMES_REMOTE_URL"]
TOKENS = Path(os.environ["HERMES_REMOTE_STATE"]) / "tokens.json"


def post(path, body=None, bearer=None):
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    req = urllib.request.Request(BASE + path, method="POST", headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def save(tokens):
    TOKENS.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(TOKENS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(tokens, f)


def login():
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    reply = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            reply.update(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Signed in to Hermes; you can close this tab.")

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Callback)
    url = BASE + "/auth/native/authorize?" + urllib.parse.urlencode({
        "provider": "self-hosted", "code_challenge": challenge, "code_challenge_method": "S256",
        "redirect_uri": f"http://127.0.0.1:{server.server_port}/callback", "state": state})
    print(f"Sign in at {url}", file=sys.stderr)
    webbrowser.open(url)
    while not reply:
        server.handle_request()
    if reply.get("state") != state or "code" not in reply:
        sys.exit(f"Sign-in failed: {reply.get('error', 'no code')}")
    save(post("/auth/native/token", {"code": reply["code"], "code_verifier": verifier}))
    print("Signed in.", file=sys.stderr)


def refresh(tokens):
    tokens = post("/auth/native/refresh", {"refresh_token": tokens["refresh_token"], "provider": tokens["provider"]})
    save(tokens)
    return tokens


def ticket():
    try:
        tokens = json.loads(TOKENS.read_text())
    except FileNotFoundError:
        sys.exit("Not signed in: run `hermes login`.")
    try:
        if tokens["expires_at"] < time.time() + 60:
            tokens = refresh(tokens)
        try:
            print(post("/api/auth/ws-ticket", bearer=tokens["access_token"])["ticket"])
        except urllib.error.HTTPError as e:
            if e.code != 401:
                raise
            print(post("/api/auth/ws-ticket", bearer=refresh(tokens)["access_token"])["ticket"])
    except urllib.error.HTTPError as e:
        sys.exit("Session expired: run `hermes login`." if e.code == 401 else f"Hermes: HTTP {e.code}")


{"login": login, "ticket": ticket}[sys.argv[1]]()
