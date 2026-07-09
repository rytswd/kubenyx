#!/usr/bin/env bash
# microvm-boot.sh <runner-store-path> <logfile> — boot the single-node
# firecracker microVM once under the bench contention contract, wait for
# KUBENYX-CLUSTER-READY, print the in-guest uptime seconds on stdout,
# tear down and wait until no firecracker process remains.
#
# Contention contract (why this script exists at all): the box's boot-time
# "bimodality" (3.4s vs 5.4s for a byte-identical runner) is host CPU
# contention, not the guest — 320 busy threads dilate every boot phase
# ~2.3x uniformly (profiled 2026-07-09; drop_caches showed no effect).
# Two controls, both enforced here so every future bench inherits them:
#
#   1. Idleness gate: refuse to boot when the host already has sustained
#      runnable threads (min of 3 samples > KX_MAX_RUNNABLE, default 16).
#      Exit 9 = "measurement would be a lie, not a failure of the guest".
#      KX_FORCE=1 downgrades the refusal to a tagged warning on stderr.
#   2. CPU pinning: the VMM and its vcpu threads run in a fixed cpuset
#      (KX_CPUSET, default 8-15 — one L3 neighborhood, off cpu0's
#      housekeeping; ~8 threads for a 4-vcpu firecracker). Placement is
#      deterministic run-to-run, and load elsewhere cannot steal the
#      guest's CPU TIME — but package frequency and LLC/DRAM bandwidth
#      still bleed through (320 off-range busy threads: pinned boot
#      4.61s vs 5.12s free placement vs ~3.4s idle), which is why the
#      gate above, not the pinning, is the primary control.
#      On an IDLE host pinning is itself a win —
#      paired median 0.16s faster than free placement over 6 pairs
#      (5/6), envelope 3.30-3.49 vs 3.38-3.73: one L3 neighborhood
#      beats threads scattering across two sockets. Consequence:
#      pinned-harness numbers are NOT comparable to pre-harness
#      unpinned logs; compare pinned-vs-pinned only.
#
# The scaling governor must be `performance` on every cpu (the third
# leg of the contract, enforced since the 16:xx profiling session).
set -euo pipefail
runner=$1
log=$2
cpuset=${KX_CPUSET:-8-15}
max_runnable=${KX_MAX_RUNNABLE:-16}

gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
if [ "$gov" != performance ]; then
  echo "FATAL: governor contract violated (governor=$gov, need performance)" >&2
  exit 9
fi

# Sustained-runnable sample: min of 3 forgives transient spikes (our own
# ps is one of them), sustained load cannot hide. Subtract 1 for the ps.
runnable=999
for _ in 1 2 3; do
  r=$(ps -eLo stat= | grep -c '^R' || true)
  r=$(( r > 0 ? r - 1 : 0 ))
  [ "$r" -lt "$runnable" ] && runnable=$r
  sleep 0.15
done
if [ "$runnable" -gt "$max_runnable" ]; then
  if [ "${KX_FORCE:-}" = 1 ]; then
    echo "WARN: contended host (runnable=$runnable > $max_runnable), KX_FORCE=1 — numbers are tagged suspect" >&2
  else
    echo "FATAL: contended host (runnable=$runnable > $max_runnable); refuse per bench contract (KX_FORCE=1 overrides)" >&2
    exit 9
  fi
fi

if pgrep -x firecracker >/dev/null 2>&1; then
  echo "FATAL: leftover firecracker process" >&2
  exit 2
fi

cwd=/tmp/kxb   # short CWD: firecracker unix sockets live here
rm -rf "$cwd"
mkdir -p "$cwd"
: > "$log"

( cd "$cwd" && exec taskset -c "$cpuset" "$runner/bin/microvm-run" ) </dev/null >"$log" 2>&1 &
launcher=$!

deadline=$(( $(date +%s) + 120 ))
uptime=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if grep -q "KUBENYX-FAILED\|KUBENYX-DEGRADED" "$log" 2>/dev/null; then
    echo "FATAL: guest degraded/failed — see $log" >&2
    pkill -KILL -x firecracker 2>/dev/null || true
    wait "$launcher" 2>/dev/null || true
    exit 3
  fi
  # Only accept a COMPLETE marker line (trailing "s"): the console log is
  # written incrementally and grep can see a torn prefix.
  uptime=$(sed -n 's/.*KUBENYX-CLUSTER-READY uptime=\([0-9.]*\)s.*/\1/p' "$log" 2>/dev/null | head -1)
  [ -n "$uptime" ] && break
  sleep 0.1
done

# Teardown: disposable tmpfs guest — TERM then KILL, wait for full exit
# (the tap family is exclusive; a half-dead VMM poisons the next boot).
pkill -TERM -x firecracker 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -x firecracker >/dev/null 2>&1 || break
  sleep 0.1
done
pkill -KILL -x firecracker 2>/dev/null || true
for _ in $(seq 1 50); do
  pgrep -x firecracker >/dev/null 2>&1 || break
  sleep 0.1
done
wait "$launcher" 2>/dev/null || true

if pgrep -x firecracker >/dev/null 2>&1; then
  echo "FATAL: firecracker refused to die" >&2
  exit 4
fi
if [ -z "$uptime" ]; then
  echo "FATAL: no CLUSTER-READY within 120s — see $log" >&2
  exit 5
fi
echo "$uptime"
