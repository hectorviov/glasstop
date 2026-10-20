#!/usr/bin/env bash
# Reliability soak (PLAN.md M7). Launches build/Glasstop.app with stderr captured, then every
# INTERVAL minutes for HOURS hours appends a CSV row: footprint, average CPU, leak count (every
# 3rd row) and sampler stalls logged so far (excluding the ones caused by `leaks` itself, which
# suspends the app while scanning).
#
# Usage: scripts/soak.sh [hours=24] [interval_min=30]
# Output: soak/soak-<timestamp>.csv and soak/stderr-<timestamp>.log
set -uo pipefail
cd "$(dirname "$0")/.."

HOURS=${1:-24}
INTERVAL_MIN=${2:-30}
STAMP=$(date +%Y%m%d-%H%M)
mkdir -p soak
CSV="soak/soak-$STAMP.csv"
ERR="soak/stderr-$STAMP.log"

pkill -x Glasstop; sleep 1
open --stderr "$PWD/$ERR" build/Glasstop.app
sleep 60   # let it settle

to_mb() {   # "59 MB" / "1.2 GB" / "980 KB" -> MB
    awk '{ v=$1; u=$2; if (u=="GB") v*=1024; else if (u=="KB") v/=1024; printf "%.1f", v }'
}

echo "time,pid,footprint_mb,cpu_pct,leaks,stalls" > "$CSV"
rows=$(( HOURS * 60 / INTERVAL_MIN ))
for ((i = 0; i <= rows; i++)); do
    now=$(date +%Y-%m-%dT%H:%M:%S)
    if PID=$(pgrep -x Glasstop); then
        fp=$(footprint -p "$PID" 2>/dev/null | sed -nE 's/.*Footprint: ([0-9.]+ [KMG]B).*/\1/p' | to_mb)
        cpu=$(top -l 11 -s 2 -pid "$PID" -stats cpu | grep -E '^ *[0-9.]+ *$' | tail -10 \
              | awk '{ s += $1 } END { if (NR) printf "%.2f", s / NR }')
        lk=""
        if (( i % 3 == 0 )); then
            # `leaks` suspends the app while it scans memory (several seconds), which the app
            # logs as a sampler stall. Those are excluded from the count.
            before=$(grep -c "sampler stall" "$ERR" 2>/dev/null || true)
            lk=$(leaks "$PID" 2>/dev/null | sed -nE 's/.*: ([0-9]+) leaks for.*/\1/p')
            sleep 3
            after=$(grep -c "sampler stall" "$ERR" 2>/dev/null || true)
            leak_stalls=$(( ${leak_stalls:-0} + after - before ))
        fi
        stalls=$(( $(grep -c "sampler stall" "$ERR" 2>/dev/null || true) - ${leak_stalls:-0} ))
        echo "$now,$PID,$fp,$cpu,$lk,$stalls" >> "$CSV"
    else
        echo "$now,,,,,not running" >> "$CSV"
    fi
    (( i < rows )) && sleep $(( INTERVAL_MIN * 60 ))
done
echo "soak finished: $CSV"
