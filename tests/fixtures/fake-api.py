#!/usr/bin/env python3
"""Small AF_UNIX API service used by the host Caddy edge integration test."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import socketserver
import uuid
from http.server import BaseHTTPRequestHandler


EXPECTED_KEY = os.environ["FAKE_API_KEY"]
EXPECTED_CLIENT_IP = os.environ["FAKE_API_CLIENT_IP"]
CREATED_KEY = "imp_" + ("c" * 43)


class ThreadingUnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeAPI/1.0"
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def respond(
        self,
        status: int,
        body: bytes = b"",
        content_type: str = "application/json",
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        if body:
            self.send_header("Content-Type", content_type)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=3600")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Credentials", "true")
        self.send_header("X-Content-Type-Options", "unsafe")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def respond_json(
        self, status: int, payload: object, headers: dict[str, str] | None = None
    ) -> None:
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
        self.respond(status, body, headers=headers)

    def respond_problem(self, status: int, title: str, detail: str) -> None:
        body = json.dumps(
            {
                "detail": detail,
                "request_id": str(uuid.uuid4()),
                "status": status,
                "title": title,
                "type": "about:blank",
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
        self.respond(status, body, "application/problem+json")

    def authenticated(self) -> bool:
        values = self.headers.get_all("Authorization", failobj=[])
        return values == [f"Bearer {EXPECTED_KEY}"]

    def proxy_headers_valid(self) -> bool:
        if self.headers.get_all("Cookie", failobj=[]):
            return False
        api_headers = [
            (name.lower(), value)
            for name, value in self.headers.items()
            if name.lower().startswith("x-api-")
        ]
        return api_headers == [("x-api-client-ip", EXPECTED_CLIENT_IP)]

    def authorize(self) -> bool:
        if not self.authenticated():
            body = json.dumps(
                {
                    "detail": "A valid bearer API key is required.",
                    "request_id": str(uuid.uuid4()),
                    "status": 401,
                    "title": "Unauthorized",
                    "type": "about:blank",
                },
                separators=(",", ":"),
                sort_keys=True,
            ).encode()
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Bearer realm="imessage-proxy"')
            self.send_header("Content-Type", "application/problem+json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return False
        if not self.proxy_headers_valid():
            self.respond_problem(502, "Bad Gateway", "The proxy metadata was invalid.")
            return False
        return True

    def read_json(self) -> object:
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length))

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self.authorize():
            return
        if self.path == "/api/status":
            self.respond_json(
                200,
                {
                    "key": {
                        "expires_at": "2026-11-07T12:00:00Z",
                        "id": "11111111-1111-4111-8111-111111111111",
                        "key_prefix": "imp_aaaaaaaa",
                        "name": "Edge test administrator",
                        "scopes": ["admin"],
                    },
                    "messages": {"dependency_version": "0.13.4", "status": "ready"},
                    "status": "ok",
                    "uptime_seconds": 7322,
                    "version": "edge-test",
                },
            )
            return
        if self.path == "/api/keys":
            self.respond_json(
                200,
                {
                    "keys": [
                        {
                            "created_at": "2026-08-09T12:00:00Z",
                            "expires_at": "2026-11-07T12:00:00Z",
                            "id": "11111111-1111-4111-8111-111111111111",
                            "key_prefix": "imp_aaaaaaaa",
                            "last_used_at": "2026-08-09T12:05:00Z",
                            "name": "Edge test administrator",
                            "revoked_at": None,
                            "scopes": ["admin"],
                        }
                    ]
                },
            )
            return
        if self.path == "/api/keys/11111111-1111-4111-8111-111111111111":
            self.respond_json(
                200,
                {
                    "created_at": "2026-08-09T12:00:00Z",
                    "expires_at": "2026-11-07T12:00:00Z",
                    "id": "11111111-1111-4111-8111-111111111111",
                    "key_prefix": "imp_aaaaaaaa",
                    "last_used_at": "2026-08-09T12:05:00Z",
                    "name": "Edge test administrator",
                    "revoked_at": None,
                    "scopes": ["admin"],
                },
            )
            return
        if self.path == "/api/chats/42/background":
            self.respond_json(
                200,
                {
                    "background_set": True,
                    "cache_exists": True,
                    "chat_id": 42,
                    "file_size": 2048,
                    "latest_event": {
                        "action": "set",
                        "date": "2026-08-09T12:03:00Z",
                    },
                    "watch_background_exists": False,
                },
            )
            return
        if self.path == "/api/audit-events?limit=1":
            self.respond_json(
                200,
                {
                    "events": [
                        {
                            "action": "status.read",
                            "created_at": "2026-08-09T12:05:00Z",
                            "duration_ms": 3,
                            "key_id": "11111111-1111-4111-8111-111111111111",
                            "phase": "final",
                            "request_id": "33333333-3333-4333-8333-333333333333",
                            "source": EXPECTED_CLIENT_IP,
                            "status": 200,
                            "target_key_id": None,
                        }
                    ]
                },
            )
            return
        self.respond_problem(404, "Not Found", "The requested API route does not exist.")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self.authorize():
            return
        if self.path != "/api/keys":
            self.respond_problem(404, "Not Found", "The requested API route does not exist.")
            return
        try:
            request = self.read_json()
        except (ValueError, json.JSONDecodeError):
            self.respond_problem(400, "Bad Request", "The JSON body is invalid.")
            return
        if not isinstance(request, dict):
            self.respond_problem(400, "Bad Request", "The request must be an object.")
            return
        name = request.get("name")
        scopes = request.get("scopes")
        expires_in_days = request.get("expires_in_days")
        valid_scopes = {"messages:read", "messages:send", "admin"}
        if (
            set(request) != {"expires_in_days", "name", "scopes"}
            or not isinstance(name, str)
            or not 1 <= len(name) <= 80
            or not isinstance(scopes, list)
            or not 1 <= len(scopes) <= 3
            or len(set(scopes)) != len(scopes)
            or any(not isinstance(scope, str) or scope not in valid_scopes for scope in scopes)
            or isinstance(expires_in_days, bool)
            or not isinstance(expires_in_days, int)
            or not 1 <= expires_in_days <= 365
        ):
            self.respond_problem(400, "Bad Request", "The API key request is invalid.")
            return
        self.respond_json(
            201,
            {
                "created_at": "2026-08-09T12:10:00Z",
                "expires_at": "2026-11-07T12:10:00Z",
                "id": "22222222-2222-4222-8222-222222222222",
                "key": CREATED_KEY,
                "key_prefix": "imp_cccccccc",
                "name": name,
                "last_used_at": None,
                "revoked_at": None,
                "scopes": scopes,
            },
            {"Location": "/api/keys/22222222-2222-4222-8222-222222222222"},
        )

    def do_DELETE(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self.authorize():
            return
        if self.path == "/api/keys/22222222-2222-4222-8222-222222222222":
            self.respond(204)
            return
        self.respond_problem(404, "Not Found", "The API key was not found.")

    def do_OPTIONS(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self.authorize():
            return
        self.respond_problem(404, "Not Found", "The requested API route does not exist.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    args = parser.parse_args()
    socket_path = pathlib.Path(args.socket)
    if socket_path.exists():
        raise SystemExit("socket path already exists")
    server = ThreadingUnixHTTPServer(str(socket_path), Handler)
    os.chmod(socket_path, 0o600)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        socket_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
