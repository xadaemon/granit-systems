import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse


class ParameterHandler(BaseHTTPRequestHandler):
    last_params = {}

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)

        if params != ParameterHandler.last_params:
            print("Parameters changed:", params)
            ParameterHandler.last_params = params

        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass  # Suppress default request logging

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: python server.py <port>")
        sys.exit(1)

    port = int(sys.argv[1])
    server = HTTPServer(('', port), ParameterHandler)
    print(f"Server listening on port {port}")
    server.serve_forever()
