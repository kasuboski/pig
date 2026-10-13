#!/usr/bin/env python3
"""Opt-in live wire proof; response data and credentials are never saved."""
import copy
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.environ.get("UPSTREAM_BASE_URL", "http://llms/v1").rstrip("/")
KEY = os.environ.get("UPSTREAM_API_KEY", "")
ROOT = Path(__file__).resolve().parents[1]
CAPTURED = []


def request(url, body=None, key=""):
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url, data=body, headers=headers)
    try:
        response = urllib.request.urlopen(req, timeout=180)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers.get("Content-Type", "application/json"), response.read()


class Recorder(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        CAPTURED.append(body)
        status, content_type, response = request(BASE + "/responses", body, KEY)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_):
        pass


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def completed(body):
    events = []
    for line in body.decode().splitlines():
        if line.startswith("data:"):
            try:
                events.append(json.loads(line[5:].strip()))
            except json.JSONDecodeError:
                pass
    terminal = [e for e in events if e.get("type") == "response.completed"]
    assert terminal, "missing response.completed SSE event"
    response = terminal[-1]["response"]
    assert response["status"] == "completed", response.get("status")
    text = "".join(c.get("text", "") for item in response.get("output", []) for c in item.get("content", []))
    assert "CACHE_OK" in text, "missing CACHE_OK output"


def cache_rejection(body):
    value = json.loads(body)
    error = value.get("error", value)
    assert error.get("param") == "prompt_cache_options", error
    assert error.get("code") == "invalid_parameter", error
    return error["message"]


def main():
    payload = {
        "model": "gpt-6-luna",
        "input": [{"role": "user", "content": [{"type": "input_text", "text": "Reply with exactly CACHE_OK"}]}],
        "instructions": "Answer briefly.",
        "reasoning": {"effort": "low"},
        "prompt_cache_options": {"mode": "explicit"},
        "store": False,
        "stream": True,
    }
    original = json.dumps(payload).encode()
    print("Model: gpt-6-luna; reasoning: low", flush=True)
    status, _, body = request(BASE + "/responses", original, KEY)
    if status == 400:
        message = cache_rejection(body)
        print(f"direct explicit-cache: HTTP 400, {message}", flush=True)
    else:
        assert status == 200, f"direct explicit-cache HTTP {status}: {body[:300]!r}"
        completed(body)
        print("direct explicit-cache: HTTP 200, completed CACHE_OK (upstream supports option)", flush=True)
    baseline_status = status
    fixed = copy.deepcopy(payload)
    del fixed["prompt_cache_options"]
    status, _, body = request(BASE + "/responses", json.dumps(fixed).encode(), KEY)
    assert status == 200, f"direct omitted HTTP {status}: {body[:300]!r}"
    completed(body)
    print("direct omitted: HTTP 200, completed CACHE_OK", flush=True)

    recorder = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
    threading.Thread(target=recorder.serve_forever, daemon=True).start()
    try:
        for policy in ("preserve", "omit"):
            port = unused_port()
            env = os.environ | {
                "OPENAI_COMPAT_BASE_URL": f"http://127.0.0.1:{recorder.server_port}/v1",
                "OPENAI_COMPAT_API_KEY": "",
                "PIG_PROXY_PORT": str(port),
                "PROMPT_CACHE_POLICY": policy,
            }
            # Avoid pipe backpressure; retain diagnostics only until this run ends.
            with tempfile.TemporaryFile() as log:
                proc = subprocess.Popen(["gleam", "run", "-m", "support/prompt_cache_live"], cwd=ROOT / "packages/pig_proxy", env=env, stdout=log, stderr=log, start_new_session=True)
                try:
                    url = f"http://127.0.0.1:{port}"
                    for _ in range(300):
                        if proc.poll() is not None:
                            log.seek(0)
                            raise AssertionError(log.read().decode())
                        try:
                            if request(url + "/health")[0] == 200:
                                break
                        except urllib.error.URLError:
                            time.sleep(0.1)
                    else:
                        raise AssertionError("Pig listener did not become ready")
                    before = len(CAPTURED)
                    status, _, body = request(url + "/v1/responses", original)
                    assert len(CAPTURED) == before + 1, "unexpected physical retries"
                    actual = CAPTURED[-1]
                    if policy == "preserve":
                        assert actual == original, "preserve changed wire bytes"
                        assert status == baseline_status, f"preserve HTTP {status}"
                        if status == 400:
                            cache_rejection(body)
                            print("Pig preserve: HTTP 400; option preserved byte-for-byte; one physical attempt", flush=True)
                        else:
                            completed(body)
                            print("Pig preserve: HTTP 200; completed CACHE_OK; exact wire bytes", flush=True)
                    else:
                        assert json.loads(actual) == fixed, "omission changed unrelated request fields"
                        assert status == 200, f"Pig omit HTTP {status}: {body[:300]!r}"
                        completed(body)
                        print("Pig exact-model omit: HTTP 200; completed CACHE_OK; only top-level option removed", flush=True)
                finally:
                    import signal
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=10)
    finally:
        recorder.shutdown()
        recorder.server_close()
    print("PASS: live streaming Responses through real Pig listeners and recorded upstream wire bodies", flush=True)
    print("Buffered path is covered by synthetic HTTP tests: this upstream requires stream=true.", flush=True)


if __name__ == "__main__":
    main()
