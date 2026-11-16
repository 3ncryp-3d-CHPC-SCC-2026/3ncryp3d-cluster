#!/bin/bash
# power-monitor.sh - log power draw and temperatures for all three nodes
# while a benchmark runs, and warn at the report's 75 C throttling line.
#
# Reads each node's BMC (HPE iLO 6) over IPMI-over-LAN, so it never touches
# the nodes' CPUs and can run from node3 or a laptop on the iLO network.
#
# Usage:
#   cp tools/ilo.env.example tools/ilo.env   # iLO IPs + monitoring user
#   tools/power-monitor.sh [-i SECONDS] [-o FILE.csv] [-t WARN_C] [-- cmd ...]
#
#   -i  sample interval in seconds (default 5)
#   -o  CSV output (default results/power-<date>.csv)
#   -t  temperature warning threshold in C (default 75)
#   -- cmd ...  run cmd (e.g. an mpirun) and stop logging when it exits;
#               without it, logs until Ctrl-C
#
# Needs: ipmitool. iLO must have "IPMI/DCMI over LAN" enabled
# (iLO web UI: Security > Access Settings). The iLO password is read from
# the file named by ILO_PASS_FILE, never from the command line.
#
# At exit it prints per-node peak/average watts and the hottest sensor,
# which is the evidence for the report's 233 W / 800 W PSU headroom claim.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL=5
OUT=""
WARN_C=75
CMD=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) INTERVAL="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    -t) WARN_C="$2"; shift 2 ;;
    --) shift; CMD=("$@"); break ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

ENV_FILE="${ILO_ENV:-$HERE/ilo.env}"
[[ -r "$ENV_FILE" ]] || { echo "missing $ENV_FILE (copy ilo.env.example)" >&2; exit 1; }
# shellcheck source-path=SCRIPTDIR source=ilo.env.example
. "$ENV_FILE"
command -v ipmitool >/dev/null || { echo "install ipmitool (apt install ipmitool)" >&2; exit 1; }
[[ -r "${ILO_PASS_FILE:-}" ]] || { echo "ILO_PASS_FILE not readable" >&2; exit 1; }
perm="$(stat -c %a "$ILO_PASS_FILE" 2>/dev/null || echo 600)"
[[ "$perm" == 600 || "$perm" == 400 ]] || echo "WARN: chmod 600 $ILO_PASS_FILE" >&2

OUT="${OUT:-results/power-$(date +%Y%m%d-%H%M%S).csv}"
mkdir -p "$(dirname "$OUT")"

ipmi() {
  local host="$1"; shift
  ipmitool -I lanplus -H "$host" -U "$ILO_USER" -f "$ILO_PASS_FILE" "$@" 2>/dev/null
}

# Instantaneous power in watts: DCMI first, then the "Power Meter" sensor.
read_watts() {
  local host="$1" w
  w="$(ipmi "$host" dcmi power reading | awk -F: '/Instantaneous power reading/ {gsub(/[^0-9]/,"",$2); print $2}')"
  if [[ -z "$w" ]]; then
    w="$(ipmi "$host" sdr type "Current" | awk -F'|' 'tolower($1) ~ /power meter/ {gsub(/[^0-9.]/,"",$5); print $5; exit}')"
  fi
  echo "${w:-}"
}

# Prints "max_temp_C|sensor_name|cpu_temp_C" from the temperature SDR.
read_temps() {
  local host="$1"
  ipmi "$host" sdr type Temperature | awk -F'|' '
    {
      name=$1; gsub(/^ +| +$/,"",name)
      val=$5; if (val !~ /degrees C/) next
      gsub(/[^0-9.]/,"",val); v=val+0
      if (v>max) {max=v; maxn=name}
      if (tolower(name) ~ /cpu/ && v>cpu) cpu=v
    }
    END { if (maxn=="") print "||"; else printf "%s|%s|%s\n", max, maxn, cpu }'
}

echo "timestamp,node,watts,max_temp_c,max_temp_sensor,cpu_temp_c" > "$OUT"
echo "logging ${#NODES[@]} nodes every ${INTERVAL}s to $OUT (warn at ${WARN_C} C)"

declare -A PEAK SUM N HOT HOTN
for n in "${!NODES[@]}"; do PEAK[$n]=0; SUM[$n]=0; N[$n]=0; HOT[$n]=0; HOTN[$n]=""; done

summary() {
  echo
  echo "== summary ($OUT) =="
  printf '%-6s %9s %9s %9s  %s\n' node peak_W avg_W hot_C hottest_sensor
  for n in $(printf '%s\n' "${!NODES[@]}" | sort); do
    local avg=0
    (( N[$n] > 0 )) && avg=$(( SUM[$n] / N[$n] ))
    printf '%-6s %9s %9s %9s  %s\n' "$n" "${PEAK[$n]}" "$avg" "${HOT[$n]}" "${HOTN[$n]}"
  done
  echo "PSU rating per node: 800 W"
}

CHILD=""
cleanup() {
  [[ -n "$CHILD" ]] && kill "$CHILD" 2>/dev/null || true
  summary
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ ${#CMD[@]} -gt 0 ]]; then
  "${CMD[@]}" &
  CHILD=$!
fi

while :; do
  ts="$(date -Is)"
  for n in $(printf '%s\n' "${!NODES[@]}" | sort); do
    host="${NODES[$n]}"
    w="$(read_watts "$host")"
    IFS='|' read -r tmax tname tcpu <<< "$(read_temps "$host")"
    echo "$ts,$n,${w},${tmax},\"${tname}\",${tcpu}" >> "$OUT"
    if [[ -n "$w" ]]; then
      w_int="${w%.*}"
      (( w_int > PEAK[$n] )) && PEAK[$n]=$w_int
      SUM[$n]=$(( SUM[$n] + w_int )); N[$n]=$(( N[$n] + 1 ))
    else
      echo "$ts WARN $n: no power reading from $host" >&2
    fi
    if [[ -n "$tmax" ]]; then
      t_int="${tmax%.*}"
      if (( t_int > HOT[$n] )); then HOT[$n]=$t_int; HOTN[$n]="$tname"; fi
      if (( t_int >= WARN_C )); then
        echo "$ts WARN $n: ${tname} at ${tmax} C (>= ${WARN_C} C throttling line)" >&2
      fi
    fi
  done
  if [[ -n "$CHILD" ]] && ! kill -0 "$CHILD" 2>/dev/null; then
    wait "$CHILD" || echo "command exited with status $?" >&2
    CHILD=""
    break
  fi
  sleep "$INTERVAL"
done
