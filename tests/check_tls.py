"""Engine CA contract through real HTTPS clients and disposable child processes, offline only."""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch


def run(check, here):
    from benji import gate, providers, tls, voice, web
    with tempfile.TemporaryDirectory(prefix='benji-trust-') as td:
        root = Path(td)
        for name in ('first', 'second'):
            subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', '/CN=fixture.example', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'subjectAltName=DNS:fixture.example',
                            '-keyout', str(root / (name + '.key')), '-out', str(root / (name + '.pem'))],
                           check=True, capture_output=True)
        file = root / 'selected.pem'
        file.write_bytes((root / 'first.pem').read_bytes().ljust(4096, b'\n'))
        with patch.dict(os.environ, {}, clear=True):
            check('TLS unset retains source defaults', tls.context() is None)
        with patch.dict(os.environ, {'BENJI_TLS_CA_FILE': str(file)}):
            old = tls.context()
            check('TLS context requires CA and hostname verification', old.verify_mode == ssl.CERT_REQUIRED and old.check_hostname)
            check('successful TLS selection is cached', tls.context() is old)
            # Atomic replacement with the same mtime and byte count must not reuse old trust.
            replacement = root / 'replacement.pem'
            replacement.write_bytes((root / 'second.pem').read_bytes().ljust(4096, b'\n'))
            before = file.stat()
            assert replacement.stat().st_size == before.st_size
            os.utime(replacement, ns=(before.st_atime_ns, before.st_mtime_ns))
            replacement.replace(file)
            check('replacing selected CA invalidates cached roots', tls.context() is not old and tls.context().get_ca_certs(binary_form=True) != old.get_ca_certs(binary_form=True))
            file.write_text('broken CA')
            try:
                tls.context(); rejected = False
            except tls.TrustError:
                rejected = True
            check('corrupting previously valid CA fails closed', rejected)
            file.write_bytes((root / 'first.pem').read_bytes().ljust(4096, b'\n'))
            check('failed selections are not cached', tls.context().get_ca_certs(binary_form=True) == old.get_ca_certs(binary_form=True))
        bad = root / 'bad.pem'; bad.write_text('not PEM')
        for selection in ('', 'relative.pem', str(root / 'missing.pem'), str(root), str(bad)):
            with patch.dict(os.environ, {'BENJI_TLS_CA_FILE': selection}):
                try:
                    tls.context(); rejected = False
                except tls.TrustError:
                    rejected = True
                check('explicit invalid CA rejected ' + repr(selection), rejected)
        # Use invalid trust so every real call must fail before opening a socket, with its public error type.
        wav = root / 'fixture.wav'; wav.write_bytes(b'offline audio fixture')
        with patch.dict(os.environ, {'BENJI_TLS_CA_FILE': str(bad)}), patch.object(socket, 'create_connection', side_effect=AssertionError('network attempted')):
            calls = [('post', lambda: providers._post('https://fixture.example/', {}, {}), providers.ProviderError),
                     ('post retry', lambda: providers._post('https://fixture.example/', {}, {}, retry=True), providers.ProviderError),
                     ('stream', lambda: providers._stream('https://fixture.example/', {}, {}, lambda *a: None, lambda d: None, lambda: False, None), providers.ProviderError),
                     ('stream retry', lambda: providers._stream('https://fixture.example/', {}, {}, lambda *a: None, lambda d: None, lambda: False, None, retry=True), providers.ProviderError),
                     ('OpenAI voice', lambda: voice._transcribe_openai(str(wav), 'local-fixture'), voice.VoiceError),
                     ('Deepgram voice', lambda: voice._transcribe_deepgram(str(wav), 'local-fixture'), voice.VoiceError),
                     ('web', lambda: web._get('https://fixture.example/'), web.WebError)]
            for name, call, error_type in calls:
                try:
                    call(); mapped = False
                except error_type as error:
                    mapped = 'BENJI_TLS_CA_FILE' in str(error)
                check('invalid CA uses caller error ' + name, mapped)
        with patch.dict(os.environ, {'BENJI_TLS_CA_FILE': str(file)}, clear=True):
            child = subprocess.check_output(['/usr/bin/env'], env=gate.tool_env(), text=True)
            check('child environment excludes engine CA and no SSL trust is injected', all(n + '=' not in child for n in ('BENJI_TLS_CA_FILE', 'SSL_CERT_FILE', 'SSL_CERT_DIR')))
        with patch.dict(os.environ, {'BENJI_TLS_CA_FILE': str(file), 'SSL_CERT_FILE': '/explicit/tool.pem', 'SSL_CERT_DIR': '/explicit/tool-roots'}, clear=True):
            child = subprocess.check_output(['/usr/bin/env'], env=gate.tool_env(), text=True)
            check('explicit child tool trust is preserved', 'SSL_CERT_FILE=/explicit/tool.pem' in child and 'SSL_CERT_DIR=/explicit/tool-roots' in child and 'BENJI_TLS_CA_FILE=' not in child)

        seen, names, connections = [], [], []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                seen.append(self.headers['Host'])
                body = b'<p>fixture verified</p>'
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_ctx.load_cert_chain(root / 'first.pem', root / 'first.key')
        server_ctx.set_servername_callback(lambda sock, name, ctx: names.append(name))
        server.socket = server_ctx.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        real_socket = socket.socket
        class RoutedSocket(real_socket):
            def connect(self, address):
                connections.append(address)
                return super().connect(('127.0.0.1', server.server_port))
        def resolve(host, port, *args, **kwargs):
            return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, '', ('8.8.8.8', port))]
        try:
            with patch.dict(os.environ, {'BENJI_TLS_CA_FILE': str(file), 'HTTPS_PROXY': 'http://invalid.proxy:1'}), patch.object(socket, 'socket', RoutedSocket), patch.object(socket, 'getaddrinfo', resolve):
                # Real DNS-pinned HTTPS handler, socket and SNI. Only address routing is local.
                check('DNS-pinned web transport uses explicit CA', web.fetch_text(f'https://fixture.example:{server.server_port}/') == 'fixture verified')
                try:
                    web.fetch_text(f'https://wrong.example:{server.server_port}/'); rejected = False
                except web.WebError:
                    rejected = True
                check('combined pinned transport rejects wrong TLS hostname before HTTP', rejected and len(seen) == 1)
                check('combined transport preserves DNS-pinned address SNI Host and ignores proxy', all(c == ('8.8.8.8', server.server_port) for c in connections) and names == ['fixture.example', 'wrong.example'] and seen == [f'fixture.example:{server.server_port}'])
        finally:
            server.shutdown(); server.server_close(); thread.join(5)
