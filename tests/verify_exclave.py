#!/usr/bin/env python3
"""Verify the clipboard backup and real Exclave-core -> sing-box interoperability.

Use the core commit pinned by Exclave 0.17.68 (2fc8bc67ba7930e83a7873ee30d0ffc2fdb102a4)
and Kryo 5.7.1. No Android installation, public listener or production keys are used.
"""
import argparse
import contextlib
import http.client
import http.server
import json
from pathlib import Path
import socket
import socketserver
import ssl
import struct
import tempfile
import threading

import verify as v

v.SCRIPT = Path(__file__).resolve().parents[1] / 'snell-reality-native.sh'


class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        query, sock = self.request
        # One A answer, using a compressed reference to the question's name.
        response = query[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + query[12:]
        response += b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x7f\x00\x00\x2a'
        sock.sendto(response, self.client_address)


def start_service(stack, service):
    threading.Thread(target=service.serve_forever, daemon=True).start()
    stack.callback(service.server_close)
    stack.callback(service.shutdown)
    return service


def fetch(socks, destination):
    with v.socks_connect(socks, destination) as sock:
        sock.sendall(b'GET /payload HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
        response = http.client.HTTPResponse(sock)
        response.begin()
        assert response.status == 200
        assert response.read() == v.BODY


def main():
    parser = argparse.ArgumentParser()
    for flag in ['--sing-box', '--exclave-core', '--kryo-jar']:
        parser.add_argument(flag, required=True, type=lambda p: str(Path(p).resolve()))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='snell-exclave-test-') as folder:
        root = Path(folder)
        processes = v.Processes(root)
        with contextlib.ExitStack() as stack:
            stack.callback(processes.close)
            ports = set()
            while len(ports) < 6:
                ports.add(v.free_port())
            reality, snell, socks, decoy, dns_in, bad_port = ports
            work, config = root / 'work', root / 'config'
            (work / 'bin').mkdir(parents=True)
            (work / 'bin/sing-box').symlink_to(args.sing_box)
            v.bash_function('WORK_DIR=$1; SERVER=127.0.0.1; SNI=www.cloudflare.com; LISTEN=127.0.0.1; '
                            'PORT=$2; SNELL_PORT=$3; SOCKS_PORT=$4; make_state',
                            work, reality, snell, socks)
            v.bash_function('render_configs "$1" "$2"', work / 'state.json', config)
            state = json.loads((work / 'state.json').read_text())
            backup = config / 'clients/exclave-import.txt'
            exported = config / 'clients/client-exclave.json'
            decoded = root / 'decoded.json'
            result = v.run('java', '--class-path', args.kryo_jar,
                           str(Path(__file__).with_name('ExclaveBackupCheck.java')),
                           str(backup), str(exported), str(decoded))
            print(result.stdout.strip())
            for file in [backup, exported]:
                assert file.stat().st_mode & 0o077 == 0
            client = json.loads(decoded.read_text())
            assert state['private_key'] not in decoded.read_text()
            assert client['outbounds'][0]['settings']['mode'] == 'unsafe-raw'
            assert client['outbounds'][0]['proxySettings']['tag'] == 'reality-out'
            assert client['outbounds'][1]['settings']['vnext'][0]['address'] == state['server']
            assert client['outbounds'][1]['streamSettings']['realitySettings']['publicKey'] == state['public_key']
            v.run(args.exclave_core, 'test', '-c', str(decoded))
            print('PASS Exclave configuration validation, complete chain and private-key isolation')
            # Exercise JSON escaping and longer Kryo string lengths with real Java decoding.
            escaped_state = {**state, 'server': '2001:db8::1', 'psk': '例子/+?=\\"' + 'x' * 220}
            (root / 'escaped-state.json').write_text(json.dumps(escaped_state))
            v.bash_function('render_exclave_export "$1" "$2"', root / 'escaped-state.json', root / 'escaped')
            v.run('java', '--class-path', args.kryo_jar, str(Path(__file__).with_name('ExclaveBackupCheck.java')),
                  str(root / 'escaped/exclave-import.txt'), str(root / 'escaped/client-exclave.json'), str(root / 'escaped-decoded.json'))
            assert json.loads((root / 'escaped-decoded.json').read_text())['outbounds'][0]['settings']['psk'] == escaped_state['psk']
            print('PASS IPv6 and credential escaping in offline backup')
            server = json.loads((config / 'server.json').read_text())
            server['log']['level'] = 'debug'
            server['inbounds'][0]['tls']['reality']['handshake'] = {'server': '127.0.0.1', 'server_port': decoy}
            (config / 'server.json').write_text(json.dumps(server))
            v.run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                  '-subj', '/CN=www.cloudflare.com', '-addext', 'subjectAltName=DNS:www.cloudflare.com',
                  '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem'))
            cover = v.CoverServer(('127.0.0.1', decoy), v.CoverHandler)
            cover.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            cover.context.minimum_version = ssl.TLSVersion.TLSv1_3
            cover.context.set_alpn_protocols(['h2', 'http/1.1'])
            cover.context.set_ecdh_curve('X25519')
            cover.context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
            start_service(stack, cover)
            http_service = start_service(stack, http.server.ThreadingHTTPServer(('127.0.0.1', 0), v.Handler))
            udp = start_service(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), v.EchoHandler))
            dns = start_service(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), DNSHandler))
            # The Android app adds its VPN/IPC inbounds. Use loopback SOCKS and DNS
            # inbounds here to exercise the identical exported outbound/routing config.
            client['inbounds'] = [
                {'tag': 'test-in', 'listen': '127.0.0.1', 'port': socks, 'protocol': 'socks',
                 'settings': {'auth': 'noauth', 'udp': True, 'ip': '127.0.0.1'}},
                {'tag': 'dns-in', 'listen': '127.0.0.1', 'port': dns_in, 'protocol': 'dokodemo-door',
                 'settings': {'address': '127.0.0.1', 'port': 53, 'network': 'udp'}}]
            client['log']['loglevel'] = 'debug'
            client['dns']['servers'] = [{'address': '127.0.0.1', 'port': dns.server_address[1]}]
            client['outbounds'][2]['settings'].update(address='127.0.0.1', port=dns.server_address[1])
            (root / 'client.json').write_text(json.dumps(client))
            processes.start('native-server', [args.sing_box, 'run', '-c', config / 'server.json'], reality)
            processes.start('exclave-client', [args.exclave_core, 'run', '-c', root / 'client.json'], socks)
            fetch(socks, http_service.server_address[1])
            fetch(socks, http_service.server_address[1])
            print(f'PASS Exclave-core -> sing-box REALITY -> Snell v6: {len(v.BODY)} TCP bytes and reuse')
            v.check_udp(socks, udp.server_address[1])
            print('PASS Exclave Snell UDP-over-TCP: 32 / 1200 / 4096-byte datagrams')
            query = b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x04test\x07invalid\x00\x00\x01\x00\x01'
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(5)
                sock.sendto(query, ('127.0.0.1', dns_in))
                answer = sock.recv(4096)
                assert answer[:2] == query[:2] and struct.unpack('!H', answer[6:8])[0] == 1
                assert answer[-4:] == b'\x7f\x00\x00\x2a'
            print('PASS Android DNS inbound routing through the Snell/REALITY chain')
            client['inbounds'] = [client['inbounds'][0]]
            client['inbounds'][0]['port'] = bad_port
            sid = state['short_id']
            client['outbounds'][1]['streamSettings']['realitySettings']['shortId'] = ('0' if sid[0] != '0' else '1') + sid[1:]
            (root / 'bad.json').write_text(json.dumps(client))
            processes.start('bad-exclave-client', [args.exclave_core, 'run', '-c', root / 'bad.json'], bad_port)
            try:
                fetch(bad_port, http_service.server_address[1])
            except (OSError, ValueError, http.client.HTTPException):
                print('PASS wrong REALITY short ID cannot reach the backend')
            else:
                raise AssertionError('invalid REALITY credentials accepted')
    print('ALL EXCLAVE CHECKS PASSED')


if __name__ == '__main__':
    main()
