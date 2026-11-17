#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../snell-reality-native.sh
source "$SCRIPT_DIR/snell-reality-native.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
CONFIG_DIR=$TEST_DIR/config
BIN_DIR=$TEST_DIR/bin
UNIT_DIR=$TEST_DIR/units
MANAGER=$TEST_DIR/manager
WORK_DIR=$TEST_DIR/work
mkdir -p "$CONFIG_DIR/clients" "$BIN_DIR" "$UNIT_DIR" "$WORK_DIR"
printf '{"schema":2,"engine":"sing-box","psk":"original-secret"}\n' > "$CONFIG_DIR/state.json"
printf 'original client\n' > "$CONFIG_DIR/clients/client.json"
printf 'original binary\n' > "$BIN_DIR/sing-box"
printf 'original manager\n' > "$MANAGER"
printf 'original unit\n' > "$UNIT_DIR/$UNIT"
systemctl() { printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"; }
userdel() { printf '%s\n' "$*" >> "$TEST_DIR/userdel.log"; }
snapshot_install
[[ $HAD_INSTALL == 1 && $OLD_ACTIVE == 1 && $OLD_ENABLED == 1 ]]
printf 'broken config\n' > "$CONFIG_DIR/state.json"
printf 'new binary\n' > "$BIN_DIR/sing-box"
rollback
diff -r "$WORK_DIR/backup/config" "$CONFIG_DIR"
diff -r "$WORK_DIR/backup/bin" "$BIN_DIR"
cmp "$WORK_DIR/backup/manager" "$MANAGER"
cmp "$WORK_DIR/backup/unit" "$UNIT_DIR/$UNIT"
grep -Fxq "start $UNIT" "$TEST_DIR/systemctl.log"
[[ ! -e $TEST_DIR/userdel.log ]]
printf 'PASS native failed upgrade restores credentials, binaries, unit and service state\n'
(
    cp() { return 1; }
    result=0
    rollback || result=$?
    [[ $result != 0 && -f $WORK_DIR/backup/config/state.json ]]
)
rollback
diff -r "$WORK_DIR/backup/config" "$CONFIG_DIR"
printf 'PASS native restore failure preserves the recoverable original snapshot\n'
HAD_INSTALL=0
CREATED_USER=1
rollback
[[ ! -e $CONFIG_DIR && ! -e $BIN_DIR && ! -e $MANAGER && ! -e $UNIT_DIR/$UNIT ]]
grep -Fxq "$SERVICE_USER" "$TEST_DIR/userdel.log"
printf 'PASS native failed fresh install removes its dedicated artifacts\n'
mkdir "$TEST_DIR/cleanup"
rc=0
bash -c 'source "$1"; WORK_DIR=$2; trap cleanup EXIT; exit 7' \
    test "$SCRIPT_DIR/snell-reality-native.sh" "$TEST_DIR/cleanup" || rc=$?
[[ $rc == 7 && ! -e $TEST_DIR/cleanup ]]
printf 'PASS native cleanup preserves failure status and deletes temporary secrets\n'
