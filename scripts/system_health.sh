#!/usr/bin/env bash
# system_health.sh - collect basic host health metrics, log them, and warn on thresholds.
#
# Exit codes: 0 = healthy, 1 = warning (a threshold exceeded), 2 = critical
# (a metric is >= the critical threshold, default 95%), 3 = usage/runtime error.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"

# ----------------------------------------------------------------- defaults
DISK_THRESHOLD=80
CPU_THRESHOLD=90
MEM_THRESHOLD=85
CRITICAL_THRESHOLD=95
LOG_FILE="${HEALTH_LOG_FILE:-./health_log.txt}"
MAX_LOG_BYTES=$((1024 * 1024)) # rotate at 1 MiB
MAX_LOG_FILES=5                # keep health_log.txt.1 .. .5
OUTPUT_JSON=false
QUIET=false
WEBHOOK_URL="${HEALTH_WEBHOOK_URL:-}" # optional Slack/Discord-compatible webhook

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Collect CPU, memory, disk (all mounted filesystems), load average and the top 5
processes by memory. Appends a timestamped entry to the log file and prints
[WARNING] / [CRITICAL] lines when thresholds are exceeded.

Options:
  --cpu N          CPU usage warning threshold in % (default: ${CPU_THRESHOLD})
  --mem N          Memory usage warning threshold in % (default: ${MEM_THRESHOLD})
  --disk N         Disk usage warning threshold in % per filesystem (default: ${DISK_THRESHOLD})
  --critical N     Any metric at or above N% is CRITICAL (default: ${CRITICAL_THRESHOLD})
  --json           Write the log entry (and stdout) as a single JSON line
  --log-file PATH  Log file (default: ${LOG_FILE}; env HEALTH_LOG_FILE)
  --max-bytes N    Rotate the log when it exceeds N bytes (default: ${MAX_LOG_BYTES})
  --keep N         Number of rotated logs to keep (default: ${MAX_LOG_FILES})
  -q, --quiet      Only print warnings (still writes the log)
  -h, --help       Show this help
  -V, --version    Show version

Environment:
  HEALTH_WEBHOOK_URL  If set, warnings are POSTed to this Slack/Discord webhook.

Exit codes: 0 healthy, 1 warning, 2 critical, 3 error.
EOF
}

die() {
  echo "[ERROR] $*" >&2
  exit 3
}

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --cpu | --mem | --disk | --critical | --max-bytes | --keep)
        (($# >= 2)) || die "$1 requires a value"
        is_int "$2" || die "$1 expects a non-negative integer, got '$2'"
        case "$1" in
          --cpu) CPU_THRESHOLD=$2 ;;
          --mem) MEM_THRESHOLD=$2 ;;
          --disk) DISK_THRESHOLD=$2 ;;
          --critical) CRITICAL_THRESHOLD=$2 ;;
          --max-bytes) MAX_LOG_BYTES=$2 ;;
          --keep) MAX_LOG_FILES=$2 ;;
        esac
        shift 2
        ;;
      --log-file)
        (($# >= 2)) || die "--log-file requires a value"
        LOG_FILE=$2
        shift 2
        ;;
      --json) OUTPUT_JSON=true; shift ;;
      -q | --quiet) QUIET=true; shift ;;
      -h | --help) usage; exit 0 ;;
      -V | --version) echo "${SCRIPT_NAME} ${VERSION}"; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
}

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# ----------------------------------------------------------------- collectors
# CPU usage % over a 1s sample from /proc/stat (portable, no sysstat needed).
cpu_usage() {
  local -a a b
  read -r -a a < <(grep '^cpu ' /proc/stat)
  sleep 1
  read -r -a b < <(grep '^cpu ' /proc/stat)
  # fields: cpu user nice system idle iowait irq softirq steal
  local idle_a=$((a[4] + a[5])) idle_b=$((b[4] + b[5]))
  local total_a=0 total_b=0 i
  for i in 1 2 3 4 5 6 7 8; do
    total_a=$((total_a + a[i]))
    total_b=$((total_b + b[i]))
  done
  local dt=$((total_b - total_a)) di=$((idle_b - idle_a))
  if ((dt <= 0)); then echo 0; else echo $(((100 * (dt - di)) / dt)); fi
}

# Memory usage % based on MemAvailable (what the kernel considers reclaimable).
mem_usage() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END { if (t>0) printf "%d", (t-a)*100/t; else print 0 }' /proc/meminfo
}

# "mountpoint<TAB>used%" for every real mounted filesystem.
disk_usage() {
  df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null |
    awk 'NR>1 && $5 ~ /%$/ { gsub("%","",$5); printf "%s\t%s\n", $6, $5 }'
}

load_average() { cut -d' ' -f1-3 /proc/loadavg; }

top_processes() {
  ps -eo pid=,comm=,%mem=,rss= --sort=-%mem | head -n 5 | awk '{printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4}'
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/ }
  s=${s//$'\n'/ }
  printf '%s' "$s"
}

# ----------------------------------------------------------------- log rotation
rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size=$(wc -c <"$LOG_FILE")
  ((size < MAX_LOG_BYTES)) && return 0
  local i
  rm -f -- "${LOG_FILE}.${MAX_LOG_FILES}"
  for ((i = MAX_LOG_FILES - 1; i >= 1; i--)); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f -- "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
  done
  mv -f -- "$LOG_FILE" "${LOG_FILE}.1"
}

notify_webhook() {
  [[ -n "$WEBHOOK_URL" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local text
  text=$(json_escape "$1")
  # "content" is Discord's field, "text" is Slack's; each ignores the other.
  curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "{\"content\":\"${text}\",\"text\":\"${text}\"}" "$WEBHOOK_URL" >/dev/null 2>&1 ||
    echo "[ERROR] failed to send webhook notification" >&2
}

# ----------------------------------------------------------------- main
main() {
  parse_args "$@"
  require awk df ps grep cut
  [[ -r /proc/stat && -r /proc/meminfo ]] || die "this script needs a Linux /proc filesystem"

  local ts host cpu mem load
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  host=$(hostname 2>/dev/null || echo unknown)
  cpu=$(cpu_usage)
  mem=$(mem_usage)
  load=$(load_average)

  local -a warnings=()
  local status=0

  check() { # name value threshold
    local name=$1 value=$2 threshold=$3
    if ((value >= CRITICAL_THRESHOLD)); then
      warnings+=("[CRITICAL] ${name} usage ${value}% >= critical ${CRITICAL_THRESHOLD}%")
      status=2
    elif ((value > threshold)); then
      warnings+=("[WARNING] ${name} usage ${value}% exceeds threshold ${threshold}%")
      ((status < 1)) && status=1
    fi
    return 0
  }

  check "CPU" "$cpu" "$CPU_THRESHOLD"
  check "Memory" "$mem" "$MEM_THRESHOLD"

  local disks_text="" disks_json="" mount pct
  while IFS=$'\t' read -r mount pct; do
    [[ -n "$mount" ]] || continue
    check "Disk ${mount}" "$pct" "$DISK_THRESHOLD"
    disks_text+="    ${mount}: ${pct}%"$'\n'
    disks_json+="${disks_json:+,}{\"mount\":\"$(json_escape "$mount")\",\"used_pct\":${pct}}"
  done < <(disk_usage)

  local procs_text="" procs_json="" pid comm pmem rss
  while IFS=$'\t' read -r pid comm pmem rss; do
    [[ -n "$pid" ]] || continue
    procs_text+="    ${pid} ${comm} ${pmem}% (${rss} KiB)"$'\n'
    procs_json+="${procs_json:+,}{\"pid\":${pid},\"command\":\"$(json_escape "$comm")\",\"mem_pct\":${pmem},\"rss_kib\":${rss}}"
  done < <(top_processes)

  local status_name
  case $status in 0) status_name=healthy ;; 1) status_name=warning ;; *) status_name=critical ;; esac

  local entry
  if [[ "$OUTPUT_JSON" == true ]]; then
    local warn_json="" w
    for w in "${warnings[@]+"${warnings[@]}"}"; do
      warn_json+="${warn_json:+,}\"$(json_escape "$w")\""
    done
    local l1 l5 l15
    read -r l1 l5 l15 <<<"$load"
    entry="{\"timestamp\":\"${ts}\",\"host\":\"$(json_escape "$host")\",\"status\":\"${status_name}\",\"cpu_pct\":${cpu},\"mem_pct\":${mem},\"load\":{\"1m\":${l1},\"5m\":${l5},\"15m\":${l15}},\"disks\":[${disks_json}],\"top_processes\":[${procs_json}],\"warnings\":[${warn_json}]}"
  else
    entry="=== ${ts} ${host} status=${status_name}
  CPU: ${cpu}%  Memory: ${mem}%  Load: ${load}
  Disks:
${disks_text}  Top 5 processes by memory (pid command %mem rss):
${procs_text}"
    if ((${#warnings[@]} > 0)); then
      entry+="$(printf '  %s\n' "${warnings[@]}")"$'\n'
    fi
  fi

  mkdir -p -- "$(dirname -- "$LOG_FILE")"
  rotate_log
  printf '%s\n' "$entry" >>"$LOG_FILE"

  if [[ "$QUIET" != true ]]; then
    printf '%s\n' "$entry"
  elif ((${#warnings[@]} > 0)); then
    printf '%s\n' "${warnings[@]}"
  fi
  if ((${#warnings[@]} > 0)); then
    printf '%s\n' "${warnings[@]}" >&2
    notify_webhook "$(printf '%s: %s' "$host" "$(IFS='; '; echo "${warnings[*]}")")"
  fi

  exit "$status"
}

main "$@"
