#!/usr/bin/env python3
import http.server
import socketserver
import socket
import os

PORT = 8000
MONITOR_SOCKET = '/tmp/qemu-monitor.sock'
AUTO_PERSIST_FILE = '/tmp/auto_persist'

class PersistHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/persist':
            with open(AUTO_PERSIST_FILE, 'w') as f:
                f.write('1')
            
            try:
                if os.path.exists(MONITOR_SOCKET):
                    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    s.connect(MONITOR_SOCKET)
                    s.sendall(b'system_powerdown\\n')
                    s.close()
                    msg = "Success: ACPI shutdown command sent to QEMU. VM is shutting down and will auto-persist changes."
                else:
                    msg = "Error: QEMU monitor socket not found."
            except Exception as e:
                msg = f"Error sending QEMU command: {e}"
            
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            html = f"""
            <html>
            <head><title>Persist Command</title></head>
            <body style="font-family: Arial, sans-serif; text-align: center; padding-top: 50px; background-color: #121212; color: #ffffff;">
                <h2>{msg}</h2>
                <p>The host is compressing the disk image in the background. The machine will shut down when finished.</p>
            </body>
            </html>
            """
            self.wfile.write(html.encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

def run():
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), PersistHandler) as httpd:
        print("Persist server running on port", PORT)
        httpd.serve_forever()

if __name__ == '__main__':
    run()
