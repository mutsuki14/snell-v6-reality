#!/usr/bin/env bash
# Snell v6 unsafe-raw over VLESS + REALITY. Requires Bash 4+, systemd and root.
set -Eeuo pipefail
umask 077

SCRIPT_VERSION=1.0.0
SNELL_VERSION=6.0.0
XRAY_VERSION=26.11.9
CONFIG_DIR=/etc/snell-reality
BIN_DIR=/usr/local/lib/snell-reality
UNIT_DIR=/etc/systemd/system
MANAGER=/usr/local/sbin/snell-reality
SERVICE_USER=snell-reality
SNELL_UNIT=snell-reality-snell.service
XRAY_UNIT=snell-reality-xray.service
SERVER=''
SNI=www.cloudflare.com
PORT=443
SNELL_PORT=23456
CLIENT_PORT=23456
SOCKS_PORT=1080
LISTEN=''
ASSUME_YES=0
WORK_DIR=''
TRANSACTION=0
HAD_INSTALL=0
CREATED_USER=0
OLD_SNELL_ACTIVE=0
OLD_XRAY_ACTIVE=0
OLD_SNELL_ENABLED=0
OLD_XRAY_ENABLED=0

info() { printf '[+] %s\n' "$*"; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Snell v6（mode=unsafe-raw）+ VLESS / REALITY 一键安装

用法：sudo bash snell-reality.sh [命令] [选项]
命令：
  install      安装；默认命令，已安装时保留原配置
  upgrade      升级到本脚本固定的版本，保留密钥、地址和端口
  show         显示 Surge 配置及客户端配置文件位置（含凭据）
  check        检查配置、服务和监听端口
  status       查看服务状态
  start        启动两个服务
  stop         停止两个服务
  restart      检查配置后重启
  logs         显示最近日志并持续跟随（Ctrl-C 退出）
  uninstall    卸载本脚本创建的服务、程序和配置

仅用于首次 install 的选项：
  --server HOST       VPS 公网 IP 或域名；未指定时尝试自动检测
  --port PORT         REALITY TCP 入口，默认 443
  --sni DOMAIN        REALITY 目标域名，默认 www.cloudflare.com，目标端口 443
  --listen IP         公网监听地址，默认 0.0.0.0；IPv6 地址默认为 ::
  --snell-port PORT   VPS 上回环 Snell 端口，默认 23456
  --client-port PORT  本地 Xray 桥接端口，默认 23456
  --socks-port PORT   sing-box 客户端本地代理端口，默认 1080
  --yes               仅用于跳过卸载确认

示例：sudo bash snell-reality.sh install --server 你的VPS公网IP
支持：Debian 11+ / Ubuntu 22.04+，amd64 / arm64，systemd。
公网仅使用 REALITY TCP 端口。Snell 明文端口固定绑定 127.0.0.1。
EOF
}

require_root() { [[ $EUID -eq 0 ]] || die '请使用 sudo 或 root 执行。'; }
require_systemd() {
    if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null; then
        die '需要正在运行的 systemd；不支持普通 Docker 容器或 OpenRC。'
    fi
}

parse_options() {
    while (($#)); do
        case "$1" in
            --yes) ASSUME_YES=1; shift; continue ;;
            --server|--sni|--port|--listen|--snell-port|--client-port|--socks-port)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "$1 缺少参数。"
                case "$1" in
                    --server) SERVER=$2 ;;
                    --sni) SNI=$2 ;;
                    --port) PORT=$2 ;;
                    --listen) LISTEN=$2 ;;
                    --snell-port) SNELL_PORT=$2 ;;
                    --client-port) CLIENT_PORT=$2 ;;
                    --socks-port) SOCKS_PORT=$2 ;;
                esac
                shift 2 ;;
            *) die "未知选项：$1" ;;
        esac
    done
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
    for cmd in curl unzip jq openssl python3 ss flock useradd getent sha256sum timeout; do
        command -v "$cmd" >/dev/null || missing=1
    done
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing=1
    if ((missing)); then
        info '安装依赖……'
        apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            ca-certificates curl unzip jq openssl python3 iproute2 util-linux passwd coreutils
    fi
}

validate_options() {
    python3 - "$SERVER" "$SNI" "$PORT" "$SNELL_PORT" "$CLIENT_PORT" "$SOCKS_PORT" "$LISTEN" <<'PY'
import ipaddress, re, sys
server, sni, port, snell, client, socks, listen = sys.argv[1:]
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
for value in (port, snell, client, socks):
    if not re.fullmatch(r'[1-9][0-9]{0,4}', value) or int(value) > 65535:
        fail('端口必须是 1–65535 的十进制整数，不能带前导零。')
if port == snell:
    fail('REALITY 入口端口与 Snell 回环端口不能相同。')
if client == socks:
    fail('本地桥接端口与本地代理端口不能相同。')
if not address(listen) or address(listen).is_multicast:
    fail('--listen 必须是有效的本机 IP 或通配监听地址。')
PY
}

download() {
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --connect-timeout 15 --max-time 240 --retry 3 --retry-delay 2 \
        --output "$2" "$1"
}

select_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            SNELL_ARCH=amd64; XRAY_ARCH=64
            SNELL_SHA=8a9c4463ca87cfa5eaa37c6af0d37ab93ea275aa12391985bb2a375ca3abd7f2
            XRAY_SHA=b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82 ;;
        aarch64|arm64)
            SNELL_ARCH=aarch64; XRAY_ARCH=arm64-v8a
            SNELL_SHA=a0b2915cbc77dc3baf8fa069e741c20808d8a10c3a8a93e709a0a580645c3bd7
            XRAY_SHA=64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be ;;
        *) die "不支持的架构：$(uname -m)，需要 amd64 / arm64。" ;;
    esac
}

download_binaries() {
    select_arch
    mkdir -p "$WORK_DIR/bin"
    info "下载 Snell $SNELL_VERSION 与 Xray $XRAY_VERSION，并校验 SHA-256……"
    download "https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip" "$WORK_DIR/snell.zip"
    download "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip" "$WORK_DIR/xray.zip"
    printf '%s  %s\n' "$SNELL_SHA" "$WORK_DIR/snell.zip" "$XRAY_SHA" "$WORK_DIR/xray.zip" | sha256sum --check --status
    # Extract only the known members; never unpack arbitrary archive paths as root.
    unzip -p "$WORK_DIR/snell.zip" snell-server > "$WORK_DIR/bin/snell-server"
    unzip -p "$WORK_DIR/xray.zip" xray > "$WORK_DIR/bin/xray"
    chmod 0755 "$WORK_DIR/bin/"*
    "$WORK_DIR/bin/snell-server" --version > "$WORK_DIR/snell-version.log" 2>&1
    "$WORK_DIR/bin/xray" version > "$WORK_DIR/xray-version.log"
    grep -Fq "v$SNELL_VERSION" "$WORK_DIR/snell-version.log"
    grep -Fq "Xray $XRAY_VERSION " "$WORK_DIR/xray-version.log"
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

make_state() {
    local keys private public psk uuid sid
    keys=$("$WORK_DIR/bin/xray" x25519)
    private=$(awk '/^PrivateKey:/ {print $2}' <<< "$keys")
    public=$(awk '/^Password \(PublicKey\):/ {print $3} /^PublicKey:/ {print $2}' <<< "$keys")
    [[ $private =~ ^[A-Za-z0-9_-]{43}$ && $public =~ ^[A-Za-z0-9_-]{43}$ ]] || die '无法解析 Xray 密钥。'
    psk=$(openssl rand -hex 16)
    sid=$(openssl rand -hex 8)
    uuid=$("$WORK_DIR/bin/xray" uuid)
    jq -n --arg server "$SERVER" --arg sni "$SNI" --arg listen "$LISTEN" \
        --argjson port "$PORT" --argjson snell_port "$SNELL_PORT" \
        --argjson client_port "$CLIENT_PORT" --argjson socks_port "$SOCKS_PORT" \
        --arg psk "$psk" --arg uuid "$uuid" --arg private "$private" --arg public "$public" --arg sid "$sid" \
        --arg snell_version "$SNELL_VERSION" --arg xray_version "$XRAY_VERSION" \
        '{schema:1,server:$server,sni:$sni,listen:$listen,port:$port,snell_port:$snell_port,
          client_port:$client_port,socks_port:$socks_port,psk:$psk,uuid:$uuid,
          private_key:$private,public_key:$public,short_id:$sid,
          snell_version:$snell_version,xray_version:$xray_version}' > "$WORK_DIR/state.json"
}

render_configs() {
    local state=$1 out=$2
    mkdir -p "$out/clients"
    install -m 0600 "$state" "$out/state.json"
    jq -r '"[snell-server]\nlisten = 127.0.0.1:\(.snell_port)\npsk = \(.psk)\nmode = unsafe-raw\ndns-ip-preference = prefer-ipv4\n"' \
        "$state" > "$out/snell.conf"
    jq '{log:{loglevel:"warning"},
      inbounds:[{tag:"reality-in",listen:.listen,port:.port,protocol:"vless",
        settings:{clients:[{id:.uuid}],decryption:"none"},
        streamSettings:{network:"raw",security:"reality",realitySettings:{show:false,
          target:(.sni+":443"),xver:0,serverNames:[.sni],privateKey:.private_key,shortIds:[.short_id]}}}],
      outbounds:[{tag:"snell-loopback",protocol:"freedom",settings:{redirect:("127.0.0.1:"+(.snell_port|tostring)),
        finalRules:[{action:"allow",network:"tcp",ip:["127.0.0.1"],port:(.snell_port|tostring)},
                    {action:"block",delay:0}]}}],
      routing:{rules:[{type:"field",inboundTag:["reality-in"],outboundTag:"snell-loopback"}]}}
    ' "$state" > "$out/xray.json"
    # No Vision flow: this tunnel carries Snell frames, not directly TLS records.
    jq '{log:{loglevel:"warning"},
      inbounds:[{tag:"snell-local",listen:"127.0.0.1",port:.client_port,protocol:"dokodemo-door",
        settings:{address:"127.0.0.1",port:.snell_port,network:"tcp"}}],
      outbounds:[{tag:"reality-out",protocol:"vless",settings:{vnext:[{address:.server,port:.port,
        users:[{id:.uuid,encryption:"none"}]}]},streamSettings:{network:"raw",security:"reality",
        realitySettings:{fingerprint:"chrome",serverName:.sni,password:.public_key,shortId:.short_id}}}]}
    ' "$state" > "$out/clients/xray-bridge.json"
    jq '{log:{level:"warn"},
      inbounds:[{type:"mixed",tag:"local-proxy",listen:"127.0.0.1",listen_port:.socks_port}],
      outbounds:[{type:"snell",tag:"snell-out",server:"127.0.0.1",server_port:.client_port,
        version:6,psk:.psk,mode:"unsafe-raw",reuse:true}],
      route:{final:"snell-out"}}
    ' "$state" > "$out/clients/sing-box-via-bridge.json"
    jq -r '"# 添加到支持 Snell v6 的 Surge 的 [Proxy] 节；先在同一台电脑运行 xray-bridge.json。\nSnell-REALITY = snell, 127.0.0.1, \(.client_port), psk=\(.psk), version=6, mode=unsafe-raw, reuse=true\n\n# Surge Mac 开启增强模式时，将下面规则放在 [Rule] 节中兜底规则之前：\n# PROCESS-NAME,xray,DIRECT\n"' \
        "$state" > "$out/clients/surge-snippet.conf"
    chmod 0600 "$out/"*.* "$out/clients/"*
}

write_units() {
    local out=$1
    mkdir -p "$out"
    cat > "$out/$SNELL_UNIT" <<EOF
[Unit]
Description=Snell v6 unsafe-raw (loopback only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN_DIR/snell-server -c $CONFIG_DIR/snell.conf
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
    cat > "$out/$XRAY_UNIT" <<EOF
[Unit]
Description=REALITY transport for loopback Snell
After=network-online.target $SNELL_UNIT
Wants=network-online.target $SNELL_UNIT

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN_DIR/xray run -config $CONFIG_DIR/xray.json
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

check_xray_configs() {
    local binary=$1 config=$2
    "$binary" run -test -config "$config/xray.json" > /dev/null
    "$binary" run -test -config "$config/clients/xray-bridge.json" > /dev/null
}

require_install() {
    [[ -f $CONFIG_DIR/state.json ]] || die '尚未安装，请先执行 install。'
    [[ $(jq -r '.schema' "$CONFIG_DIR/state.json") == 1 ]] || die '安装状态格式不兼容。'
}

snapshot_install() {
    if [[ -e $CONFIG_DIR ]]; then
        HAD_INSTALL=1
        require_install
        mkdir -p "$WORK_DIR/backup"
        cp -a "$CONFIG_DIR" "$WORK_DIR/backup/config"
        cp -a "$BIN_DIR" "$WORK_DIR/backup/bin"
        cp -a "$MANAGER" "$WORK_DIR/backup/manager"
        cp -a "$UNIT_DIR/$SNELL_UNIT" "$UNIT_DIR/$XRAY_UNIT" "$WORK_DIR/backup/"
        systemctl is-active --quiet "$SNELL_UNIT" && OLD_SNELL_ACTIVE=1
        systemctl is-active --quiet "$XRAY_UNIT" && OLD_XRAY_ACTIVE=1
        systemctl is-enabled --quiet "$SNELL_UNIT" && OLD_SNELL_ENABLED=1
        systemctl is-enabled --quiet "$XRAY_UNIT" && OLD_XRAY_ENABLED=1
    fi
    return 0
}

rollback() {
    local failed=0
    printf '[错误] 部署失败，恢复部署前的专用服务及配置。\n' >&2
    systemctl disable --now "$XRAY_UNIT" "$SNELL_UNIT" >/dev/null 2>&1 || true
    rm -rf -- "$CONFIG_DIR" "$BIN_DIR" || failed=1
    rm -f -- "$MANAGER" "$UNIT_DIR/$SNELL_UNIT" "$UNIT_DIR/$XRAY_UNIT" || failed=1
    if ((HAD_INSTALL)); then
        cp -a "$WORK_DIR/backup/config" "$CONFIG_DIR" || failed=1
        cp -a "$WORK_DIR/backup/bin" "$BIN_DIR" || failed=1
        cp -a "$WORK_DIR/backup/manager" "$MANAGER" || failed=1
        cp -a "$WORK_DIR/backup/$SNELL_UNIT" "$WORK_DIR/backup/$XRAY_UNIT" "$UNIT_DIR/" || failed=1
    elif ((CREATED_USER)); then
        userdel "$SERVICE_USER" >/dev/null 2>&1 || failed=1
    fi
    systemctl daemon-reload || failed=1
    if ((HAD_INSTALL)); then
        if ((OLD_SNELL_ENABLED)); then systemctl enable "$SNELL_UNIT" >/dev/null 2>&1 || failed=1; fi
        if ((OLD_XRAY_ENABLED)); then systemctl enable "$XRAY_UNIT" >/dev/null 2>&1 || failed=1; fi
        if ((OLD_SNELL_ACTIVE)); then systemctl start "$SNELL_UNIT" || failed=1; fi
        if ((OLD_XRAY_ACTIVE)); then systemctl start "$XRAY_UNIT" || failed=1; fi
    fi
    return "$failed"
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

check_services() {
    # systemctl with multiple arguments succeeds if *any* unit is active; check each.
    systemctl is-active --quiet "$SNELL_UNIT" || return 1
    systemctl is-active --quiet "$XRAY_UNIT" || return 1
    python3 - "$CONFIG_DIR/state.json" <<'PY'
import json, socket, subprocess, sys
state = json.load(open(sys.argv[1]))
port = state['snell_port']
lines = subprocess.check_output(['ss','-H','-ltn','sport = :' + str(port)], text=True).splitlines()
if not lines or any(line.split()[3] != '127.0.0.1:' + str(port) for line in lines):
    sys.exit('Snell 未监听或未严格绑定到 127.0.0.1。')
host = state['listen']
host = {'0.0.0.0':'127.0.0.1','::':'::1'}.get(host, host)
for address, value in [('127.0.0.1', port), (host, state['port'])]:
    with socket.create_connection((address, value), timeout=2):
        pass
PY
}

deploy() {
    local action=$1 path self_source
    install_dependencies
    if [[ $action == install && -f $CONFIG_DIR/state.json ]]; then
        info '已安装，保留原配置。使用 upgrade 更新程序，使用 show 查看配置。'
        show_config
        return 0
    fi
    if [[ $action == upgrade ]]; then require_install; fi
    if [[ $action == install ]]; then
        for path in "$CONFIG_DIR" "$BIN_DIR" "$MANAGER" "$UNIT_DIR/$SNELL_UNIT" "$UNIT_DIR/$XRAY_UNIT"; do
            [[ ! -e $path && ! -L $path ]] || die "已有文件 $path，拒绝覆盖。"
        done
        getent passwd "$SERVICE_USER" >/dev/null && die "已有同名用户 $SERVICE_USER，拒绝接管。"
        getent group "$SERVICE_USER" >/dev/null && die "已有同名组 $SERVICE_USER，拒绝接管。"
        detect_server
        if [[ -z $LISTEN ]]; then
            if [[ $SERVER == *:* ]]; then LISTEN=::; else LISTEN=0.0.0.0; fi
        fi
        validate_options
        port_free "$PORT"
        port_free "$SNELL_PORT"
    else
        SNI=$(jq -r .sni "$CONFIG_DIR/state.json")
    fi
    check_target
    self_source=$(readlink -f -- "${BASH_SOURCE[0]}")
    [[ -f $self_source ]] || die '请先保存脚本到文件，再用 bash 执行；不支持直接管道执行。'
    WORK_DIR=$(mktemp -d /tmp/snell-reality.XXXXXXXX)
    download_binaries
    if [[ $action == install ]]; then
        make_state
    else
        jq --arg s "$SNELL_VERSION" --arg x "$XRAY_VERSION" '.snell_version=$s | .xray_version=$x' \
            "$CONFIG_DIR/state.json" > "$WORK_DIR/state.json"
    fi
    render_configs "$WORK_DIR/state.json" "$WORK_DIR/config"
    check_xray_configs "$WORK_DIR/bin/xray" "$WORK_DIR/config"
    write_units "$WORK_DIR/units"
    # Stage the executing script first: upgrade may be invoked via MANAGER itself.
    install -m 0755 "$self_source" "$WORK_DIR/manager"
    snapshot_install
    TRANSACTION=1
    if (( ! HAD_INSTALL )); then
        useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
        CREATED_USER=1
    else
        systemctl stop "$XRAY_UNIT" "$SNELL_UNIT"
    fi
    install -d -m 0755 "$BIN_DIR"
    install -m 0755 "$WORK_DIR/bin/snell-server" "$WORK_DIR/bin/xray" "$BIN_DIR/"
    install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"
    install -m 0600 "$WORK_DIR/config/state.json" "$CONFIG_DIR/state.json"
    install -m 0640 -o root -g "$SERVICE_USER" "$WORK_DIR/config/snell.conf" "$WORK_DIR/config/xray.json" "$CONFIG_DIR/"
    install -d -m 0700 "$CONFIG_DIR/clients"
    install -m 0600 "$WORK_DIR/config/clients/"* "$CONFIG_DIR/clients/"
    install -m 0644 "$WORK_DIR/units/"* "$UNIT_DIR/"
    install -m 0755 "$WORK_DIR/manager" "$MANAGER"
    systemctl daemon-reload
    systemctl enable "$SNELL_UNIT" "$XRAY_UNIT" >/dev/null
    systemctl start "$SNELL_UNIT" "$XRAY_UNIT"
    local healthy=0 attempt
    for ((attempt=0; attempt<10; attempt++)); do
        if check_services >/dev/null 2>&1; then healthy=1; break; fi
        sleep 1
    done
    ((healthy)) || die '服务未能启动；请查看 journalctl 中的错误。'
    # A process can bind and crash immediately: require a second successful observation.
    sleep 2
    check_services
    TRANSACTION=0
    info '安装完成，已设置开机启动。'
    show_config
}

show_config() {
    require_install
    local entry_port
    entry_port=$(jq -r .port "$CONFIG_DIR/state.json")
    info "服务器：$(jq -r .server "$CONFIG_DIR/state.json")，REALITY TCP 端口：$entry_port"
    cat "$CONFIG_DIR/clients/surge-snippet.conf"
    printf '\n客户端文件（包含凭据，仅交给可信客户端）：\n  %s\n  %s\n' \
        "$CONFIG_DIR/clients/xray-bridge.json" "$CONFIG_DIR/clients/sing-box-via-bridge.json"
    printf '客户端须运行 Xray %s 桥接；Surge / sing-box 通过桥接连接，不能直接连接公网 Snell。\n' "$XRAY_VERSION"
    printf '\n请在 VPS 防火墙和云安全组放行 TCP %s；无需开放 Snell 回环端口或入站 UDP。\n' "$entry_port"
    printf '管理命令：sudo snell-reality {show|check|status|restart|logs|upgrade|uninstall}\n'
}

uninstall() {
    require_install
    if (( ! ASSUME_YES )); then
        local answer
        printf '将删除 Snell/REALITY 专用服务、客户端配置和全部密钥。输入 yes 继续：' > /dev/tty
        read -r answer < /dev/tty
        [[ $answer == yes ]] || { info '取消卸载。'; return 0; }
    fi
    systemctl disable --now "$XRAY_UNIT" "$SNELL_UNIT"
    rm -f -- "$UNIT_DIR/$SNELL_UNIT" "$UNIT_DIR/$XRAY_UNIT"
    rm -rf -- "$CONFIG_DIR" "$BIN_DIR"
    rm -f -- "$MANAGER"
    systemctl daemon-reload
    systemctl reset-failed "$SNELL_UNIT" "$XRAY_UNIT" >/dev/null 2>&1 || true
    userdel "$SERVICE_USER"
    info '卸载完成；系统依赖和防火墙规则保留。'
}

main() {
    local action=${1:-install}
    if (($#)); then shift; fi
    case "$action" in
        -h|--help|help) usage; return 0 ;;
        --version) printf '%s\n' "$SCRIPT_VERSION"; return 0 ;;
        install|upgrade|show|check|status|start|stop|restart|logs|uninstall) ;;
        *) usage; die "未知命令：$action" ;;
    esac
    if [[ $action != install && $# -gt 0 ]]; then
        [[ $action == uninstall && $# == 1 && $1 == --yes ]] || die '这些选项仅适用于首次 install。'
    fi
    parse_options "$@"
    require_root
    require_systemd
    # flock is part of util-linux on supported systems, required before dependency changes.
    command -v flock >/dev/null || die '缺少 flock，请先 apt-get install util-linux。'
    exec 9>/run/lock/snell-reality.lock
    flock -n 9 || die '另一个 snell-reality 命令正在运行。'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Avoid printing command expansions or secret values on failures.
    trap 'printf "[错误] 第 %s 行执行失败。\n" "$LINENO" >&2' ERR
    case "$action" in
        install|upgrade) deploy "$action" ;;
        show) show_config ;;
        check) require_install; check_xray_configs "$BIN_DIR/xray" "$CONFIG_DIR"; check_services; info '配置及本机服务检查通过。公网连通性仍需从客户端验证。' ;;
        status) require_install; systemctl --no-pager --full status "$SNELL_UNIT" "$XRAY_UNIT" ;;
        start) require_install; systemctl start "$SNELL_UNIT" "$XRAY_UNIT" ;;
        stop) require_install; systemctl stop "$XRAY_UNIT" "$SNELL_UNIT" ;;
        restart) require_install; check_xray_configs "$BIN_DIR/xray" "$CONFIG_DIR"; systemctl restart "$SNELL_UNIT" "$XRAY_UNIT"; sleep 2; check_services ;;
        logs) require_install; flock -u 9; journalctl -u "$SNELL_UNIT" -u "$XRAY_UNIT" --no-pager -n 80 -f ;;
        uninstall) uninstall ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
