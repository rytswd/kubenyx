#!/usr/bin/env bash
# microvm-ab.sh <runnerA> <runnerB> <pairs> <labelA> <labelB> <outdir>
# Interleaved paired A/B for single-node microVM cold boots — the house
# standard: pair i odd boots A then B, pair i even boots B then A, so
# slow drift in host state cancels inside each pair. Judge ONLY by the
# paired median (the host envelope is bimodal; raw medians lie).
#
# Every boot goes through microvm-boot.sh, which enforces the contention
# contract (performance governor, idleness gate, VMM cpuset pinning) —
# see the header there. An exit 9 mid-run means the host got contended:
# the run aborts rather than emitting poisoned pairs.
#
# Output: one line per boot, then a "PAIRS" table (a_i b_i per line) and
# the paired-median delta (a - b, positive = B faster).
set -euo pipefail
A=$1; B=$2; N=$3; LA=$4; LB=$5; OUT=$6
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

echo "# $(date -u +%FT%TZ) loadavg=$(cut -d' ' -f1-3 /proc/loadavg) cpuset=${KX_CPUSET:-8-15} max_runnable=${KX_MAX_RUNNABLE:-16}"

declare -a AV BV
for i in $(seq 1 "$N"); do
  if [ $(( i % 2 )) -eq 1 ]; then order="A B"; else order="B A"; fi
  for side in $order; do
    if [ "$side" = A ]; then r=$A; l=$LA; else r=$B; l=$LB; fi
    v=$(bash "$here/microvm-boot.sh" "$r" "$OUT/pair${i}-${l}.log")
    echo "pair=$i $l uptime=${v}s"
    if [ "$side" = A ]; then AV[$i]=$v; else BV[$i]=$v; fi
    sleep 1
  done
done

echo "PAIRS ($LA $LB):"
for i in $(seq 1 "$N"); do echo "${AV[$i]} ${BV[$i]}"; done

# Paired median of (a_i - b_i), computed exactly (sorted, middle or mean
# of middles).
for i in $(seq 1 "$N"); do
  awk -v a="${AV[$i]}" -v b="${BV[$i]}" 'BEGIN{printf "%.3f\n", a-b}'
done | sort -n | awk -v n="$N" '
  { d[NR] = $1 }
  END {
    if (n % 2) m = d[(n+1)/2];
    else m = (d[n/2] + d[n/2+1]) / 2;
    printf "PAIRED-MEDIAN-DELTA(%s-%s)=%.3fs (positive = %s faster)\n", "'"$LA"'", "'"$LB"'", m, "'"$LB"'"
  }'
