#!/usr/bin/env python3
"""Real-process smoke tests; all listeners use loopback and all files are temporary.

Usage: python3 tests/verify.py --snell /path/snell-server --xray /path/xray
                             --sing-box /path/sing-box
No root, systemd mutations, public listeners or live credentials are needed.
"""
import argparse
import contextlib
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time

SCRIPT = Path(__file__).resolve().parents[1] / 'snell-reality.sh'
BODY = (b'Snell v6 unsafe-raw over REALITY: actual application data.\n' * 19000)


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(str(args[:2]) + '\n' + result.stdout + result.stderr)
    return result


def bash_function(code, *args, check=True):
    return subprocess.run(['bash', '-c', 'source "$1"; shift; ' + code, 'test', str(SCRIPT), *map(str, args)],
                          check=check, text=True, capture_output=True)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def read_exact(sock, size):
    data = b''
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise OSError('unexpected EOF')
        data += part
    return data


def socks_connect(port, target):
    sock = socket.create_connection(('127.0.0.1', port), timeout=5)
    sock.sendall(b'\x05\x01\x00')
    assert read_exact(sock, 2) == b'\x05\x00'
    sock.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', target))
    header = read_exact(sock, 4)
    if header[1] != 0:
        sock.close()
        raise OSError(f'SOCKS rejected request: {header[1]}')
    length = {1: 4, 4: 16}.get(header[3])
    if length is None:
        length = read_exact(sock, 1)[0]
    read_exact(sock, length + 2)
    return sock


def fetch(port, target):
    with socks_connect(port, target) as sock:
        sock.sendall(b'GET /payload HTTP/1.0\r\nHost: localhost\r\n\r\n')
        response = b''
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            response += chunk
    headers, body = response.split(b'\r\n\r\n', 1)
    assert b'200 OK' in headers
    assert body == BODY, (len(body), len(BODY))
    return hashlib.sha256(body).hexdigest()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *_args):
        pass


class CoverServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


class CoverHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        try:
            with self.server.context.wrap_socket(self.request, server_side=True) as tls:
                request = tls.recv(8192)
                if request.startswith(b'PRI * HTTP/2.0'):
                    # An empty HTTP/2 SETTINGS frame is sufficient for the cover probe.
                    tls.sendall(b'\x00\x00\x00\x04\x00\x00\x00\x00\x00')
                elif request:
                    tls.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
        except (OSError, ssl.SSLError):
            pass


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)


def check_udp(socks_port, destination_port):
    with socket.create_connection(('127.0.0.1', socks_port), timeout=5) as control:
        control.sendall(b'\x05\x01\x00')
        assert read_exact(control, 2) == b'\x05\x00'
        control.sendall(b'\x05\x03\x00\x01' + b'\x00' * 6)
        header = read_exact(control, 4)
        assert header == b'\x05\x00\x00\x01', header
        host = socket.inet_ntoa(read_exact(control, 4))
        relay_port = struct.unpack('!H', read_exact(control, 2))[0]
        if host == '0.0.0.0':
            host = '127.0.0.1'
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.settimeout(5)
            for length in [32, 1200, 4096]:
                payload = os.urandom(length)
                packet = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', destination_port) + payload
                udp.sendto(packet, (host, relay_port))
                answer, _ = udp.recvfrom(65535)
                assert answer[:4] == b'\x00\x00\x00\x01'
                assert answer[10:] == payload


class Processes:
    def __init__(self, root):
        self.root, self.items = root, []

    def start(self, name, command, port):
        log = (self.root / (name + '.log')).open('w+')
        process = subprocess.Popen(list(map(str, command)), stdout=log, stderr=log)
        self.items.append((process, log))
        for _ in range(100):
            if process.poll() is not None:
                log.seek(0)
                raise RuntimeError(name + ' failed: ' + log.read())
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    return
            except OSError:
                time.sleep(.05)
        raise RuntimeError(name + ' did not listen')

    def close(self):
        for process, _ in reversed(self.items):
            process.terminate()
        for process, log in reversed(self.items):
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if sys.exc_info()[0] is not None:
                log.seek(0)
                print(Path(log.name).name + ':\n' + log.read()[-8000:], file=sys.stderr)
            log.close()


def validate_inputs():
    code = 'SERVER=$1; SNI=$2; PORT=$3; SNELL_PORT=23456; CLIENT_PORT=23456; SOCKS_PORT=1080; LISTEN=$4; validate_options'
    for server, sni, port, listen in [
        ('203.0.113.10', 'www.microsoft.com', '443', '0.0.0.0'),
        ('2001:db8::1', 'www.microsoft.com', '443', '::'),
        ('proxy.example.com', 'www.microsoft.com', '8443', '0.0.0.0'),
    ]:
        bash_function(code, server, sni, port, listen)
    for server, sni, port, listen in [
        ('127.0.0.1', 'www.microsoft.com', '443', '0.0.0.0'),
        ('0.0.0.0', 'www.microsoft.com', '443', '0.0.0.0'),
        ('a.example\nmode=default', 'www.microsoft.com', '443', '0.0.0.0'),
        ('$(touch /tmp/should-not-exist)', 'www.microsoft.com', '443', '0.0.0.0'),
        ('example.com', 'example.com', '443', '0.0.0.0'),
        ('203.0.113.10', 'https://www.microsoft.com', '443', '0.0.0.0'),
        ('203.0.113.10', 'www.microsoft.com', '23456', '0.0.0.0'),
        ('203.0.113.10', 'www.microsoft.com', '65536', '0.0.0.0'),
        ('203.0.113.10', 'www.microsoft.com', '0443', '0.0.0.0'),
        ('203.0.113.10', 'www.microsoft.com', '443', 'bad-listener'),
    ]:
        result = bash_function(code, server, sni, port, listen, check=False)
        assert result.returncode != 0, (server, sni, port, listen)
    print('PASS input validation: IPv4, IPv6, domains, injection, invalid ports and self-forwarding')


def main():
    parser = argparse.ArgumentParser()
    for name in ['snell', 'xray', 'sing-box']:
        parser.add_argument('--' + name, required=True, type=lambda p: str(Path(p).resolve()))
    args = parser.parse_args()
    run('bash', '-n', str(SCRIPT))
    validate_inputs()
    with tempfile.TemporaryDirectory(prefix='snell-reality-test-') as directory:
        root = Path(directory)
        processes = Processes(root)
        with contextlib.ExitStack() as stack:
            stack.callback(processes.close)
            ports = []
            while len(ports) < 7:
                p = free_port()
                if p not in ports:
                    ports.append(p)
            reality, snell, bridge, socks, decoy, bad_bridge, bad_socks = ports
            keys = run(args.xray, 'x25519').stdout.splitlines()
            private = next(x.split(': ', 1)[1] for x in keys if x.startswith('PrivateKey:'))
            public = next(x.split(': ', 1)[1] for x in keys if x.startswith(('Password (PublicKey):', 'PublicKey:')))
            state = dict(schema=1, server='127.0.0.1', sni='www.cloudflare.com', listen='127.0.0.1',
                         port=reality, snell_port=snell, client_port=bridge, socks_port=socks,
                         psk=os.urandom(16).hex(), uuid=run(args.xray, 'uuid').stdout.strip(),
                         private_key=private, public_key=public, short_id=os.urandom(8).hex(),
                         snell_version='6.0.0', xray_version='26.11.9')
            state_path = root / 'state.json'
            state_path.write_text(json.dumps(state))
            config = root / 'config'
            bash_function('render_configs "$1" "$2"', state_path, config)
            for path in config.rglob('*'):
                if path.is_file():
                    assert path.stat().st_mode & 0o077 == 0, path
            text = (config / 'snell.conf').read_text()
            assert f'listen = 127.0.0.1:{snell}' in text and 'mode = unsafe-raw' in text
            for path in (config / 'clients').iterdir():
                assert private not in path.read_text(), path
            server = json.loads((config / 'xray.json').read_text())
            assert server['outbounds'][0]['settings']['redirect'] == f'127.0.0.1:{snell}'
            assert server['inbounds'][0]['streamSettings']['security'] == 'reality'
            assert 'flow' not in server['inbounds'][0]['settings']['clients'][0]
            # Replace ONLY the cover target for the local test; no Internet TLS server is needed.
            server['inbounds'][0]['streamSettings']['realitySettings']['target'] = f'127.0.0.1:{decoy}'
            (config / 'xray.json').write_text(json.dumps(server))
            bash_function('check_xray_configs "$1" "$2"', args.xray, config)
            run(args.sing_box, 'check', '-c', str(config / 'clients/sing-box-via-bridge.json'))
            print('PASS generated configurations: real Xray and sing-box validators, private-key isolation and file modes')
            run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=www.cloudflare.com', '-addext', 'subjectAltName=DNS:www.cloudflare.com',
                '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem'))
            cover = CoverServer(('127.0.0.1', decoy), CoverHandler)
            cover.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            cover.context.minimum_version = ssl.TLSVersion.TLSv1_3
            cover.context.set_alpn_protocols(['h2', 'http/1.1'])
            cover.context.set_ecdh_curve('X25519')
            cover.context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
            threading.Thread(target=cover.serve_forever, daemon=True).start()
            stack.callback(cover.server_close)
            stack.callback(cover.shutdown)
            http_service = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=http_service.serve_forever, daemon=True)
            thread.start()
            stack.callback(http_service.server_close)
            stack.callback(http_service.shutdown)
            http_port = http_service.server_address[1]
            processes.start('snell', [args.snell, '-c', config / 'snell.conf'], snell)
            processes.start('reality-server', [args.xray, 'run', '-c', config / 'xray.json'], reality)
            processes.start('xray-bridge', [args.xray, 'run', '-c', config / 'clients/xray-bridge.json'], bridge)
            processes.start('singbox', [args.sing_box, 'run', '-c', config / 'clients/sing-box-via-bridge.json'], socks)
            digest = fetch(socks, http_port)
            fetch(socks, http_port)  # reuse another connection
            print(f'PASS real Snell -> Xray bridge -> VLESS/REALITY -> official Snell: {len(BODY)} bytes, sha256={digest[:16]}...')
            udp_service = socketserver.ThreadingUDPServer(('127.0.0.1', 0), EchoHandler)
            udp_service.daemon_threads = True
            threading.Thread(target=udp_service.serve_forever, daemon=True).start()
            stack.callback(udp_service.server_close)
            stack.callback(udp_service.shutdown)
            check_udp(socks, udp_service.server_address[1])
            print('PASS UDP-over-TCP through the same REALITY tunnel: 32 / 1200 / 4096-byte datagrams')
            # Invalid REALITY short ID must not reach the Snell backend.
            bad = json.loads((config / 'clients/xray-bridge.json').read_text())
            bad['inbounds'][0]['port'] = bad_bridge
            original = state['short_id']
            bad['outbounds'][0]['streamSettings']['realitySettings']['shortId'] = ('0' if original[0] != '0' else '1') + original[1:]
            bad_path = root / 'bad-client.json'
            bad_path.write_text(json.dumps(bad))
            processes.start('bad-bridge', [args.xray, 'run', '-c', bad_path], bad_bridge)
            bad_snell = json.loads((config / 'clients/sing-box-via-bridge.json').read_text())
            bad_snell['inbounds'][0]['listen_port'] = bad_socks
            bad_snell['outbounds'][0]['server_port'] = bad_bridge
            bad_snell_path = root / 'bad-snell-client.json'
            bad_snell_path.write_text(json.dumps(bad_snell))
            processes.start('bad-snell', [args.sing_box, 'run', '-c', bad_snell_path], bad_socks)
            try:
                fetch(bad_socks, http_port)
            except (OSError, ValueError):
                print('PASS wrong REALITY short ID cannot retrieve backend application data')
            else:
                raise AssertionError('invalid REALITY credentials were accepted')
            units = root / 'units'
            bash_function('BIN_DIR=$1; CONFIG_DIR=$2; SERVICE_USER=$3; write_units "$4"',
                          Path(args.xray).parent, config, os.environ.get('USER', 'agent'), units)
            for unit in units.iterdir():
                unit_text = unit.read_text()
                unit_text = unit_text.replace(str(Path(args.xray).parent / 'snell-server'), args.snell)
                unit.write_text(unit_text)
            runtime = root / 'runtime'
            runtime.mkdir(mode=0o700)
            run('systemd-analyze', '--user', 'verify', *map(str, units.iterdir()),
                env={**os.environ, 'XDG_RUNTIME_DIR': str(runtime)})
            print('PASS systemd unit syntax and executable paths (no running systemd was modified)')
    print('ALL CHECKS PASSED')


if __name__ == '__main__':
    main()
