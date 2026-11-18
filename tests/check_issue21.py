"""Issue 21 fetch regressions, with real HTTP/TLS sockets routed to disposable local servers.

Only DNS and the destination routing are replaced. No public requests are made.
"""
from __future__ import annotations

import contextlib
import io
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from benji import gate, web


class FetchTests(unittest.TestCase):
    @contextlib.contextmanager
    def server(self, *, tls=False, ipv6=False):
        seen, names = [], []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                seen.append((self.path, self.headers.get('Host')))
                body = b'<p>local fixture</p>'
                self.send_response(302 if self.path == '/redirect' else 200)
                if self.path == '/redirect':
                    self.send_header('Location', f'http://next.example:{self.server.server_port}/final')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        class Server(ThreadingHTTPServer):
            address_family = socket.AF_INET6 if ipv6 else socket.AF_INET
            daemon_threads = True
        with tempfile.TemporaryDirectory() as td:
            srv = Server(('::1' if ipv6 else '127.0.0.1', 0), Handler)
            ctx = None
            if tls:
                root = Path(td)
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                                '-keyout', str(root / 'fixture.key'), '-out', str(root / 'fixture.crt'),
                                '-subj', '/CN=fixture.example', '-addext', 'subjectAltName=DNS:fixture.example'],
                               check=True, capture_output=True)
                server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                server_ctx.load_cert_chain(root / 'fixture.crt', root / 'fixture.key')
                server_ctx.set_servername_callback(lambda sock, name, context: names.append(name))
                srv.socket = server_ctx.wrap_socket(srv.socket, server_side=True)
                ctx = ssl.create_default_context(cafile=str(root / 'fixture.crt'))
            thread = threading.Thread(target=srv.serve_forever, daemon=True)
            thread.start()
            try:
                yield srv.server_port, seen, names, ctx
            finally:
                srv.shutdown()
                srv.server_close()
                thread.join(5)

    @contextlib.contextmanager
    def network(self, port, answers, *, ipv6=False, fail_first=False, unsupported_ipv6=False):
        resolutions, connections = [], []
        real_socket = socket.socket
        def resolve(host, requested_port, *args, **kwargs):
            resolutions.append(host)
            ips = answers(host, resolutions.count(host))
            return [(socket.AF_INET6 if ':' in ip else socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP,
                     '', (ip, requested_port or port, 0, 0) if ':' in ip else (ip, requested_port or port)) for ip in ips]
        class RoutedSocket(real_socket):
            def __init__(self, family=socket.AF_INET, *args, **kwargs):
                if unsupported_ipv6 and family == socket.AF_INET6:
                    raise OSError("fixture IPv6 unavailable")
                super().__init__(family, *args, **kwargs)
            def connect(self, address):
                connections.append(address)
                if fail_first and len(connections) == 1:
                    raise OSError('fixture first address unavailable')
                destination = ('::1', port, 0, 0) if self.family == socket.AF_INET6 else ('127.0.0.1', port)
                return super().connect(destination)
        # The old gate binds its resolver as a default argument, so route that seam too.
        def refusal(host, resolve=None):
            return gate.host_refusal(host, resolve=resolve or socket.getaddrinfo)
        with patch.object(socket, 'getaddrinfo', resolve), patch.object(socket, 'socket', RoutedSocket), \
             patch.object(web, 'host_refusal', refusal), patch('urllib.request.proxy_bypass', return_value=True):
            yield resolutions, connections

    def test_rebinding_never_connects_to_the_second_private_answer(self):
        with self.server() as (port, seen, _, _), self.network(port, lambda h,n: ['8.8.8.8'] if n == 1 else ['127.0.0.1']) as (dns, connections):
            self.assertEqual(web.fetch_text(f'http://fixture.example:{port}/read'), 'local fixture')
            self.assertEqual([c[0] for c in connections], ['8.8.8.8'])
            self.assertEqual(dns, ['fixture.example'])
            self.assertEqual(seen, [('/read', f'fixture.example:{port}')])

    def test_redirect_resolves_and_pins_each_hop(self):
        with self.server() as (port, seen, _, _), self.network(port, lambda h,n: ['8.8.8.8'] if n == 1 else ['127.0.0.1']) as (dns, connections):
            self.assertEqual(web.fetch_text(f'http://fixture.example:{port}/redirect'), 'local fixture')
            self.assertEqual(dns, ['fixture.example', 'next.example'])
            self.assertEqual([c[0] for c in connections], ['8.8.8.8', '8.8.8.8'])
            self.assertEqual(seen[-1], ('/final', f'next.example:{port}'))

    def test_private_or_mixed_answers_send_no_request(self):
        with self.server() as (port, seen, _, _):
            for ips in [['127.0.0.1'], ['8.8.8.8', '::1'], ['::ffff:127.0.0.1']]:
                with self.subTest(ips=ips), self.network(port, lambda h,n: ips) as (_, connections):
                    with self.assertRaises(web.WebError):
                        web.fetch_text(f'http://fixture.example:{port}/read')
                    self.assertEqual(connections, [])
            self.assertEqual(seen, [])

    def test_redirect_to_private_answer_is_refused_before_connection(self):
        with self.server() as (port, seen, _, _), self.network(port, lambda h,n: ['127.0.0.1'] if h == 'next.example' else ['8.8.8.8']) as (_, connections):
            with self.assertRaises(web.WebError):
                web.fetch_text(f'http://fixture.example:{port}/redirect')
            self.assertEqual([c[0] for c in connections], ['8.8.8.8'])
            self.assertEqual(len(seen), 1)

    def test_https_preserves_sni_host_and_certificate_validation(self):
        with self.server(tls=True) as (port, seen, names, ctx), \
             patch('ssl._create_default_https_context', return_value=ctx), \
             patch.object(next(h for h in web._OPENER.handlers if isinstance(h, urllib.request.HTTPSHandler)), '_context', ctx), \
             self.network(port, lambda h,n: ['8.8.8.8']) as (_, connections):
            self.assertEqual(web.fetch_text(f'https://fixture.example:{port}/read'), 'local fixture')
            self.assertEqual(names, ['fixture.example'])
            self.assertEqual(seen, [('/read', f'fixture.example:{port}')])
            with self.assertRaises(web.WebError):
                web.fetch_text(f'https://wrong.example:{port}/read')
            self.assertEqual(names[-1], 'wrong.example')
            self.assertEqual(len(seen), 1, 'a wrong certificate sends no HTTP request')
            self.assertTrue(all(c[0] == '8.8.8.8' for c in connections))

    def test_ipv6_connection_and_ipv6_to_ipv4_fallback(self):
        with self.server(ipv6=True) as (port, seen, _, _), self.network(port, lambda h,n: ['2606:4700:4700::1111']) as (_, connections):
            self.assertEqual(web.fetch_text(f'http://fixture.example:{port}/read'), 'local fixture')
            self.assertEqual(connections, [('2606:4700:4700::1111', port, 0, 0)])
        with self.server() as (port, _, _, _), self.network(port, lambda h,n: ['2606:4700:4700::1111', '8.8.8.8'], fail_first=True) as (dns, connections):
            self.assertEqual(web.fetch_text(f'http://fixture.example:{port}/read'), 'local fixture')
            self.assertEqual([c[0] for c in connections], ['2606:4700:4700::1111', '8.8.8.8'])
            self.assertEqual(dns, ['fixture.example'])
        with self.server() as (port, _, _, _), self.network(port, lambda h,n: ['2606:4700:4700::1111', '8.8.8.8'], unsupported_ipv6=True) as (_, connections):
            self.assertEqual(web.fetch_text(f'http://fixture.example:{port}/read'), 'local fixture')
            self.assertEqual([c[0] for c in connections], ['8.8.8.8'])


def run(check, here=None):
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(FetchTests))
    print(stream.getvalue())
    check(f'issue 21 fetch regressions: {result.testsRun} tests', result.wasSuccessful())


if __name__ == '__main__':
    unittest.main(verbosity=2)
