#!/usr/bin/env python3
import hmac
import http.server
import os
import socket
import socketserver

PORT = int(os.environ.get("PERSIST_PORT", "8000"))
BIND_ADDRESS = os.environ.get("PERSIST_BIND_ADDRESS", "192.168.254.1")
TOKEN = os.environ.get("PERSIST_TOKEN", "")
MONITOR_SOCKET = "/tmp/qemu-monitor.sock"
AUTO_PERSIST_FILE = "/tmp/auto_persist"


class PersistHandler(http.server.BaseHTTPRequestHandler):
    server_version = "XP-Persist/1.0"

    def send_text(self, status, message):
        body = (message + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_text(200, "ok")
        else:
            self.send_text(405, "Use POST /persist with an Authorization: Bearer header.")

    def do_POST(self):
        if self.path != "/persist":
            self.send_text(404, "not found")
            return

        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {TOKEN}"
        if not TOKEN or not hmac.compare_digest(supplied, expected):
            self.send_text(403, "invalid persist token")
            return

        if not os.path.exists(MONITOR_SOCKET):
            self.send_text(503, "QEMU monitor socket is not available")
            return

        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
                monitor.settimeout(3)
                monitor.connect(MONITOR_SOCKET)
                monitor.sendall(b"system_powerdown\n")

            marker_tmp = AUTO_PERSIST_FILE + ".tmp"
            with open(marker_tmp, "w", encoding="ascii") as marker:
                marker.write("1\n")
                marker.flush()
                os.fsync(marker.fileno())
            os.replace(marker_tmp, AUTO_PERSIST_FILE)
        except OSError as exc:
            self.send_text(503, f"failed to request shutdown: {exc}")
            return

        self.send_text(202, "shutdown requested; the host will persist and power off")

    def log_message(self, message_format, *args):
        print(f"{self.client_address[0]} - {message_format % args}", flush=True)


class PersistServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def run():
    if not TOKEN:
        raise SystemExit("PERSIST_TOKEN must be set")
    with PersistServer((BIND_ADDRESS, PORT), PersistHandler) as server:
        print(f"Persist server listening on {BIND_ADDRESS}:{PORT}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    run()
