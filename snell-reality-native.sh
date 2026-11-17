#!/usr/bin/env bash
# Native sing-box on both ends: Snell v6 unsafe-raw through VLESS + REALITY.
set -Eeuo pipefail
umask 077
SCRIPT_VERSION=2.0.0
SINGBOX_VERSION=1.14.4
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
服务端一个 sing-box 进程；客户端一个 sing-box 配置，无需 Xray。

sudo bash snell-reality-native.sh install --server VPS公网IP
sudo snell-reality-native {show|check|status|start|stop|restart|logs|upgrade|uninstall}

首次安装选项：
  --server HOST       公网 IP / 域名；留空尝试自动检测
  --port PORT         REALITY TCP 入口，默认 443
  --sni DOMAIN        目标站点，默认 www.cloudflare.com:443
  --listen IP         默认 0.0.0.0，IPv6 地址默认 ::
  --snell-port PORT   Snell 回环监听端口，默认 23456
  --socks-port PORT   桌面客户端本地代理端口，默认 1080
  --profile-url URL   可选：你自己的 HTTPS 完整配置下载地址

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
            --server|--port|--sni|--listen|--snell-port|--socks-port|--profile-url|--url)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "$1 缺少参数。"
                case "$1" in
                    --server) SERVER=$2 ;;
                    --port) PORT=$2 ;;
                    --sni) SNI=$2 ;;
                    --listen) LISTEN=$2 ;;
                    --snell-port) SNELL_PORT=$2 ;;
                    --socks-port) SOCKS_PORT=$2 ;;
                    --profile-url|--url) PROFILE_URL=$2 ;;
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
        info '原生版已安装，保留现有配置。'; show_config; return 0
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
    info '原生版安装完成，已设置开机启动。'
    show_config
}

show_config() {
    require_install
    local url
    info "服务端 / 客户端使用 sing-box $SINGBOX_VERSION；客户端无需 Xray 桥接。"
    printf '入口：%s，TCP %s\n' "$(jq -r .server "$CONFIG_DIR/state.json")" "$(jq -r .port "$CONFIG_DIR/state.json")"
    printf '完整客户端配置（含凭据）：\n  %s/clients/client-mixed.json\n  %s/clients/client-tun.json\n' "$CONFIG_DIR" "$CONFIG_DIR"
    printf '桌面 SOCKS/HTTP 使用 mixed；支持 TUN 配置的客户端可导入 tun 文件。\n'
    url=$(jq -r '.profile_url // ""' "$CONFIG_DIR/state.json")
    if [[ -n $url ]]; then
        printf '远程配置导入链接（请先把 client-tun.json 部署到指定的 HTTPS 地址）：\n'
        make_import_link "$url"
    else
        printf '可直接导入完整 JSON 文件；使用 HTTPS 配置地址可生成 sing-box 远程配置导入链接。\n'
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
        install|upgrade|show|check|status|start|stop|restart|logs|uninstall) ;;
        *) usage; die "未知命令：$action" ;;
    esac
    if [[ $action != install && $# -gt 0 ]]; then
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
        install|upgrade) deploy "$action" ;;
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
