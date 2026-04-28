from __future__ import annotations

import argparse
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


class HardenedHTTPServer(ThreadingHTTPServer):
    request_queue_size = 64
    daemon_threads = True
    allow_reuse_address = True


class StaticSpaHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    root = Path('.')

    def do_GET(self) -> None:
        self._serve(send_body=True)

    def do_HEAD(self) -> None:
        self._serve(send_body=False)

    def _serve(self, send_body: bool) -> None:
        target = self._resolve_path()
        if target is None or not target.is_file():
            self.send_error(404, 'Not Found')
            return

        ctype = mimetypes.guess_type(str(target))[0] or 'application/octet-stream'
        data = target.read_bytes()

        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-cache' if target.name == 'index.html' else 'public, max-age=300')
        self.end_headers()

        if send_body:
            self.wfile.write(data)

    def _resolve_path(self) -> Path | None:
        raw_path = unquote(urlparse(self.path).path)
        relative = raw_path.lstrip('/') or 'index.html'
        normalized = Path(relative)

        try:
            candidate = (self.root / normalized).resolve()
            candidate.relative_to(self.root)
        except Exception:
            return None

        if candidate.is_dir():
            index_candidate = candidate / 'index.html'
            if index_candidate.is_file():
                return index_candidate

        if candidate.is_file():
            return candidate

        spa_fallback = (self.root / 'index.html').resolve()
        try:
            spa_fallback.relative_to(self.root)
        except Exception:
            return None
        return spa_fallback if spa_fallback.is_file() else None

    def log_message(self, format: str, *args) -> None:
        print('%s - - [%s] %s' % (self.address_string(), self.log_date_time_string(), format % args))


def main() -> None:
    parser = argparse.ArgumentParser(description='Lightweight static SPA server')
    parser.add_argument('--root', required=True, help='Directory to serve')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    parser.add_argument('--host', default='0.0.0.0', help='Host to bind to')
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        raise SystemExit(f'Root directory not found: {root}')

    StaticSpaHandler.root = root
    server = HardenedHTTPServer((args.host, args.port), StaticSpaHandler)
    print(f'Serving {root} on http://{args.host}:{args.port}')
    server.serve_forever()


if __name__ == '__main__':
    main()
