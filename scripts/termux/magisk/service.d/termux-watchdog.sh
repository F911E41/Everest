#!/system/bin/sh
set -eu

# Wait for 18 seconds to ensure all services are up
sleep 18

termux_activity="com.termux/.HomeActivity"
watchdog_interval="${TERMUX_WATCHDOG_INTERVAL_SECONDS:-24}"
restart_delay="${TERMUX_WATCHDOG_RESTART_DELAY_SECONDS:-18}"

start_termux() {
  am start -n "$termux_activity" >/dev/null 2>&1 || log_msg "Failed to start Termux activity."
}

# Logging function
log_msg() {
  if command -v log >/dev/null 2>&1; then
    log -t "everest-termux-watchdog" "$1"
  else
    echo "[everest-termux-watchdog] $1"
  fi
}

# First-time start
start_termux

# Ensure Termux is running
# Protect Termux from being killed by the system
(
  while true; do
    pids="$(pidof com.termux 2>/dev/null || true)"
    if [ -z "$pids" ]; then
      log_msg "Termux app not running, starting..."
      start_termux
      sleep "$restart_delay"
    else
      for pid in $pids; do
        [ -w "/proc/${pid}/oom_adj" ] && echo -17 >"/proc/${pid}/oom_adj" 2>/dev/null || true
        [ -w "/proc/${pid}/oom_score_adj" ] && echo -1000 >"/proc/${pid}/oom_score_adj" 2>/dev/null || true
      done
    fi

    sleep "$watchdog_interval"
  done
) &
