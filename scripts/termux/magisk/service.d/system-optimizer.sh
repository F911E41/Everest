#!/system/bin/sh

log_msg() {
  if command -v log >/dev/null 2>&1; then
    log -t "everest-system-optimizer" "$1"
  else
    echo "[everest-system-optimizer] $1"
  fi
}

write_if_writable() {
  target="$1"
  value="$2"
  if [ -w "$target" ]; then
    echo "$value" >"$target" 2>/dev/null || true
    return 0
  fi
  return 1
}

# Disable Doze mode
dumpsys deviceidle disable

# Set CPU governor to performance for all CPUs
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  gov_file="$cpu/cpufreq/scaling_governor"
  write_if_writable "$gov_file" performance || true
done

# Set I/O scheduler to noop/none depending on availability
for blockdev in /sys/block/*/queue/scheduler; do
  [ -f "$blockdev" ] || continue
  schedulers="$(cat "$blockdev" 2>/dev/null || true)"
  case "$schedulers" in
  *noop*) write_if_writable "$blockdev" noop || true ;;
  *none*) write_if_writable "$blockdev" none || true ;;
  esac
done

# Set swappiness to somewhat higher value in order to prevent `OOM Killer` killing the processes
write_if_writable /proc/sys/vm/swappiness 80 || true

# Set the CPU governor for the moderate cpuset
write_if_writable /sys/devices/system/cpu/cpufreq/policy0/scaling_governor performance || true

log_msg "System optimizer applied."
