#!/system/bin/sh
set -eu

log_msg() {
  if command -v log >/dev/null 2>&1; then
    log -t "everest-adb-activator" "$1"
  else
    echo "[everest-adb-activator] $1"
  fi
}

sleep "${ADB_ACTIVATOR_DELAY_SECONDS:-12}"

adb_port="${EVEREST_ADB_PORT:-43219}"

if ! command -v setprop >/dev/null 2>&1; then
  log_msg "setprop command not found."
  exit 1
fi

setprop service.adb.tcp.port "$adb_port"

if command -v stop >/dev/null 2>&1 && command -v start >/dev/null 2>&1; then
  if stop adbd; then
    start adbd || log_msg "Failed to start adbd after stop."
  else
    log_msg "Failed to stop adbd; attempting start anyway."
    start adbd || log_msg "Failed to start adbd."
  fi
  log_msg "ADB TCP port configured: ${adb_port}."
else
  log_msg "stop/start command not found; ADB daemon restart skipped."
fi
