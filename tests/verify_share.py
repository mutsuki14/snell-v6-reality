#!/usr/bin/env python3
"""Exercise Caddy HTTPS sharing locally; never request a public certificate.

The fixture uses a temporary test CA trusted only by the test client. Production
still requires a public IP and a publicly trusted certificate from ACME.
"""
import argparse
import contextlib
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import tempfile
import urllib.parse

import verify as v

v.SCRIPT = Path(__file__).resolve().parents[1] / 'snell-reality-native.sh'


def test_inputs():
    for ip in ['8.8.8.8', '2606:4700:4700::1111']:
        v.bash_function('validate_share_address "$1" 8443 443 23456', ip)
    for ip in ['127.0.0.1', '10.0.0.1', '100.64.0.1', '203.0.113.1', '224.0.0.1',
               '::', '::1', 'fe80::1%eth0', 'ff02::1', 'example.com']:
        assert v.bash_function('validate_share_address "$1" 8443 443 23456', ip, check=False).returncode
    for port in ['80', '443', '23456', '0', '65536', '08443', '8443;false']:
        assert v.bash_function('validate_share_address 8.8.8.8 "$1" 443 23456', port, check=False).returncode
    assert v.bash_function('validate_share_address 8.8.8.8 8443 80 23456', check=False).returncode
    print('PASS public IP and port conflict validation')


def request(port, ip, path, ca, host=None):
    ctx = ssl.create_default_context(cafile=str(ca))
    with socket.create_connection(('127.0.0.1', port), timeout=3) as sock:
        # IP addresses are intentionally sent without TLS SNI, like real clients.
        with ctx.wrap_socket(sock, server_hostname=ip) as tls:
            tls.sendall(f'GET {path} HTTP/1.1\r\nHost: {host or ip}:{port}\r\nConnection: close\r\n\r\n'.encode())
            response = http.client.HTTPResponse(tls)
            response.begin()
            return response.status, response.getheader('Cache-Control'), response.read()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--caddy', required=True, type=lambda p: str(Path(p).resolve()))
    args = parser.parse_args()
    test_inputs()
    with tempfile.TemporaryDirectory(prefix='snell-share-test-') as folder:
        root = Path(folder)
        config, share, data = root / 'proxy', root / 'share', root / 'data'
        for path in [config / 'clients', share, data / 'profiles']:
            path.mkdir(parents=True)
        port, ip, token = v.free_port(), '203.0.113.10', 'abc123' * 8
        state = {'schema': 1, 'ip': ip, 'port': port, 'token': token}
        share_state = share / 'share.json'
        share_state.write_text(json.dumps(state))
        proxy_state = {'schema': 2, 'engine': 'sing-box', 'private_key': 'server-private-test-only', 'profile_url': ''}
        (config / 'state.json').write_text(json.dumps(proxy_state))
        for name in ['client-tun.json', 'client-mixed.json']:
            payload = {'outbounds': [{'type': 'snell', 'password': 'test-client-secret'}], 'test_profile': name}
            for dest in [config / 'clients' / name, data / 'profiles' / name]:
                dest.write_text(json.dumps(payload))
        # Even an accidentally present non-client file must not be downloadable.
        (data / 'profiles/server.json').write_text('server-private-test-only')
        caddy_config = root / 'caddy.json'
        v.bash_function('SHARE_DATA_DIR=$1; render_share_config "$2" "$3"', data, share_state, caddy_config)
        production = json.loads(caddy_config.read_text())
        issuer = production['apps']['tls']['automation']['policies'][0]['issuers'][0]
        assert issuer['profile'] == 'shortlived' and issuer['challenges']['tls-alpn']['disabled']
        v.run(args.caddy, 'validate', '--config', str(caddy_config))
        print('PASS production ACME configuration accepted by real Caddy (no public issuance)')
        url = v.bash_function('share_url "$1"', share_state).stdout.strip()
        assert url == f'https://{ip}:{port}/{token}/client-tun.json'
        state['ip'] = '2606:4700:4700::1111'
        share_state.write_text(json.dumps(state))
        url6 = v.bash_function('share_url "$1"', share_state).stdout.strip()
        assert url6.startswith('https://[2606:4700:4700::1111]:')
        link = v.bash_function('make_import_link "$1"', url6).stdout.strip()
        assert urllib.parse.parse_qs(urllib.parse.urlsplit(link).query)['url'] == [url6]
        state['ip'] = ip
        share_state.write_text(json.dumps(state))
        print('PASS IPv4 / IPv6 HTTPS URLs and complete-profile import link')
        # Issue a fixture IP certificate from a private, ephemeral test CA.
        v.run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
              '-subj', '/CN=Ephemeral sharing test CA', '-addext', 'basicConstraints=critical,CA:TRUE',
              '-keyout', str(root / 'ca.key'), '-out', str(root / 'ca.pem'))
        v.run('openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=IP test',
              '-keyout', str(root / 'leaf.key'), '-out', str(root / 'leaf.csr'))
        (root / 'extensions').write_text(f'subjectAltName=IP:{ip}\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n')
        v.run('openssl', 'x509', '-req', '-in', str(root / 'leaf.csr'), '-CA', str(root / 'ca.pem'),
              '-CAkey', str(root / 'ca.key'), '-CAcreateserial', '-days', '1',
              '-extfile', str(root / 'extensions'), '-out', str(root / 'leaf.pem'))
        # Only replace certificate issuance and listener binding for the test.
        local_config = json.loads(json.dumps(production))
        local_config['apps']['tls'] = {'certificates': {'load_files': [
            {'certificate': str(root / 'leaf.pem'), 'key': str(root / 'leaf.key')}]}}
        server = local_config['apps']['http']['servers']['profiles']
        server['automatic_https'] = {'disable': True}
        server['listen'] = [f'127.0.0.1:{port}']
        local_path = root / 'local.json'
        local_path.write_text(json.dumps(local_config))
        processes = v.Processes(root)
        with contextlib.ExitStack() as stack:
            stack.callback(processes.close)
            processes.start('caddy', ['env', f'XDG_CONFIG_HOME={root / "xdg-config"}',
                                     f'XDG_DATA_HOME={root / "xdg-data"}', args.caddy,
                                     'run', '--config', str(local_path)], port)
            for name in ['client-tun.json', 'client-mixed.json']:
                status, cache, body = request(port, ip, f'/{token}/{name}', root / 'ca.pem')
                assert status == 200 and cache == 'no-store'
                assert body == (config / 'clients' / name).read_bytes()
                assert b'server-private-test-only' not in body
            for path in ['/', '/client-tun.json', '/wrong/client-tun.json', f'/{token}/',
                         f'/{token}/server.json', f'/{token}/../server.json', f'/{token}/%2e%2e/server.json',
                         f'/{token}/../client-tun.json', '/state.json']:
                assert request(port, ip, path, root / 'ca.pem')[0] == 404, path
            assert request(port, ip, f'/{token}/client-tun.json', root / 'ca.pem', host='other.invalid')[0] == 404
            print('PASS real IP HTTPS without SNI, both profiles, access token and private-file isolation')
            probe = 'CONFIG_DIR=$1; SHARE_CONFIG_DIR=$2; probe_share_https'
            assert v.bash_function(probe, config, share, check=False).returncode != 0
            v.bash_function('export SSL_CERT_FILE=$3; ' + probe, config, share, root / 'ca.pem')
            (data / 'profiles/client-tun.json').write_text('{}')
            assert v.bash_function('export SSL_CERT_FILE=$3; ' + probe, config, share,
                                   root / 'ca.pem', check=False).returncode != 0
            print('PASS readiness rejects untrusted certificates and mismatched configuration')
        v.bash_function('CONFIG_DIR=$1; persist_share_url "$2"', config, url)
        updated = json.loads((config / 'state.json').read_text())
        assert updated == {**proxy_state, 'profile_url': url}
        assert (config / 'state.json').stat().st_mode & 0o777 == 0o600
        unit = root / 'snell-reality-share.service'
        v.bash_function('SHARE_BIN_DIR=$1; SHARE_CONFIG_DIR=$2; SHARE_DATA_DIR=$3; write_share_unit "$4"',
                        Path(args.caddy).parent, share, data, unit)
        runtime = root / 'runtime'
        runtime.mkdir(mode=0o700)
        v.run('systemd-analyze', '--user', 'verify', str(unit), env={**os.environ, 'XDG_RUNTIME_DIR': str(runtime)})
        print('PASS URL persistence preserves proxy credentials; sharing unit syntax passes')
    print('ALL SHARING CHECKS PASSED')


if __name__ == '__main__':
    main()
