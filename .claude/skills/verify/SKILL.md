---
name: verify
description: How to verify Kubenyx changes end-to-end — build the NixOS VM test driver and drive a real cluster; native bench for control-plane timing. Use for any change under modules/, pkgs/, lib/, or tests/.
---

# Verifying Kubenyx

The surface is a booted Kubernetes cluster driven with `kubectl`. The only
honest verification is the NixOS VM test (real systemd, real containerd,
real networking). Nix eval alone proves nothing; there are no unit tests.

## Environment facts (this dev box)

- **No KVM** — VM tests run under QEMU TCG: single-node happy path takes
  ~15–25 min wall. Absolute in-VM timings are meaningless; only
  kubenyx-vs-k3s ratios in identical VMs count.
- The Bash sandbox blocks `cache.nixos.org` — every `nix build` needs the
  sandbox bypassed or it tries to compile the world.
- `nix flake` requires files tracked in the **git index** (`git add` new
  files) even though the repo is jj-managed.
- `/etc` is immutable on this host (blocks native k3s; not Kubenyx).

## Recipe

```bash
git add -A .   # flake sees only git-tracked files

# 1. Build the driver (fast eval+build check; catches shellcheck failures
#    in writeShellApplication scripts, containerd config validation, etc.)
nix build .#checks.x86_64-linux.single-node.driver -o .result-driver

# 2. Run it OUTSIDE the nix sandbox (driver runs qemu directly; avoids the
#    kvm system-feature requirement)
.result-driver/bin/nixos-test-driver > test-run.log 2>&1; echo EXIT=$?
grep -aE 'KUBENYX-METRIC|Traceback|RequestedAssert' test-run.log
```

Exit 0 + four `KUBENYX-METRIC` lines = the full happy path passed
(security posture, PKI idempotency, zero-registry pod start, exec,
Service VIP, DNS, hairpin, no-daemon audit).

Control-plane timing changes: `nix build .#packages.x86_64-linux.native-bench
-o result-nb && ./result-nb/bin/kubenyx-native-bench` (seconds, not
minutes; `KEEP_WORK=1` keeps component logs, `WARM_RESTART=1` adds the
warm apiserver metric). Record results in `bench/RESULTS.md`.

Backends/matrix: `.#checks.x86_64-linux.single-node-etcd.driver`,
`.#checks.x86_64-linux.bench-vs-k3s.driver` — same run pattern.

## Gotchas that already bit

- Only ONE driver at a time: they share `/tmp/vde1.ctl` + VM state dirs; a
  second driver hangs at "start all VLans". Clean up:
  `pkill -f '[n]ixos-test-driver-wrapped'; pkill -9 -f '[q]emu-system';
  rm -rf /tmp/vde1.ctl /tmp/vm-state-machine* /tmp/shared-xchg`
  (bracketed patterns so the kill doesn't match its own cmdline).
- `ps` inside the sandbox cannot see processes started outside it — check
  for running qemu with sandbox bypassed before declaring a run dead.
- The driver buffers output through pipes; an empty log ≠ dead run.
- shellcheck runs at build time on all writeShellApplication scripts; a
  single-item `for x in <one thing>` loop fails the build (SC2043) — use
  arrays.
