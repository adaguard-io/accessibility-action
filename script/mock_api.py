#!/usr/bin/env python3
"""
Mock ADAGuard API for testing the action without spending real scans.

Mirrors the shapes POST /v1/scan and GET /v1/scan/{id}/status actually return,
including the two behaviours that are easy to get wrong:
  * `passed` is false whenever auth_status is expired_fallback, whatever the score
  * `score` and the issue counts are null until the scan reaches a terminal state

Drive the outcome with the SCENARIO env var:
  pass | fail_score | expired_fallback | scan_error | unauthorized | quota
"""

import json
import os
import re
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIO = os.environ.get("SCENARIO", "pass")
PORT = int(os.environ.get("PORT", "8787"))

SCAN_ID = "11111111-2222-3333-4444-555555555555"

# How many status polls to report as still running before going terminal, so the
# polling loop is genuinely exercised rather than short-circuited on poll one.
POLLS_BEFORE_DONE = int(os.environ.get("POLLS_BEFORE_DONE", "1"))
_polls = {"n": 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep the test output readable

    def _send(self, code, payload, extra_headers=None):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.path.startswith("/v1/scan"):
            return self._send(404, {"detail": "not found"})

        if self.headers.get("X-API-Key") in (None, ""):
            return self._send(401, {"detail": "Missing API key"})

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode() if length else "{}"
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            return self._send(400, {"detail": "invalid json"})

        # Record what the action sent, so the test can assert on the request body.
        with open(os.environ.get("REQUEST_DUMP", "/tmp/adaguard_mock_request.json"), "w") as fh:
            json.dump(body, fh)

        # Record headers too, so the test can assert on Idempotency-Key.
        with open(os.environ.get("HEADER_DUMP", "/tmp/adaguard_mock_headers.json"), "w") as fh:
            json.dump({k.lower(): v for k, v in self.headers.items()}, fh)

        if SCENARIO == "idempotent_replay":
            return self._send(200, {
                "scan_id": SCAN_ID, "status": "completed", "url": body.get("url"),
                "created_at": "2026-01-01T00:00:00Z",
                "poll_url": f"/v1/scan/{SCAN_ID}/status", "idempotent_replay": True,
            })

        if SCENARIO == "unauthorized":
            return self._send(401, {"detail": "Invalid API key"})
        if SCENARIO == "quota":
            # Monthly quota — tagged so the action can distinguish it from a
            # transient throttle. Won't clear by retrying.
            return self._send(
                429,
                {"detail": {"error": "Monthly scan limit reached", "scans_used": 30, "scans_limit": 30, "upgrade_url": "/billing"}},
                extra_headers={"X-RateLimit-Type": "quota"},
            )
        if SCENARIO == "rate_limit":
            # Transient hourly throttle — carries Retry-After.
            return self._send(
                429,
                {"detail": "Rate limit exceeded"},
                extra_headers={"X-RateLimit-Type": "rate_limit", "Retry-After": "42"},
            )

        return self._send(200, {"scan_id": SCAN_ID, "status": "queued", "poll_url": f"/v1/scan/{SCAN_ID}/status"})

    def do_GET(self):
        m = re.match(r"^/v1/scan/([^/]+)/status", self.path)
        if not m:
            return self._send(404, {"detail": "not found"})

        _polls["n"] += 1
        if _polls["n"] <= POLLS_BEFORE_DONE:
            return self._send(200, {
                "scan_id": SCAN_ID, "status": "in_progress", "url": "https://example.com",
                "pages_scanned": 0, "max_pages": 1, "score": None, "passed": None,
                "issues_critical": None, "issues_warning": None, "issues_info": None,
                "auth_status": "not_requested", "error": None, "poll_again_in": 3,
            })

        if SCENARIO == "scan_error":
            return self._send(200, {
                "scan_id": SCAN_ID, "status": "failed", "url": "https://example.com",
                "pages_scanned": 0, "max_pages": 1, "score": None, "passed": None,
                "issues_critical": None, "issues_warning": None, "issues_info": None,
                "auth_status": "not_requested", "error": "Navigation timed out", "poll_again_in": None,
            })

        if SCENARIO == "expired_fallback":
            # Score is high, but passed is false — the point of the scenario.
            return self._send(200, {
                "scan_id": SCAN_ID, "status": "completed", "url": "https://example.com",
                "pages_scanned": 3, "max_pages": 5, "score": 95, "passed": False,
                "issues_critical": 0, "issues_warning": 2, "issues_info": 1,
                "auth_status": "expired_fallback", "error": None, "poll_again_in": None,
            })

        score, passed = (42, False) if SCENARIO == "fail_score" else (91, True)
        return self._send(200, {
            "scan_id": SCAN_ID, "status": "completed", "url": "https://example.com",
            "pages_scanned": 1, "max_pages": 1, "score": score, "passed": passed,
            "issues_critical": 3 if not passed else 0, "issues_warning": 5, "issues_info": 2,
            "auth_status": "not_requested", "error": None, "poll_again_in": None,
        })


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
