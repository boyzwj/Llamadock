#!/usr/bin/env python3

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PAYLOAD = b"GGUF-llamadock-range-smoke-payload"


class RangeFixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path not in {
            "/model.gguf",
            "/no-range.gguf",
            "/bad-range.gguf",
        }:
            self.send_error(404)
            return

        range_header = self.headers.get("Range")
        start = 0
        status = 200
        if range_header and self.path != "/no-range.gguf":
            prefix = "bytes="
            if not range_header.startswith(prefix):
                self.send_error(416)
                return
            value = range_header[len(prefix):].split("-", 1)[0]
            try:
                start = int(value)
            except ValueError:
                self.send_error(416)
                return
            if start < 0 or start >= len(PAYLOAD):
                self.send_error(416)
                return
            status = 206

        body = PAYLOAD[start:]
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", '"llamadock-range-fixture"')
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            content_range_start = start
            if self.path == "/bad-range.gguf":
                content_range_start += 1
            self.send_header(
                "Content-Range",
                (
                    f"bytes {content_range_start}-"
                    f"{len(PAYLOAD) - 1}/{len(PAYLOAD)}"
                ),
            )
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def log_message(self, format, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18081)
    arguments = parser.parse_args()
    server = ThreadingHTTPServer(
        ("127.0.0.1", arguments.port),
        RangeFixtureHandler,
    )
    print(
        f"range fixture listening on 127.0.0.1:{arguments.port}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
