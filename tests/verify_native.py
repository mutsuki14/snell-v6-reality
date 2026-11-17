#!/usr/bin/env python3
"""Test generated native configurations with two real sing-box processes only."""
import argparse
import contextlib
import http.server
import json
import os
from pathlib import Path
import socketserver
import ssl
import tempfile
import threading
import urllib.parse

import verify as v

v.SCRIPT = Path(__file__).resolve().parents[1] / 'snell-reality-native.sh'


def test_import_link():
    url = 'https://example.invalid/private/profile.json?token=a%2Bb&format=json'
    result = v.run('bash', str(v.SCRIPT), 'import-link', '--url', url).stdout.strip()
    parsed = urllib.parse.urlsplit(result)
    assert parsed.scheme == 'sing-box' and parsed.netloc == 'import-remote-profile'
    assert urllib.parse.parse_qs(parsed.query)['url'] == [url]
    assert parsed.fragment == 'Snell-REALITY'
    for bad in ['http://example.com/a', 'https://user:pass@example.com/a', 'https://example.com/a#secret',
                'https://example.com/a\nb', 'javascript:alert(1)', 'https://example.com:bad/a']:
        result = v.bash_function('make_import_link "$1"', bad, check=False)
        assert result.returncode != 0, bad
    print('PASS official remote-profile URI syntax, URL escaping and rejection of malformed URLs')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sing-box', required=True, type=lambda p: str(Path(p).resolve()))
    args = parser.parse_args()
    sb = args.sing_box
    v.run('bash', '-n', str(v.SCRIPT))
    v.validate_inputs()
    test_import_link()
    with tempfile.TemporaryDirectory(prefix='snell-native-test-') as folder:
        root = Path(folder)
        processes = v.Processes(root)
        with contextlib.ExitStack() as stack:
            stack.callback(processes.close)
            ports = []
            while len(ports) < 6:
                port = v.free_port()
                if port not in ports:
                    ports.append(port)
            reality, snell, socks, decoy, bad_port, bypass_port = ports
            # Use the same real key/state generation function as the installer.
            work = root / 'work'
            (work / 'bin').mkdir(parents=True)
            (work / 'bin/sing-box').symlink_to(sb)
            v.bash_function('WORK_DIR=$1; SERVER=127.0.0.1; SNI=www.cloudflare.com; LISTEN=127.0.0.1; '
                            'PORT=$2; SNELL_PORT=$3; SOCKS_PORT=$4; make_state',
                            work, reality, snell, socks)
            state = json.loads((work / 'state.json').read_text())
            config = root / 'config'
            v.bash_function('render_configs "$1" "$2"', work / 'state.json', config)
            for path in config.rglob('*.json'):
                assert path.stat().st_mode & 0o077 == 0, path
            for path in (config / 'clients').iterdir():
                assert state['private_key'] not in path.read_text()
            server = json.loads((config / 'server.json').read_text())
            assert len(server['inbounds']) == 2
            inner = server['inbounds'][1]
            assert (inner['type'], inner['version'], inner['mode'], inner['listen']) == ('snell', 6, 'unsafe-raw', '127.0.0.1')
            rules = server['route']['rules']
            assert rules[0]['override_address'] == '127.0.0.1' and rules[0]['override_port'] == snell
            assert rules[0]['network'] == 'tcp' and rules[1]['action'] == 'reject'
            mixed = json.loads((config / 'clients/client-mixed.json').read_text())
            assert mixed['outbounds'][0]['detour'] == mixed['outbounds'][1]['tag'] == 'reality-out'
            assert mixed['outbounds'][0]['mode'] == 'unsafe-raw'
            tun = json.loads((config / 'clients/client-tun.json').read_text())
            assert tun['inbounds'][0]['type'] == 'tun' and len(tun['inbounds'][0]['address']) == 2
            assert tun['dns']['servers'][1]['detour'] == 'snell-out'
            v.bash_function('check_configs "$1" "$2"', sb, config)
            print('PASS native server / mixed / TUN configuration validation, scoped forwarding and secret isolation')
            # Substitute a local cover target for a self-contained network test.
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
            threading.Thread(target=cover.serve_forever, daemon=True).start()
            stack.callback(cover.server_close)
            stack.callback(cover.shutdown)
            http_service = http.server.ThreadingHTTPServer(('127.0.0.1', 0), v.Handler)
            threading.Thread(target=http_service.serve_forever, daemon=True).start()
            stack.callback(http_service.server_close)
            stack.callback(http_service.shutdown)
            processes.start('native-server', [sb, 'run', '-c', config / 'server.json'], reality)
            processes.start('native-client', [sb, 'run', '-c', config / 'clients/client-mixed.json'], socks)
            digest = v.fetch(socks, http_service.server_address[1])
            v.fetch(socks, http_service.server_address[1])
            print(f'PASS native sing-box -> REALITY -> native Snell v6: {len(v.BODY)} TCP bytes, sha256={digest[:16]}...')
            udp = socketserver.ThreadingUDPServer(('127.0.0.1', 0), v.EchoHandler)
            udp.daemon_threads = True
            threading.Thread(target=udp.serve_forever, daemon=True).start()
            stack.callback(udp.server_close)
            stack.callback(udp.shutdown)
            v.check_udp(socks, udp.server_address[1])
            print('PASS native UDP-over-TCP: 32 / 1200 / 4096-byte datagrams')
            # Wrong REALITY credentials must not reach the backend HTTP server.
            bad = json.loads(json.dumps(mixed))
            bad['inbounds'][0]['listen_port'] = bad_port
            original = state['short_id']
            bad['outbounds'][1]['tls']['reality']['short_id'] = ('0' if original[0] != '0' else '1') + original[1:]
            (root / 'bad.json').write_text(json.dumps(bad))
            processes.start('bad-client', [sb, 'run', '-c', root / 'bad.json'], bad_port)
            try:
                v.fetch(bad_port, http_service.server_address[1])
            except (OSError, ValueError):
                print('PASS wrong REALITY short ID is rejected')
            else:
                raise AssertionError('wrong credentials reached backend')
            # A valid outer VLESS client cannot bypass the Snell protocol layer.
            bypass = json.loads(json.dumps(mixed))
            bypass['inbounds'][0]['listen_port'] = bypass_port
            bypass['route']['final'] = 'reality-out'
            (root / 'bypass.json').write_text(json.dumps(bypass))
            processes.start('bypass-client', [sb, 'run', '-c', root / 'bypass.json'], bypass_port)
            try:
                v.fetch(bypass_port, http_service.server_address[1])
            except (OSError, ValueError):
                print('PASS outer VLESS cannot bypass the fixed Snell backend')
            else:
                raise AssertionError('VLESS bypassed Snell')
            units = root / 'units'
            v.bash_function('BIN_DIR=$1; CONFIG_DIR=$2; SERVICE_USER=$3; write_unit "$4"',
                            Path(sb).parent, config, os.environ.get('USER', 'agent'), units)
            runtime = root / 'runtime'
            runtime.mkdir(mode=0o700)
            v.run('systemd-analyze', '--user', 'verify', *map(str, units.iterdir()),
                  env={**os.environ, 'XDG_RUNTIME_DIR': str(runtime)})
            print('PASS native systemd unit verification (without installing services)')
    print('ALL NATIVE CHECKS PASSED')


if __name__ == '__main__':
    main()
