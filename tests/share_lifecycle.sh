#!/usr/bin/env bash
# Simulate service management; no system accounts, ports or production paths are touched.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_SCRIPT=$SCRIPT_DIR/tests/share_lifecycle.sh
# shellcheck source=../snell-reality-native.sh
source "$SCRIPT_DIR/snell-reality-native.sh"
RUN_MODE=${1:-parent}
TEST_DIR=${2:-$(mktemp -d)}
CONFIG_DIR=$TEST_DIR/proxy
BIN_DIR=$TEST_DIR/proxy-bin
UNIT_DIR=$TEST_DIR/units
MANAGER=$TEST_DIR/manager
SHARE_CONFIG_DIR=$TEST_DIR/share-config
SHARE_BIN_DIR=$TEST_DIR/share-bin
SHARE_DATA_DIR=$TEST_DIR/share-data
WORK_DIR=$TEST_DIR/work-$RUN_MODE

install_dependencies() { :; }
port_free() { :; }
getent() { return 1; }
useradd() { printf '%s\n' "$*" >> "$TEST_DIR/useradd.log"; }
userdel() { printf '%s\n' "$*" >> "$TEST_DIR/userdel.log"; }
sleep() { :; }
systemctl() {
    printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"
    [[ $RUN_MODE != start-fail || $* != "enable --now $SHARE_UNIT" ]]
}
install() {
    local args=()
    # Keep real file installation and modes, but require no root or dedicated group.
    while (($#)); do
        case "$1" in
            -o|-g) shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    command install "${args[@]}"
}
download_share_binary() {
    printf 'download\n' >> "$TEST_DIR/download.log"
    printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/caddy"
    chmod 0755 "$WORK_DIR/caddy"
}
probe_share_https() { [[ $RUN_MODE == ready ]]; }

if [[ $RUN_MODE != parent ]]; then
    mkdir -p "$WORK_DIR"
    trap cleanup EXIT
    case "$RUN_MODE" in
        start-fail|pending|ready) enable_share; show_config ;;
        off) remove_share ;;
        *) exit 2 ;;
    esac
    exit 0
fi

trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$CONFIG_DIR/clients" "$BIN_DIR" "$UNIT_DIR"
printf '{"schema":2,"engine":"sing-box","server":"8.8.8.8","port":443,"snell_port":23456,"private_key":"fixture-secret","profile_url":""}\n' > "$CONFIG_DIR/state.json"
printf 'fixture server configuration\n' > "$CONFIG_DIR/server.json"
printf '{"profile":"tun","password":"fixture-secret"}\n' > "$CONFIG_DIR/clients/client-tun.json"
printf '{"profile":"mixed","password":"fixture-secret"}\n' > "$CONFIG_DIR/clients/client-mixed.json"
cp -a "$CONFIG_DIR" "$TEST_DIR/original-proxy"
rc=0
bash "$TEST_SCRIPT" start-fail "$TEST_DIR" > "$TEST_DIR/start-fail.log" 2>&1 || rc=$?
[[ $rc != 0 && ! -e $SHARE_CONFIG_DIR && ! -e $SHARE_BIN_DIR && ! -e $SHARE_DATA_DIR && ! -e $UNIT_DIR/$SHARE_UNIT ]]
diff -r "$TEST_DIR/original-proxy" "$CONFIG_DIR"
grep -Fxq "$SHARE_USER" "$TEST_DIR/userdel.log"
printf 'PASS failed sharing startup removes only its dedicated files and account\n'
rm "$TEST_DIR/download.log" "$TEST_DIR/useradd.log"
rc=0
bash "$TEST_SCRIPT" pending "$TEST_DIR" > "$TEST_DIR/pending.log" 2>&1 || rc=$?
[[ $rc != 0 && -f $SHARE_CONFIG_DIR/share.json && -x $MANAGER && -f $UNIT_DIR/$SHARE_UNIT ]]
[[ -z $(jq -r .profile_url "$CONFIG_DIR/state.json") ]]
if grep -q 'sing-box://import-remote-profile' "$TEST_DIR/pending.log"; then exit 1; fi
diff -r "$TEST_DIR/original-proxy" "$CONFIG_DIR"
token=$(jq -r .token "$SHARE_CONFIG_DIR/share.json")
printf 'PASS pending certificate retains the issuer and proxy without printing a usable link\n'
bash "$TEST_SCRIPT" ready "$TEST_DIR" > "$TEST_DIR/ready.log" 2>&1
[[ $(jq -r .token "$SHARE_CONFIG_DIR/share.json") == "$token" ]]
[[ $(wc -l < "$TEST_DIR/download.log") == 1 && $(wc -l < "$TEST_DIR/useradd.log") == 1 ]]
[[ $(jq -r .profile_url "$CONFIG_DIR/state.json") == "https://8.8.8.8:8443/$token/client-tun.json" ]]
grep -q '^sing-box://import-remote-profile?' "$TEST_DIR/ready.log"
cmp "$CONFIG_DIR/clients/client-tun.json" "$SHARE_DATA_DIR/profiles/client-tun.json"
[[ $(stat -c '%a' "$SHARE_DATA_DIR/profiles/client-tun.json") == 640 ]]
[[ $(stat -c '%a' "$SHARE_CONFIG_DIR/share.json") == 600 ]]
printf 'PASS retry reuses token and installation, publishes both profiles and displays the link\n'
bash "$TEST_SCRIPT" off "$TEST_DIR" > "$TEST_DIR/off.log" 2>&1
[[ ! -e $SHARE_CONFIG_DIR && ! -e $SHARE_BIN_DIR && ! -e $SHARE_DATA_DIR && ! -e $UNIT_DIR/$SHARE_UNIT ]]
jq -S . "$CONFIG_DIR/state.json" > "$TEST_DIR/state-after"
jq -S . "$TEST_DIR/original-proxy/state.json" > "$TEST_DIR/state-before"
cmp "$TEST_DIR/state-before" "$TEST_DIR/state-after"
cmp "$TEST_DIR/original-proxy/server.json" "$CONFIG_DIR/server.json"
diff -r "$TEST_DIR/original-proxy/clients" "$CONFIG_DIR/clients"
if grep -Fq "$UNIT" "$TEST_DIR/systemctl.log"; then exit 1; fi
printf 'PASS share-off clears the owned URL and preserves proxy files and service state\n'
