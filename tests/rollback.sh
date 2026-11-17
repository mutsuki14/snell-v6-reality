#!/usr/bin/env bash
# Exercise the real snapshot/rollback functions in a temp directory; mock only
# systemctl/userdel. Never touch host services, users, /etc or /usr/local.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../snell-reality.sh
source "$SCRIPT_DIR/snell-reality.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
CONFIG_DIR=$TEST_DIR/config
BIN_DIR=$TEST_DIR/bin
UNIT_DIR=$TEST_DIR/units
MANAGER=$TEST_DIR/manager
WORK_DIR=$TEST_DIR/work
mkdir -p "$CONFIG_DIR/clients" "$BIN_DIR" "$UNIT_DIR" "$WORK_DIR"
printf '{"schema":1,"psk":"original-secret"}\n' > "$CONFIG_DIR/state.json"
printf 'original client\n' > "$CONFIG_DIR/clients/client.json"
printf 'original snell\n' > "$BIN_DIR/snell-server"
printf 'original xray\n' > "$BIN_DIR/xray"
printf 'original manager\n' > "$MANAGER"
printf 'original unit\n' > "$UNIT_DIR/$SNELL_UNIT"
printf 'original unit\n' > "$UNIT_DIR/$XRAY_UNIT"

systemctl() {
    printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"
    case "$1" in
        is-active|is-enabled) [[ ${*: -1} == "$SNELL_UNIT" ]] ;;
        *) return 0 ;;
    esac
}
userdel() { printf '%s\n' "$*" >> "$TEST_DIR/userdel.log"; }

snapshot_install
[[ $HAD_INSTALL == 1 && $OLD_SNELL_ACTIVE == 1 && $OLD_XRAY_ACTIVE == 0 ]]
[[ $OLD_SNELL_ENABLED == 1 && $OLD_XRAY_ENABLED == 0 ]]
printf 'broken config\n' > "$CONFIG_DIR/state.json"
printf 'new binary\n' > "$BIN_DIR/snell-server"
printf 'new manager\n' > "$MANAGER"
printf 'new unit\n' > "$UNIT_DIR/$XRAY_UNIT"
rollback
diff -r "$WORK_DIR/backup/config" "$CONFIG_DIR"
diff -r "$WORK_DIR/backup/bin" "$BIN_DIR"
cmp "$WORK_DIR/backup/manager" "$MANAGER"
cmp "$WORK_DIR/backup/$SNELL_UNIT" "$UNIT_DIR/$SNELL_UNIT"
cmp "$WORK_DIR/backup/$XRAY_UNIT" "$UNIT_DIR/$XRAY_UNIT"
grep -Fxq "start $SNELL_UNIT" "$TEST_DIR/systemctl.log"
if grep -Fxq "start $XRAY_UNIT" "$TEST_DIR/systemctl.log"; then
    printf 'Rollback started an originally inactive service.\n' >&2
    exit 1
fi
[[ ! -e $TEST_DIR/userdel.log ]]
printf 'PASS failed upgrade restores files, credentials and previous service states\n'

# A failed restore must return failure, leaving the original backup recoverable.
(
    cp() { return 1; }
    result=0
    rollback || result=$?
    [[ $result != 0 && -f $WORK_DIR/backup/config/state.json ]]
)
rollback
diff -r "$WORK_DIR/backup/config" "$CONFIG_DIR"
printf 'PASS restore failure is reported and original backup remains usable\n'

HAD_INSTALL=0
CREATED_USER=1
rollback
[[ ! -e $CONFIG_DIR && ! -e $BIN_DIR && ! -e $MANAGER ]]
[[ ! -e $UNIT_DIR/$SNELL_UNIT && ! -e $UNIT_DIR/$XRAY_UNIT ]]
grep -Fxq "$SERVICE_USER" "$TEST_DIR/userdel.log"
printf 'PASS failed fresh install removes only its dedicated files and account\n'

# EXIT cleanup must preserve the failure status and remove temporary secrets.
mkdir "$TEST_DIR/cleanup"
rc=0
bash -c 'source "$1"; WORK_DIR=$2; trap cleanup EXIT; exit 7' \
    test "$SCRIPT_DIR/snell-reality.sh" "$TEST_DIR/cleanup" || rc=$?
[[ $rc == 7 && ! -e $TEST_DIR/cleanup ]]
printf 'PASS cleanup preserves failure status and removes temporary files\n'
