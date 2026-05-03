#!/data/data/com.termux/files/usr/bin/sh
set -eu

log_msg() {
  printf '[%s] [termux-init] %s\n' "$(date '+%H:%M:%S')" "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Prevent device sleep
if has_cmd termux-wake-lock; then
  termux-wake-lock || log_msg "Failed to acquire wake lock."
fi

# Start SSHD immediately when available.
if has_cmd sshd; then
  sshd || log_msg "Failed to start sshd directly; watchdog will retry via sv."
else
  log_msg "sshd command not found."
fi

watchdog_interval="${WATCHDOG_INTERVAL_SECONDS:-14}"

# Service watchdog
while true; do
  if ! has_cmd sv; then
    log_msg "sv command not found; retrying..."
    sleep "$watchdog_interval"
    continue
  fi

  for svc in sshd mysqld; do
    status="$(sv status "$svc" 2>/dev/null || true)"
    case "$status" in
    run:*) ;;
    *)
      sv up "$svc" >/dev/null 2>&1 || sv restart "$svc" >/dev/null 2>&1 || log_msg "Failed to recover service: $svc"
      ;;
    esac
  done
  sleep "$watchdog_interval"
done
