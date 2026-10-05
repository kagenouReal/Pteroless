#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG_FILE="/etc/default/pteroless-resource-agent"
RUNTIME_DIR="/run/pteroless-resource-agent"
PID_FILE="${RUNTIME_DIR}/agent.pid"
SOCKET_FILE="${RUNTIME_DIR}/agent.sock"
LOG_FILE="/var/log/pteroless/resource-agent.log"
AGENT_FILE="/usr/local/lib/pteroless/resource_agent.py"
fail() {
printf '[pteroless-resource-agent] %s\n' "$1" >&2
exit 1
}
[[ "${EUID}" -eq 0 ]] || fail "Run this command as root."
[[ -r "$CONFIG_FILE" ]] || fail "Missing configuration: ${CONFIG_FILE}"
set -a
source "$CONFIG_FILE"
set +a
: "${PTEROLESS_ALLOWED_UIDS:?Missing allowed panel UIDs}"
: "${PTEROLESS_STORAGE_ROOT:?Missing server storage path}"
: "${PTEROLESS_CGROUP_ROOT:?Missing cgroup root}"
PYTHON_BIN="${PTEROLESS_PYTHON:-/usr/bin/python3}"
case "$PTEROLESS_CGROUP_ROOT" in
/sys/fs/cgroup/*)
;;
*)
fail "The cgroup root must be inside /sys/fs/cgroup."
;;
esac

agent_is_running() {
[[ -s "$PID_FILE" ]] || return 1
local pid
pid="$(<"$PID_FILE")"
[[ "$pid" =~ ^[0-9]+$ ]] || return 1
kill -0 "$pid" 2>/dev/null || return 1
tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null | grep -Fq -- "$AGENT_FILE"
}

case "${1:-status}" in
start)
mkdir -p "$RUNTIME_DIR" "$(dirname "$LOG_FILE")" /var/lib/pteroless-resource-agent
chown root:pteroless "$RUNTIME_DIR"
chmod 0750 "$RUNTIME_DIR"
for controller in cpu memory; do
grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control \
|| fail "The host has not delegated the ${controller} cgroup controller."
done
mkdir -p "$PTEROLESS_CGROUP_ROOT"
if agent_is_running; then
printf '[pteroless-resource-agent] Already running (pid %s).\n' "$(<"$PID_FILE")"
exit 0
fi
rm -f "$PID_FILE"
[[ -r "$AGENT_FILE" ]] || fail "Missing agent: ${AGENT_FILE}"
nohup "$PYTHON_BIN" -u "$AGENT_FILE" \
--socket "$SOCKET_FILE" \
--socket-group pteroless \
--allowed-uids "$PTEROLESS_ALLOWED_UIDS" \
--storage-root "$PTEROLESS_STORAGE_ROOT" \
--cgroup-root "$PTEROLESS_CGROUP_ROOT" \
>>"$LOG_FILE" 2>&1 </dev/null &
printf '%s\n' "$!" >"$PID_FILE"
chmod 0640 "$PID_FILE"
for _ in $(seq 1 50); do
if agent_is_running && [[ -S "$SOCKET_FILE" ]]; then
printf '[pteroless-resource-agent] Started (pid %s).\n' "$(<"$PID_FILE")"
exit 0
fi
sleep 0.1
done
pid="$(<"$PID_FILE")"
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
kill "$pid" 2>/dev/null || true
fi
rm -f "$PID_FILE"
fail "Agent failed to start; see ${LOG_FILE}."
;;
stop)
if ! agent_is_running; then
rm -f "$PID_FILE"
printf '[pteroless-resource-agent] Not running.\n'
exit 0
fi
pid="$(<"$PID_FILE")"
kill "$pid"
for _ in $(seq 1 50); do
if ! kill -0 "$pid" 2>/dev/null; then
rm -f "$PID_FILE"
printf '[pteroless-resource-agent] Stopped.\n'
exit 0
fi
sleep 0.1
done
fail "Agent did not stop within 5 seconds."
;;
status)
if agent_is_running && [[ -S "$SOCKET_FILE" ]]; then
printf '[pteroless-resource-agent] Running (pid %s).\n' "$(<"$PID_FILE")"
exit 0
fi
printf '[pteroless-resource-agent] Not running.\n'
exit 1
;;
*)
fail "Usage: pteroless-resource-agent {start|stop|status}"
;;
esac
