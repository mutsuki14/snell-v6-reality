#!/usr/bin/env bash
# Native sing-box on both ends: Snell v6 unsafe-raw through VLESS + REALITY.
set -Eeuo pipefail
umask 077
SCRIPT_VERSION=2.2.1
SINGBOX_VERSION=1.14.4
CADDY_VERSION=2.11.9
CONFIG_DIR=/etc/snell-reality-native
BIN_DIR=/usr/local/lib/snell-reality-native
UNIT_DIR=/etc/systemd/system
MANAGER=/usr/local/sbin/snell-reality-native
SERVICE_USER=snell-reality-native
UNIT=snell-reality-native.service
SERVER=''
SNI=www.cloudflare.com
PORT=443
SNELL_PORT=23456
SOCKS_PORT=1080
LISTEN=''
PROFILE_URL=''
ASSUME_YES=0
WORK_DIR=''
TRANSACTION=0
HAD_INSTALL=0
CREATED_USER=0
OLD_ACTIVE=0
OLD_ENABLED=0
SHARE_CONFIG_DIR=/etc/snell-reality-share
SHARE_BIN_DIR=/usr/local/lib/snell-reality-share
SHARE_DATA_DIR=/var/lib/snell-reality-share
SHARE_USER=snell-reality-share
SHARE_UNIT=snell-reality-share.service
SHARE_IP=''
SHARE_PORT=''
NO_SHARE=1
SHARE_TRANSACTION=0
SHARE_CREATED_USER=0

info() { printf '[+] %s\n' "$*"; }

die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die '请使用 sudo 或 root 执行。'; }

require_systemd() {
    if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null; then
        die '需要正在运行的 systemd；不支持普通 Docker 容器或 OpenRC。'
    fi
}

install_dependencies() {
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID" in
        debian) ((${VERSION_ID%%.*} >= 11)) || die '需要 Debian 11 或更新版本。' ;;
        ubuntu) ((${VERSION_ID%%.*} >= 22)) || die '需要 Ubuntu 22.04 或更新版本。' ;;
        *) die "不支持的系统：$ID。当前支持 Debian / Ubuntu。" ;;
    esac
    local missing=0 cmd
    for cmd in curl tar jq openssl python3 ss flock useradd getent sha256sum timeout; do
        command -v "$cmd" >/dev/null || missing=1
    done
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing=1
    if ((missing)); then
        info '安装依赖……'
        apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            ca-certificates curl tar jq openssl python3 iproute2 util-linux passwd coreutils
    fi
}

validate_options() {
    python3 - "$SERVER" "$SNI" "$PORT" "$SNELL_PORT" "$SOCKS_PORT" "$LISTEN" <<'PY'
import ipaddress, re, sys
server, sni, port, snell, socks, listen = sys.argv[1:]
def domain(value):
    return len(value) <= 253 and '.' in value and all(
        re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label)
        for label in value.split('.'))
def address(value):
    try:
        return ipaddress.ip_address(value)
    except ValueError:
        return None
def fail(message):
    sys.exit('[错误] ' + message)
ip = address(server)
if not (ip or domain(server)):
    fail('--server 必须是 IP 或完整域名，IPv6 不带方括号。')
if ip and (ip.is_loopback or ip.is_unspecified or ip.is_multicast):
    fail('--server 不能是回环、未指定或组播地址。')
if not domain(sni) or address(sni):
    fail('--sni 必须是完整域名，不能是 IP、URL 或端口。')
if server.lower() == sni.lower():
    fail('VPS 地址不能与 REALITY 目标域名相同，以免转发回自身。')
for value in (port, snell, socks):
    if not re.fullmatch(r'[1-9][0-9]{0,4}', value) or int(value) > 65535:
        fail('端口必须是 1–65535 的十进制整数，不能带前导零。')
if port == snell:
    fail('REALITY 入口端口与 Snell 回环端口不能相同。')
if not address(listen) or address(listen).is_multicast:
    fail('--listen 必须是有效的本机 IP 或通配监听地址。')
PY
}

download() {
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --connect-timeout 15 --max-time 240 --retry 3 --retry-delay 2 \
        --output "$2" "$1"
}

detect_server() {
    [[ -n $SERVER ]] && return 0
    info '尝试检测公网 IP；NAT VPS 请显式使用 --server。'
    SERVER=$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org || true)
    if [[ -z $SERVER ]]; then
        SERVER=$(curl -6 -fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org || true)
    fi
    [[ -n $SERVER ]] || die '无法检测公网 IP。请用 --server 指定 VPS 公网地址。'
}

check_target() {
    info "检查 REALITY 目标 $SNI:443 的 TLS 1.3 和 h2……"
    timeout 25 python3 - "$SNI" <<'PY'
import socket, ssl, sys
host = sys.argv[1]
ctx = ssl.create_default_context()
ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_3
ctx.set_alpn_protocols(['h2'])
try:
    with socket.create_connection((host, 443), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            if tls.selected_alpn_protocol() != 'h2':
                sys.exit('[错误] 目标未协商 h2，请更换 --sni。')
            print('[+] 目标 TLS 1.3 / h2 检查通过。')
except (OSError, ssl.SSLError) as exc:
    sys.exit('[错误] REALITY 目标检查失败：' + str(exc) + '；请更换 --sni。')
PY
}

port_free() {
    local result
    result=$(ss -H -ltn "sport = :$1")
    [[ -z $result ]] || die "TCP 端口 $1 已被占用，请选择其他端口。"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if ((SHARE_TRANSACTION && rc != 0)); then
        printf '[错误] 分享服务安装失败，清理本次新增的分享服务；代理配置保留。\n' >&2
        systemctl disable --now "$SHARE_UNIT" >/dev/null 2>&1 || true
        rm -f -- "$UNIT_DIR/$SHARE_UNIT"
        rm -rf -- "$SHARE_CONFIG_DIR" "$SHARE_BIN_DIR" "$SHARE_DATA_DIR"
        if ((SHARE_CREATED_USER)); then userdel "$SHARE_USER" >/dev/null 2>&1 || true; fi
        systemctl daemon-reload || true
    fi
    if ((TRANSACTION && rc != 0)); then
        if ! rollback; then
            printf '[错误] 自动恢复未全部成功；原始备份已保留在 %s/backup，请勿删除。\n' "$WORK_DIR" >&2
            WORK_DIR=''
        fi
    fi
    [[ -z $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
    exit "$rc"
}

usage() {
    cat <<'EOF'
原生 sing-box：Snell v6 unsafe-raw + VLESS/REALITY
服务端一个 sing-box 进程；客户端可使用 sing-box 或 Exclave，无需额外桥接。

sudo bash snell-reality-native.sh install --server VPS公网IP
sudo snell-reality-native {show|check|status|start|stop|restart|logs|upgrade|uninstall}
sudo snell-reality-native share       # Exclave 离线导入串；无需 HTTPS
sudo snell-reality-native https-share # 可选：启用纯 IP HTTPS 配置下载
sudo snell-reality-native share-off   # 关闭并移除本机分享服务
sudo snell-reality-native share-logs  # 查看签发 / 续期日志

首次安装选项：
  --server HOST       公网 IP / 域名；留空尝试自动检测
  --port PORT         REALITY TCP 入口，默认 443
  --sni DOMAIN        目标站点，默认 www.cloudflare.com:443
  --listen IP         默认 0.0.0.0，IPv6 地址默认 ::
  --snell-port PORT   Snell 回环监听端口，默认 23456
  --socks-port PORT   桌面客户端本地代理端口，默认 1080
  --profile-url URL   可选：你自己的 HTTPS 完整配置下载地址
  --with-share        额外启用 IP HTTPS 远程配置下载（默认不开启）
  --no-share          不启用 HTTPS 分享；保留此选项兼容旧命令
  --share-ip IP       分享使用的公网 IP，默认使用已配置的服务器 IP
  --share-port PORT   HTTPS 分享端口，默认 8443

默认输出 Exclave 离线导入串。0.17.68 的备份菜单默认隐藏，首次使用需开启：
  1. “关于”中长按应用版本号，直到出现 developer mode enabled。
  2. “设置”底部的 Experimental flags 中追加一行 enableProfileBackup=true。
  3. 重新启动 Exclave，在配置页选择“添加服务器配置 → 备份 → 从剪贴板导入”。
Exclave 0.17.68 不解析 snell://；此处使用其 config? 备份格式封装完整链路。
只有显式使用 --with-share / https-share 才安装 HTTPS 服务，另需 TCP 80 和分享端口。

生成远程配置导入链接（不会上传文件或启动订阅服务器）：
  bash snell-reality-native.sh import-link --url https://你的站点/随机路径/client-tun.json

卸载可加 --yes 跳过确认。仅支持 Debian 11+ / Ubuntu 22.04+、amd64/arm64、systemd。
本脚本使用独立目录与服务，不覆盖旧版 Xray 桥接安装；切换前请先停止旧服务。
EOF
}

parse_options() {
    while (($#)); do
        case "$1" in
            --yes) ASSUME_YES=1; shift; continue ;;
            --no-share) NO_SHARE=1; shift; continue ;;
            --with-share) NO_SHARE=0; shift; continue ;;
            --server|--port|--sni|--listen|--snell-port|--socks-port|--profile-url|--url|--share-ip|--share-port)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "$1 缺少参数。"
                case "$1" in
                    --server) SERVER=$2 ;;
                    --port) PORT=$2 ;;
                    --sni) SNI=$2 ;;
                    --listen) LISTEN=$2 ;;
                    --snell-port) SNELL_PORT=$2 ;;
                    --socks-port) SOCKS_PORT=$2 ;;
                    --profile-url|--url) PROFILE_URL=$2 ;;
                    --share-ip) SHARE_IP=$2 ;;
                    --share-port) SHARE_PORT=$2 ;;
                esac
                shift 2 ;;
            *) die "未知参数：$1" ;;
        esac
    done
}

make_import_link() {
    python3 - "$1" <<'PY'
import sys, urllib.parse
value = sys.argv[1]
try:
    url = urllib.parse.urlsplit(value)
    port = url.port
except ValueError:
    sys.exit('无效的配置 URL。')
if (url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment
        or any(ord(c) <= 32 or ord(c) == 127 for c in value)):
    sys.exit('请提供无用户名、密码、片段和空白字符的 HTTPS 配置下载地址。')
print('sing-box://import-remote-profile?' + urllib.parse.urlencode({'url': value}) + '#Snell-REALITY')
PY
}

render_exclave_export() {
    # Exclave 0.17.68: ConfigBean + AbstractBean, Kryo 5.7.1, zlib and Base64.
    # This is a self-contained clipboard backup, not a URI or subscription URL.
    python3 - "$1" "$2" <<'PY'
import base64, ipaddress, json, os, pathlib, struct, sys, zlib
s = json.load(open(sys.argv[1]))
out = pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
dns_servers = ['1.1.1.1']
try:
    ipaddress.ip_address(s['server'])
except ValueError:
    # Resolve the proxy hostname independently to avoid a recursive proxy dial.
    dns_servers.insert(0, {'address': 'localhost', 'domains': ['full:' + s['server']], 'skipFallback': True})
config = {
    'log': {'loglevel': 'warning'},
    'dns': {'servers': dns_servers},
    'outbounds': [
        {'tag': 'snell-out', 'protocol': 'snell',
         'settings': {'address': '127.0.0.1', 'port': s['snell_port'],
                      'version': 6, 'psk': s['psk'], 'mode': 'unsafe-raw', 'reuse': True},
         'proxySettings': {'tag': 'reality-out', 'transportLayer': True}},
        {'tag': 'reality-out', 'protocol': 'vless',
         'settings': {'vnext': [{'address': s['server'], 'port': s['port'],
                                'users': [{'id': s['uuid'], 'encryption': 'none'}]}]},
         'streamSettings': {'network': 'tcp', 'security': 'reality',
                            'realitySettings': {'serverName': s['sni'], 'publicKey': s['public_key'],
                                                'shortId': s['short_id'], 'fingerprint': 'chrome'}}},
        {'tag': 'dns-out', 'protocol': 'dns',
         'settings': {'address': '1.1.1.1', 'port': 53, 'network': 'udp'},
         'proxySettings': {'tag': 'snell-out', 'transportLayer': True}},
        {'tag': 'direct', 'protocol': 'freedom'}
    ],
    'routing': {'domainStrategy': 'AsIs', 'rules': [
        {'type': 'field', 'inboundTag': ['dns-in'], 'outboundTag': 'dns-out'}
    ]}
}
content = json.dumps(config, ensure_ascii=True, separators=(',', ':'))

def kryo_string(value):
    # All strings in this export are ASCII; JSON escapes non-ASCII credentials.
    data = value.encode('ascii')
    if not data:
        return b'\x81'
    if 1 < len(data) <= 32:
        return data[:-1] + bytes([data[-1] | 0x80])
    length = len(data) + 1
    prefix = bytearray([(length & 0x3f) | 0x80 | (0x40 if length >> 6 else 0)])
    length >>= 6
    while length:
        prefix.append((length & 0x7f) | (0x80 if length >> 7 else 0))
        length >>= 7
    return bytes(prefix) + data

blob = (struct.pack('<i', 1) + kryo_string('v2ray') + kryo_string(content) + kryo_string('')
        + struct.pack('<i', 2) + kryo_string('Snell-v6-REALITY') + struct.pack('<i', 0))
backup = 'config?' + base64.b64encode(zlib.compress(blob, 9)).decode('ascii')
for name, value in [('client-exclave.json', content), ('exclave-import.txt', backup)]:
    path = out / name
    path.write_text(value + '\n', encoding='utf-8')
    os.chmod(path, 0o600)
PY
}

show_exclave() {
    require_install
    render_exclave_export "$CONFIG_DIR/state.json" "$CONFIG_DIR/clients"
    printf 'Exclave 离线导入串（含 Snell v6 + REALITY，无需订阅或 HTTPS）：\n'
    cat "$CONFIG_DIR/clients/exclave-import.txt"
    printf '\nExclave 0.17.68 的备份菜单默认隐藏，首次使用请先开启：\n'
    printf '  1. 打开“关于”，长按应用版本号，直到出现 developer mode enabled。\n'
    printf '  2. 打开“设置”底部的 Experimental flags，保留已有内容，另起一行添加：\n'
    printf '     enableProfileBackup=true\n'
    printf '  3. 保存后重新启动 Exclave，使配置页菜单刷新。\n'
    printf '复制上面完整的 config? 行，在配置页选择“添加服务器配置 → 备份 → 从剪贴板导入”。\n'
    printf '这是 Exclave 0.17.68 的备份格式；普通节点导入入口不解析此格式，也不支持 snell://。\n'
    printf '导入文件：%s/clients/exclave-import.txt；只分享给需要使用的设备。\n' "$CONFIG_DIR"
}

validate_share_address() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import ipaddress, re, sys
ip, port, proxy_port, snell_port = sys.argv[1:]
try:
    address = ipaddress.ip_address(ip)
except ValueError:
    sys.exit('纯 IP 分享需要公网 IP；服务器配置为域名时，请用 --share-ip 指定公网 IP。')
if not address.is_global or address.is_multicast or '%' in ip:
    sys.exit('IP 证书需要可从公网访问的全球单播 IP。')
if not re.fullmatch(r'[1-9][0-9]{0,4}', port) or int(port) > 65535:
    sys.exit('分享端口必须是 1–65535 的十进制整数。')
if int(port) in (80, int(proxy_port), int(snell_port)):
    sys.exit('分享端口不能与 HTTP 验证、REALITY 或 Snell 端口冲突。')
if int(proxy_port) == 80 or int(snell_port) == 80:
    sys.exit('TCP 80 已用于代理，无法执行 IP 证书的 HTTP 验证。')
PY
}

share_url() {
    python3 - "$1" <<'PY'
import ipaddress, json, sys
s = json.load(open(sys.argv[1]))
ip = ipaddress.ip_address(s['ip'])
host = '[' + str(ip) + ']' if ip.version == 6 else str(ip)
print('https://' + host + ':' + str(s['port']) + '/' + s['token'] + '/client-tun.json')
PY
}

render_share_config() {
    local state=$1 output=$2
    jq --arg root "$SHARE_DATA_DIR/profiles" --arg storage "$SHARE_DATA_DIR/caddy" '
      . as $s | {
        admin:{disabled:true},storage:{module:"file_system",root:$storage},
        logging:{logs:{default:{level:"WARN"}}},
        apps:{tls:{certificates:{automate:[$s.ip]},automation:{policies:[{
          subjects:[$s.ip],issuers:[{module:"acme",ca:"https://acme-v02.api.letsencrypt.org/directory",
          profile:"shortlived",challenges:{"tls-alpn":{disabled:true}}}]}]}},
        http:{http_port:80,https_port:$s.port,servers:{profiles:{
          listen:[(":"+($s.port|tostring))],protocols:["h1","h2"],
          automatic_https:{disable_redirects:true},tls_connection_policies:[{default_sni:$s.ip}],
          routes:([
            {name:"client-tun.json"},{name:"client-mixed.json"}
          ] | map(.name as $name | {
            match:[{host:[$s.ip],path:[("/"+$s.token+"/"+$name)]}],terminal:true,
            handle:[{handler:"headers",response:{set:{"Cache-Control":["no-store"],"X-Content-Type-Options":["nosniff"]}}},
              {handler:"rewrite",uri:("/"+$name)},{handler:"file_server",root:$root}]
          }) + [{handle:[{handler:"static_response",status_code:404}]}])
        }}}}}
    ' "$state" > "$output"
}

download_share_binary() {
    local arch digest
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64; digest=5b8cb7faf8726a2028ad96a66e54e6e81e8f361bc6175e5d22bbd997cc5177fb ;;
        aarch64|arm64) arch=arm64; digest=5e377cff994fc9362a6fcf695c53f226cfca3a3ef85bd3a3687cf252d6310165 ;;
        *) die 'HTTPS 分享仅支持 amd64 / arm64。' ;;
    esac
    info "下载并校验 Caddy $CADDY_VERSION（用于 IP 证书和 HTTPS 配置下载）……"
    download "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${arch}.tar.gz" "$WORK_DIR/caddy.tar.gz"
    printf '%s  %s\n' "$digest" "$WORK_DIR/caddy.tar.gz" | sha256sum --check --status
    tar -xOzf "$WORK_DIR/caddy.tar.gz" caddy > "$WORK_DIR/caddy"
    chmod 0755 "$WORK_DIR/caddy"
    "$WORK_DIR/caddy" version > "$WORK_DIR/caddy-version.log"
    grep -Fq "v$CADDY_VERSION " "$WORK_DIR/caddy-version.log"
}

write_share_unit() {
    cat > "$1" <<EOF
[Unit]
Description=HTTPS IP certificate and private configuration download for Snell
After=network-online.target
Wants=network-online.target

[Service]
User=$SHARE_USER
Group=$SHARE_USER
ExecStart=$SHARE_BIN_DIR/caddy run --config $SHARE_CONFIG_DIR/caddy.json
Environment=XDG_DATA_HOME=$SHARE_DATA_DIR/data
Environment=XDG_CONFIG_HOME=$SHARE_DATA_DIR/config
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$SHARE_DATA_DIR
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

sync_share_profiles() {
    [[ -f $SHARE_CONFIG_DIR/share.json ]] || return 0
    local file
    for file in client-tun.json client-mixed.json; do
        install -m 0640 -o root -g "$SHARE_USER" "$CONFIG_DIR/clients/$file" "$SHARE_DATA_DIR/profiles/.$file.new"
        mv -f -- "$SHARE_DATA_DIR/profiles/.$file.new" "$SHARE_DATA_DIR/profiles/$file"
    done
}

probe_share_https() {
    # Verify the publicly trusted certificate and exact configuration over local TLS.
    # This does not bypass CA validation and does not prove the cloud firewall is open.
    python3 - "$SHARE_CONFIG_DIR/share.json" "$CONFIG_DIR/clients/client-tun.json" <<'PY'
import http.client, ipaddress, json, socket, ssl, sys
state = json.load(open(sys.argv[1]))
ip = ipaddress.ip_address(state['ip'])
loopback = '::1' if ip.version == 6 else '127.0.0.1'
host = '[' + str(ip) + ']' if ip.version == 6 else str(ip)
try:
    with socket.create_connection((loopback, state['port']), timeout=2) as sock:
        with ssl.create_default_context().wrap_socket(sock, server_hostname=str(ip)) as tls:
            request = f"GET /{state['token']}/client-tun.json HTTP/1.1\r\nHost: {host}:{state['port']}\r\nConnection: close\r\n\r\n"
            tls.sendall(request.encode())
            response = http.client.HTTPResponse(tls)
            response.begin()
            body = response.read(2 * 1024 * 1024)
            if response.status != 200 or json.loads(body) != json.load(open(sys.argv[2])):
                sys.exit(1)
except (OSError, ValueError, http.client.HTTPException):
    sys.exit(1)
PY
}

persist_share_url() {
    local url=$1 tmp
    tmp=$(mktemp "$CONFIG_DIR/.state.XXXXXXXX")
    jq --arg url "$url" '.profile_url=$url' "$CONFIG_DIR/state.json" > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$CONFIG_DIR/state.json"
}

enable_share() {
    require_install
    install_dependencies
    local path token source_file url attempt ready=0 current_ip current_port
    if [[ -f $SHARE_CONFIG_DIR/share.json ]]; then
        jq -e '.schema == 1 and (.token | test("^[0-9a-f]{48}$"))' "$SHARE_CONFIG_DIR/share.json" >/dev/null || die '分享状态文件不兼容。'
        current_ip=$(jq -r .ip "$SHARE_CONFIG_DIR/share.json")
        current_port=$(jq -r .port "$SHARE_CONFIG_DIR/share.json")
        [[ -z $SHARE_IP || $SHARE_IP == "$current_ip" ]] || die '更换分享 IP 请先 share-off，再重新执行 https-share。'
        [[ -z $SHARE_PORT || $SHARE_PORT == "$current_port" ]] || die '更换分享端口请先 share-off，再重新执行 https-share。'
        SHARE_IP=$current_ip
        SHARE_PORT=$current_port
    else
        for path in "$SHARE_CONFIG_DIR" "$SHARE_BIN_DIR" "$SHARE_DATA_DIR" "$UNIT_DIR/$SHARE_UNIT"; do
            [[ ! -e $path && ! -L $path ]] || die "已有文件 $path，拒绝接管。"
        done
        getent passwd "$SHARE_USER" >/dev/null && die "已有同名用户 $SHARE_USER，拒绝接管。"
        getent group "$SHARE_USER" >/dev/null && die "已有同名组 $SHARE_USER，拒绝接管。"
        SHARE_IP=${SHARE_IP:-$(jq -r .server "$CONFIG_DIR/state.json")}
        SHARE_PORT=${SHARE_PORT:-8443}
        validate_share_address "$SHARE_IP" "$SHARE_PORT" "$(jq -r .port "$CONFIG_DIR/state.json")" "$(jq -r .snell_port "$CONFIG_DIR/state.json")"
        SHARE_IP=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(sys.argv[1]))' "$SHARE_IP")
        port_free 80
        port_free "$SHARE_PORT"
        [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d /tmp/snell-reality-share.XXXXXXXX)
        token=$(openssl rand -hex 24)
        jq -n --arg ip "$SHARE_IP" --argjson port "$SHARE_PORT" --arg token "$token" \
            '{schema:1,ip:$ip,port:$port,token:$token}' > "$WORK_DIR/share.json"
        render_share_config "$WORK_DIR/share.json" "$WORK_DIR/caddy.json"
        download_share_binary
        # Validation must not create production certificate storage as root.
        jq --arg root "$WORK_DIR/caddy-validation" '.storage.root=$root' "$WORK_DIR/caddy.json" > "$WORK_DIR/caddy-validate.json"
        "$WORK_DIR/caddy" validate --config "$WORK_DIR/caddy-validate.json" > "$WORK_DIR/caddy-validate.log" 2>&1 || die 'Caddy 配置校验失败。'
        write_share_unit "$WORK_DIR/share.service"
        SHARE_TRANSACTION=1
        useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SHARE_USER"
        SHARE_CREATED_USER=1
        install -d -m 0750 -o root -g "$SHARE_USER" "$SHARE_CONFIG_DIR"
        install -d -m 0755 "$SHARE_BIN_DIR"
        install -d -m 0750 -o "$SHARE_USER" -g "$SHARE_USER" "$SHARE_DATA_DIR"
        install -d -m 0750 -o root -g "$SHARE_USER" "$SHARE_DATA_DIR/profiles"
        install -m 0755 "$WORK_DIR/caddy" "$SHARE_BIN_DIR/caddy"
        install -m 0600 "$WORK_DIR/share.json" "$SHARE_CONFIG_DIR/share.json"
        install -m 0640 -o root -g "$SHARE_USER" "$WORK_DIR/caddy.json" "$SHARE_CONFIG_DIR/caddy.json"
        install -m 0644 "$WORK_DIR/share.service" "$UNIT_DIR/$SHARE_UNIT"
        systemctl daemon-reload
    fi
    sync_share_profiles
    systemctl enable --now "$SHARE_UNIT" >/dev/null
    systemctl is-active --quiet "$SHARE_UNIT" || die '分享服务启动失败，请检查 share-logs。'
    SHARE_TRANSACTION=0
    # Keep a running issuer after a pending ACME validation so retries reuse its account/certificates.
    source_file=$(readlink -f -- "${BASH_SOURCE[0]}")
    if [[ $source_file != "$MANAGER" ]]; then install -m 0755 "$source_file" "$MANAGER"; fi
    info "正在申请 / 检查受信任的 IP 证书。请在防火墙和云安全组放行 TCP 80、$SHARE_PORT。"
    for ((attempt=0; attempt<24; attempt++)); do
        if probe_share_https >/dev/null 2>&1; then ready=1; break; fi
        systemctl is-active --quiet "$SHARE_UNIT" || die '分享服务异常退出，请执行 sudo snell-reality-native share-logs。'
        if ((attempt % 6 == 0)); then info '等待 IP 证书签发及 HTTPS 就绪……'; fi
        sleep 3
    done
    ((ready)) || die "HTTPS 服务已安装，但证书尚未就绪；代理及离线导入不受影响。请放行 TCP 80、$SHARE_PORT，查看 share-logs，随后重试 https-share。"
    url=$(share_url "$SHARE_CONFIG_DIR/share.json")
    persist_share_url "$url"
    info 'HTTPS 证书及配置内容已在 VPS 本机验证。公网访问还取决于云安全组。'
}

remove_share() {
    [[ -f $SHARE_CONFIG_DIR/share.json ]] || return 0
    local owned_url current_url
    owned_url=$(share_url "$SHARE_CONFIG_DIR/share.json")
    systemctl disable --now "$SHARE_UNIT"
    rm -f -- "$UNIT_DIR/$SHARE_UNIT"
    rm -rf -- "$SHARE_CONFIG_DIR" "$SHARE_BIN_DIR" "$SHARE_DATA_DIR"
    systemctl daemon-reload
    if [[ -f $CONFIG_DIR/state.json ]]; then
        current_url=$(jq -r '.profile_url // ""' "$CONFIG_DIR/state.json")
        if [[ $current_url == "$owned_url" ]]; then persist_share_url ''; fi
    fi
    userdel "$SHARE_USER"
    info '已关闭并移除本机 HTTPS 分享服务；代理保持原状。'
}

download_binary() {
    local arch digest archive_member
    case "$(uname -m)" in
        x86_64|amd64)
            arch=amd64
            digest=699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968 ;;
        aarch64|arm64)
            arch=arm64
            digest=436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26 ;;
        *) die '仅支持 amd64 / arm64。' ;;
    esac
    info "下载 sing-box $SINGBOX_VERSION 并校验 SHA-256……"
    download "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz" "$WORK_DIR/sing-box.tar.gz"
    printf '%s  %s\n' "$digest" "$WORK_DIR/sing-box.tar.gz" | sha256sum --check --status
    mkdir -p "$WORK_DIR/bin"
    archive_member="sing-box-${SINGBOX_VERSION}-linux-${arch}/sing-box"
    tar -xOzf "$WORK_DIR/sing-box.tar.gz" "$archive_member" > "$WORK_DIR/bin/sing-box"
    chmod 0755 "$WORK_DIR/bin/sing-box"
    "$WORK_DIR/bin/sing-box" version > "$WORK_DIR/version.log"
    grep -Fxq "sing-box version $SINGBOX_VERSION" "$WORK_DIR/version.log"
}

make_state() {
    local keys private public psk uuid sid
    keys=$("$WORK_DIR/bin/sing-box" generate reality-keypair)
    private=$(awk '/^PrivateKey:/ {print $2}' <<< "$keys")
    public=$(awk '/^PublicKey:/ {print $2}' <<< "$keys")
    [[ $private =~ ^[A-Za-z0-9_-]{43}$ && $public =~ ^[A-Za-z0-9_-]{43}$ ]] || die '无法解析 REALITY 密钥。'
    psk=$(openssl rand -hex 16)
    sid=$(openssl rand -hex 8)
    uuid=$("$WORK_DIR/bin/sing-box" generate uuid)
    jq -n --arg server "$SERVER" --arg sni "$SNI" --arg listen "$LISTEN" \
        --argjson port "$PORT" --argjson snell_port "$SNELL_PORT" --argjson socks_port "$SOCKS_PORT" \
        --arg psk "$psk" --arg uuid "$uuid" --arg private "$private" --arg public "$public" --arg sid "$sid" \
        --arg version "$SINGBOX_VERSION" --arg profile_url "$PROFILE_URL" \
        '{schema:2,engine:"sing-box",server:$server,sni:$sni,listen:$listen,port:$port,
          snell_port:$snell_port,socks_port:$socks_port,psk:$psk,uuid:$uuid,
          private_key:$private,public_key:$public,short_id:$sid,singbox_version:$version,
          profile_url:$profile_url}' > "$WORK_DIR/state.json"
}

render_configs() {
    local state=$1 out=$2
    mkdir -p "$out/clients"
    install -m 0600 "$state" "$out/state.json"
    jq '{log:{level:"warn"},dns:{servers:[{type:"local",tag:"system-dns"}]},
      inbounds:[
        {type:"vless",tag:"reality-in",listen:.listen,listen_port:.port,users:[{uuid:.uuid}],
         tls:{enabled:true,server_name:.sni,reality:{enabled:true,
           handshake:{server:.sni,server_port:443},private_key:.private_key,short_id:[.short_id]}}},
        {type:"snell",tag:"snell-in",listen:"127.0.0.1",listen_port:.snell_port,
         version:6,psk:.psk,mode:"unsafe-raw"}],
      outbounds:[{type:"direct",tag:"direct-out"}],
      route:{default_domain_resolver:"system-dns",final:"direct-out",rules:[
        {inbound:["reality-in"],network:"tcp",action:"route",outbound:"direct-out",
         override_address:"127.0.0.1",override_port:.snell_port},
        {inbound:["reality-in"],action:"reject"}]}}
    ' "$state" > "$out/server.json"
    jq '{log:{level:"warn"},dns:{servers:[{type:"local",tag:"bootstrap-dns"}]},
      inbounds:[{type:"mixed",tag:"local-proxy",listen:"127.0.0.1",listen_port:.socks_port}],
      outbounds:[
        {type:"snell",tag:"snell-out",server:"127.0.0.1",server_port:.snell_port,
         version:6,psk:.psk,mode:"unsafe-raw",reuse:true,detour:"reality-out"},
        {type:"vless",tag:"reality-out",server:.server,server_port:.port,uuid:.uuid,
         tls:{enabled:true,server_name:.sni,utls:{enabled:true,fingerprint:"chrome"},
              reality:{enabled:true,public_key:.public_key,short_id:.short_id}}}],
      route:{default_domain_resolver:"bootstrap-dns",final:"snell-out"}}
    ' "$state" > "$out/clients/client-mixed.json"
    # Full TUN profile for apps that accept sing-box configurations (core 1.14.4).
    # IPv4 and IPv6 routes are both captured. DNS uses Snell's UDP-over-TCP path.
    jq '.inbounds=[{type:"tun",tag:"tun-in",address:["172.19.0.1/30","fdfe:dcba:9876::1/126"],
                     mtu:1500,auto_route:true,strict_route:true,stack:"system"}]
      | .dns.servers += [{type:"udp",tag:"proxy-dns",server:"1.1.1.1",server_port:53,detour:"snell-out"}]
      | .dns.final="proxy-dns"
      | .route.auto_detect_interface=true
      | .route.rules=[{inbound:["tun-in"],action:"sniff"},{protocol:"dns",action:"hijack-dns"}]
    ' "$out/clients/client-mixed.json" > "$out/clients/client-tun.json"
    render_exclave_export "$state" "$out/clients"
    chmod 0600 "$out/"*.json "$out/clients/"*.json
}

check_configs() {
    local binary=$1 directory=$2 file
    for file in server.json clients/client-mixed.json clients/client-tun.json; do
        "$binary" check -c "$directory/$file"
    done
}

write_unit() {
    mkdir -p "$1"
    cat > "$1/$UNIT" <<EOF
[Unit]
Description=Native sing-box Snell v6 over REALITY
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN_DIR/sing-box run -c $CONFIG_DIR/server.json
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

require_install() {
    [[ -f $CONFIG_DIR/state.json ]] || die '尚未安装原生版，请先执行 install。'
    jq -e '.schema == 2 and .engine == "sing-box"' "$CONFIG_DIR/state.json" >/dev/null || die '状态文件不兼容。'
}

snapshot_install() {
    if [[ -e $CONFIG_DIR ]]; then
        HAD_INSTALL=1
        require_install
        mkdir -p "$WORK_DIR/backup"
        cp -a "$CONFIG_DIR" "$WORK_DIR/backup/config"
        cp -a "$BIN_DIR" "$WORK_DIR/backup/bin"
        cp -a "$MANAGER" "$WORK_DIR/backup/manager"
        cp -a "$UNIT_DIR/$UNIT" "$WORK_DIR/backup/unit"
        systemctl is-active --quiet "$UNIT" && OLD_ACTIVE=1
        systemctl is-enabled --quiet "$UNIT" && OLD_ENABLED=1
    fi
    return 0
}

rollback() {
    local failed=0
    printf '[错误] 部署失败，恢复原生版的专用配置与服务。\n' >&2
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    rm -rf -- "$CONFIG_DIR" "$BIN_DIR" || failed=1
    rm -f -- "$MANAGER" "$UNIT_DIR/$UNIT" || failed=1
    if ((HAD_INSTALL)); then
        cp -a "$WORK_DIR/backup/config" "$CONFIG_DIR" || failed=1
        cp -a "$WORK_DIR/backup/bin" "$BIN_DIR" || failed=1
        cp -a "$WORK_DIR/backup/manager" "$MANAGER" || failed=1
        cp -a "$WORK_DIR/backup/unit" "$UNIT_DIR/$UNIT" || failed=1
    elif ((CREATED_USER)); then
        userdel "$SERVICE_USER" >/dev/null 2>&1 || failed=1
    fi
    systemctl daemon-reload || failed=1
    if ((HAD_INSTALL)); then
        if ((OLD_ENABLED)); then systemctl enable "$UNIT" >/dev/null 2>&1 || failed=1; fi
        if ((OLD_ACTIVE)); then systemctl start "$UNIT" || failed=1; fi
    fi
    return "$failed"
}

check_service() {
    systemctl is-active --quiet "$UNIT" || return 1
    python3 - "$CONFIG_DIR/state.json" "$CONFIG_DIR/server.json" <<'PY'
import json, socket, subprocess, sys
state = json.load(open(sys.argv[1]))
cfg = json.load(open(sys.argv[2]))
inner = next(i for i in cfg['inbounds'] if i['tag'] == 'snell-in')
if inner['listen'] != '127.0.0.1' or inner['mode'] != 'unsafe-raw' or inner['version'] != 6:
    sys.exit('Snell 配置不符合回环监听 / v6 / unsafe-raw 要求。')
port = state['snell_port']
lines = subprocess.check_output(['ss','-H','-ltn','sport = :' + str(port)], text=True).splitlines()
if not lines or any(row.split()[3] != '127.0.0.1:' + str(port) for row in lines):
    sys.exit('Snell 未严格绑定到 127.0.0.1。')
host = {'0.0.0.0':'127.0.0.1','::':'::1'}.get(state['listen'], state['listen'])
for address, number in [('127.0.0.1', port), (host, state['port'])]:
    with socket.create_connection((address, number), timeout=2):
        pass
PY
}

deploy() {
    local action=$1 path self_source healthy=0 attempt
    install_dependencies
    if [[ $action == install && -f $CONFIG_DIR/state.json ]]; then
        require_install
        self_source=$(readlink -f -- "${BASH_SOURCE[0]}")
        if [[ $self_source != "$MANAGER" ]]; then install -m 0755 "$self_source" "$MANAGER"; fi
        info '原生版已安装，保留现有配置。'; return 0
    fi
    if [[ $action == upgrade ]]; then require_install; fi
    if [[ $action == install ]]; then
        for path in "$CONFIG_DIR" "$BIN_DIR" "$MANAGER" "$UNIT_DIR/$UNIT"; do
            [[ ! -e $path && ! -L $path ]] || die "已有文件 $path，拒绝覆盖。"
        done
        getent passwd "$SERVICE_USER" >/dev/null && die "已有同名用户 $SERVICE_USER，拒绝接管。"
        getent group "$SERVICE_USER" >/dev/null && die "已有同名组 $SERVICE_USER，拒绝接管。"
        detect_server
        if [[ -z $LISTEN ]]; then
            if [[ $SERVER == *:* ]]; then LISTEN=::; else LISTEN=0.0.0.0; fi
        fi
        validate_options
        [[ -z $PROFILE_URL ]] || make_import_link "$PROFILE_URL" >/dev/null
        port_free "$PORT"
        port_free "$SNELL_PORT"
    else
        SNI=$(jq -r .sni "$CONFIG_DIR/state.json")
    fi
    check_target
    self_source=$(readlink -f -- "${BASH_SOURCE[0]}")
    [[ -f $self_source ]] || die '请保存脚本后用 bash 执行，不支持管道执行。'
    WORK_DIR=$(mktemp -d /tmp/snell-reality-native.XXXXXXXX)
    download_binary
    if [[ $action == install ]]; then
        make_state
    else
        jq --arg version "$SINGBOX_VERSION" '.singbox_version=$version' "$CONFIG_DIR/state.json" > "$WORK_DIR/state.json"
    fi
    render_configs "$WORK_DIR/state.json" "$WORK_DIR/config"
    check_configs "$WORK_DIR/bin/sing-box" "$WORK_DIR/config"
    write_unit "$WORK_DIR/units"
    install -m 0755 "$self_source" "$WORK_DIR/manager"
    snapshot_install
    TRANSACTION=1
    if (( ! HAD_INSTALL )); then
        useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
        CREATED_USER=1
    else
        systemctl stop "$UNIT"
    fi
    install -d -m 0755 "$BIN_DIR"
    install -m 0755 "$WORK_DIR/bin/sing-box" "$BIN_DIR/sing-box"
    install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"
    install -m 0600 "$WORK_DIR/config/state.json" "$CONFIG_DIR/state.json"
    install -m 0640 -o root -g "$SERVICE_USER" "$WORK_DIR/config/server.json" "$CONFIG_DIR/server.json"
    install -d -m 0700 "$CONFIG_DIR/clients"
    install -m 0600 "$WORK_DIR/config/clients/"*.json "$CONFIG_DIR/clients/"
    install -m 0600 "$WORK_DIR/config/clients/exclave-import.txt" "$CONFIG_DIR/clients/exclave-import.txt"
    install -m 0644 "$WORK_DIR/units/$UNIT" "$UNIT_DIR/$UNIT"
    install -m 0755 "$WORK_DIR/manager" "$MANAGER"
    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null
    systemctl start "$UNIT"
    for ((attempt=0; attempt<10; attempt++)); do
        if check_service >/dev/null 2>&1; then healthy=1; break; fi
        sleep 1
    done
    ((healthy)) || die '服务未启动；使用 journalctl -u snell-reality-native 查看错误。'
    sleep 2
    check_service
    TRANSACTION=0
    sync_share_profiles
    info '原生版安装完成，已设置开机启动。'
}

show_config() {
    require_install
    local url owned_url=''
    info "服务端使用 sing-box $SINGBOX_VERSION；导出 sing-box 配置及 Exclave 离线备份。"
    printf '入口：%s，TCP %s\n' "$(jq -r .server "$CONFIG_DIR/state.json")" "$(jq -r .port "$CONFIG_DIR/state.json")"
    printf '完整客户端配置（含凭据）：\n  %s/clients/client-mixed.json\n  %s/clients/client-tun.json\n' "$CONFIG_DIR" "$CONFIG_DIR"
    printf '桌面 SOCKS/HTTP 使用 mixed；支持 TUN 配置的客户端可导入 tun 文件。\n'
    show_exclave
    url=$(jq -r '.profile_url // ""' "$CONFIG_DIR/state.json")
    if [[ -f $SHARE_CONFIG_DIR/share.json ]]; then owned_url=$(share_url "$SHARE_CONFIG_DIR/share.json"); fi
    if [[ -n $url ]]; then
        if [[ $url == "$owned_url" ]]; then
            printf '本机 HTTPS 配置下载地址：%s\n' "$url"
            printf '请保持 TCP 80 和 %s 可从公网访问，用于证书续期和配置下载。\n' "$(jq -r .port "$SHARE_CONFIG_DIR/share.json")"
        else
            printf '自定义配置地址：%s\n请确认该地址已部署完整 client-tun.json。\n' "$url"
        fi
        printf '可选 HTTPS 远程配置导入链接（适用于支持此 URI 的 sing-box 客户端）：\n'
        make_import_link "$url"
    fi
    printf '请在防火墙与云安全组放行 TCP %s，无需开放 Snell 回环端口或入站 UDP。\n' "$(jq -r .port "$CONFIG_DIR/state.json")"
}

uninstall() {
    require_install
    if (( ! ASSUME_YES )); then
        local answer
        printf '删除原生版服务、程序、配置和密钥？输入 yes 继续：' > /dev/tty
        read -r answer < /dev/tty
        [[ $answer == yes ]] || { info '取消卸载。'; return 0; }
    fi
    remove_share
    systemctl disable --now "$UNIT"
    rm -f -- "$UNIT_DIR/$UNIT" "$MANAGER"
    rm -rf -- "$CONFIG_DIR" "$BIN_DIR"
    systemctl daemon-reload
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
    userdel "$SERVICE_USER"
    info '原生版卸载完成；旧版安装、系统依赖和防火墙保持原状。'
}

main() {
    local action=${1:-install}
    if (($#)); then shift; fi
    case "$action" in
        --help|-h|help) usage; return 0 ;;
        --version) printf '%s\n' "$SCRIPT_VERSION"; return 0 ;;
        import-link)
            [[ $# == 2 && $1 == --url ]] || die '用法：import-link --url HTTPS配置下载地址'
            make_import_link "$2"; return 0 ;;
        install|upgrade|show|check|status|start|stop|restart|logs|uninstall|share|https-share|share-off|share-logs) ;;
        *) usage; die "未知命令：$action" ;;
    esac
    if [[ $action == https-share ]]; then
        local option
        for ((option=1; option<=$#; option+=2)); do
            [[ ${!option} == --share-ip || ${!option} == --share-port ]] || die 'https-share 仅接受 --share-ip 和 --share-port。'
        done
    elif [[ $action != install && $# -gt 0 ]]; then
        [[ $action == uninstall && $# == 1 && $1 == --yes ]] || die '这些参数仅适用于首次 install。'
    fi
    parse_options "$@"
    require_root
    require_systemd
    command -v flock >/dev/null || die '缺少 flock，请先 apt-get install util-linux。'
    exec 9>/run/lock/snell-reality-native.lock
    flock -n 9 || die '另一个原生版管理命令正在执行。'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'printf "[错误] 第 %s 行执行失败。\n" "$LINENO" >&2' ERR
    case "$action" in
        install)
            deploy install
            if (( ! NO_SHARE )) && { [[ -f $SHARE_CONFIG_DIR/share.json ]] || [[ -z $(jq -r '.profile_url // ""' "$CONFIG_DIR/state.json") ]]; }; then
                enable_share
            fi
            show_config ;;
        upgrade) deploy upgrade; show_config ;;
        share)
            require_install
            local source_file
            source_file=$(readlink -f -- "${BASH_SOURCE[0]}")
            if [[ $source_file != "$MANAGER" ]]; then install -m 0755 "$source_file" "$MANAGER"; fi
            show_exclave ;;
        https-share) enable_share; show_config ;;
        share-off) require_install; remove_share ;;
        share-logs) require_install; flock -u 9; journalctl -u "$SHARE_UNIT" --no-pager -n 80 -f ;;
        show) show_config ;;
        check) require_install; check_configs "$BIN_DIR/sing-box" "$CONFIG_DIR"; check_service; info '本机配置与服务检查通过。' ;;
        status) require_install; systemctl --no-pager --full status "$UNIT" ;;
        start|stop) require_install; systemctl "$action" "$UNIT" ;;
        restart) require_install; check_configs "$BIN_DIR/sing-box" "$CONFIG_DIR"; systemctl restart "$UNIT"; sleep 2; check_service ;;
        logs) require_install; flock -u 9; journalctl -u "$UNIT" --no-pager -n 80 -f ;;
        uninstall) uninstall ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
