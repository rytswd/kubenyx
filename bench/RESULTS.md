# Benchmark Results Log

Newest entries first. Native = bare processes on the dev box (64-core
x86_64, NVMe, no virtualization) via `nix run .#native-bench`. VM = NixOS
test driver under QEMU TCG (no KVM on this box) — absolute VM numbers are
meaningless, only kubenyx-vs-k3s ratios in identical VMs count. KVM =
EC2 metal (Xeon 6975P-C Granite Rapids, 384 cores, /dev/kvm): absolute
numbers are real.

## 2026-07-08 — Multi-node campaign complete: fast path held, HA proven

The v0.2 mesh + v0.3 durable/HA work landed as one campaign
(nodes.role schema → mesh → kubenyx-lb + CA custody → etcd quorum →
test legs → performance gate). The user's constraint was hard: the
single-node testing path must not pay for any of it.

### Fast path, before vs after (the gate)

| Metric | Before (pre-campaign) | After | Bar |
|---|---|---|---|
| Cold boot median (firecracker + etcd-mem) | 7.77 s | no tree-attributable change¹ | ≤ 8.2 s |
| Recreation (`kubenyx-snap cycle`) | 65.6 ms | **66.6 ms** | ≤ 100 ms |
| single-node check wall | 36.4–36.8 s | **38 s** | ≤ 45 s |
| Guest systemd unit list | — | **bit-identical** | zero new units |
| Guest closure | — | **+4,336 bytes**² | ~zero |

¹ Raw windows straddled the bar (8.26/8.42/7.95 s medians) because a
root `nix-store --optimise` was saturating store I/O during the first
runs — the decisive evidence is a 6-round interleaved A/B against the
pre-campaign runner under identical conditions: the current tree was
faster in 5 of 6 paired rounds (e.g. 8.64→8.27, 7.60→7.42). The box
shows a bimodal ~7.4–8.8 s envelope that both trees share; per-phase
console stamps are identical mode-for-mode, and slow-mode divergence
begins in kernel/initrd before any kubenyx unit runs.
² kubenyx-tools hash churn from the workspace rebuild (kubenyx-pki
+custody/mint-ca code) + the serve-script request-drain fix. kubenyx-lb
is deliberately a separate package so it cannot ride into guests;
lb/handoff/quorum/custody units are all absent from the single-node
guest (verified by unit-list diff of the built toplevels).

### New capabilities, measured

| What | Result |
|---|---|
| 3-node microVM mesh (`nix run .#microvm-cluster`) | **8.70 s** median launch→all-Ready (details below) |
| multi-server check (3-server quorum + LB agent + custody) | PASS, 25.6 s |
| failover check (crash server0; kill -9 etcd member) | PASS, 38.1 s |
| agent-add check (**hitless scale-out proof**) | PASS, 95 s — pod restartCount 0, NRestarts=0 on every control-plane unit and kubelet through a live 2→3 node config switch |
| ca-custody check (durable CA gate refuses, then boots shipped) | PASS, 30 s |
| server-reboot check (full VM reboot of a quorum member) | PASS, 98 s — persistent data + shipped CA survive, member rejoins without re-bootstrap, 2/3 quorum serves reads AND writes throughout |
| multi-node-mem check (etcd-mem + agent, the relaxation leg) | PASS, 22 s — fastest multi-node leg (etcd-mem's instant startup) |

Two findings from the failover leg worth the whole exercise:

- **`Requires=` on the datastore is wrong under quorum**: a local etcd
  death stop-propagated into the collocated apiserver, the propagated
  stop hung ~90 s in graceful shutdown (queueing etcd's restart behind
  it, stretching quorum recovery ~2 s → ~94 s), and — worse — a
  dependency stop is "deliberate" to systemd, so `Restart=always`
  never fired: one etcd blip permanently killed the API replica.
  Multi-server now uses `Wants=` (the apiserver's etcd client rides
  through no-leader windows fine); single-server keeps `Requires=`
  byte-for-byte.
- **Anonymous `/readyz` probing lies under `--anonymous-auth=false`**:
  the auth filter answers 401 regardless of readiness. kubenyx-lb
  probes with the agent's kubelet client cert; until the cert lands,
  backends stay unhealthy — correct, since without credentials there
  is no kubelet to serve anyway.

## 2026-07-08 — KVM: 3-node microVM mesh ready in 8.7s (median)

`nix run .#microvm-cluster` (air/v0.2 §2–4): 1 server + 2 agent
firecracker microVMs on bridged taps (kubenyx-br0), etcd-mem
datastore, per-agent credential handoff over ports 10125/10126
(socket-activated, IPAddressAllow per declared agent address). Wall
clock is launcher start (before the first VMM spawns) to all three
nodes reporting KUBENYX-CLUSTER-READY; verified after each run with
`kubectl get nodes` via the served kubeconfig → 3/3 Ready.

| Run | mesh wall (launch → all-Ready) | per-node in-guest ready |
|---|---|---|
| 1 | 9.145 s | agents 8.20/8.21 s, server 8.79 s |
| 2 | 8.475 s | agents 7.73/7.73 s, server 8.27 s |
| 3 | 8.703 s | agents 7.81/7.81 s, server 8.40 s |

Median **8.70 s** — under the 15 s target and the 12 s stretch.
Agents fetch their credential bundle at ~6.4s uptime (bounded retry
against the server's socket-activated handoff; the server mints all
node leaves in its ~6ms PKI oneshot) and reach Ready *before* the
server (~0.5s less unit load). Host-side negative test: connections
to 10125/10126 from the host (10.100.0.1, not an allowed source) are
dropped by IPAddressAllow (curl timeout, nothing served).

Fixed en route: the kubeconfig/bundle handoff services read only the
request line before responding, leaving unread request bytes in the
socket buffer — close() then RSTs the in-flight response tail
(`curl: (56) Recv failure`), which is why agents' `curl -f` fetch
loops never succeeded on run 0. Both serve scripts now drain the
request through the blank line.

Single-node invariant re-checked on the same commit (bit-identical
unit list; only the serve-kubeconfig script hash changed): cold boot
7.56 / 7.68 / 7.83 / 8.72 / 8.78 s over 5 runs, median **7.83 s** ≤
the 8.2 s bar (first two runs were taken right after mass nix builds;
the host was still noisy).

## 2026-07-07 — KVM session: 8.5s cluster-ready, 75ms snapshot restore

First run on real hardware (EC2 metal, KVM). Every extrapolated claim
below this entry is now superseded by a measured number.

### Phase 1 — microVM boot, measured (in-guest clock)

The honest correction first: the "12–15× TCG factor" was optimistic.
Actual factor ≈ 6.5× (76.6s TCG → 11.85s KVM); the **<10s bar failed
on the stock tree** and passed only with the boot work landed this
session:

| Tree + datastore | cluster-ready median (range) | runs |
|---|---|---|
| stock (d95e763), firecracker + kine | 11.85 s (10.83–12.92) | 5 |
| stock, cloud-hypervisor + kine | 11.70 s (11.55–11.81) | 5 |
| merged tree, firecracker + kine (A/B control) | 8.31 s (8.16–8.40) | 3 |
| merged tree, firecracker + **etcd-mem** | **7.77 s** (7.75–7.87) | 3 |
| merged tree, cloud-hypervisor + etcd-mem | 7.90 s smoke | 1 |

Attribution (A/B on the identical merged tree, only the backend
switched): the guest-profile boot work bundled in the etcd-mem change
(initrd store warmup, kubenyx.target pulled to sysinit,
DefaultDependencies pruning) is worth ~3.5 s; **etcd-mem itself is
worth ~0.5 s of wall clock** (8.31 → 7.77) — kine's ~2.4s init burns in
parallel with kubelet/containerd, so only part of it was on the
critical path. Datastore-up phase: kine 7.03s → etcd-mem 5.0s.

etcd-mem is the new Rust in-memory etcd shim (~2.3 MiB, tonic gRPC over
a unix socket) replacing kine in the microVM guests (kine is retired
from the boot path per user steer; it also loses the 38MB Go binary
from the store disk). Validation on KVM caught three real bugs the TCG
box never reached (WatchResponse proto field 8→11, initial revision
0→1, hard-wired etcd.service Requires) — see the etcd-mem commit
message. The ~5s datastore-up stamp is boot-path unit scheduling; shim
init itself is <10 ms.

Cloud-hypervisor's runner requested num_queues=8 and refused the plain
single-queue tap (MultiQueueNoTapSupport) — the flake now pins one
queue pair; boot-path cost none.

### Phase 2 — test matrix at hardware speed

All green. TCG grind loop (hours) → KVM minutes:

| Check | Result | Wall clock |
|---|---|---|
| single-node | PASS | 36.8 s (apiserver 19.8s, node Ready 30.0s, pod 33.2s) |
| single-node-etcd | PASS | 153 s |
| multi-node | PASS | 38.4 s (after the 9p fix below) |

KVM exposed a real test bug TCG could never reach: the multi-node
credential ship via the 9p shared dir fails deterministically at
hardware speed — the agent guest caches the negative dentry for
`/tmp/shared/agent-pki` and never revalidates (even a 60s retry loop
never converged). The ship is now driver-mediated (tar|base64 through
the test driver), which also matches the operator-channel semantics
the test simulates. Second harness gotcha for the record: the test
driver keys ALL its runtime state (vde socket dirs, `vm-state-<name>`,
`shared-xchg`) off `XDG_RUNTIME_DIR` with no per-run namespace —
concurrent drivers collide, vde_switch dies silently, and the loser
hangs forever at "start all VLans" (this, not test code, is why two
matrix legs stalled on the first concurrent run). Concurrent driver
runs each need their own `XDG_RUNTIME_DIR`.

### Phase 3 — kubenyx-vs-k3s, KVM-clean

Three runs (in-VM clock; last one on an otherwise idle box):

| Run | k3s | Kubenyx | ratio |
|---|---|---|---|
| stock tree, concurrent load | 24.4 s | 17.2 s | 0.71 |
| merged tree, concurrent load | 23.5 s | 18.7 s | 0.80 |
| merged tree, quiet box | 26.1 s | **17.4 s** | **0.67** |

TCG history: 1.01 → 0.85 → 0.76 → 0.73. At ~20 s boots, ±1 s of in-VM
variance moves the ratio ±0.05, so the honest KVM statement is
**0.67–0.80** — kubenyx is stable at 17–19 s while k3s wanders 23–26 s.
KVM removes the emulation distortion and the ratio *improves* —
Kubenyx's boot is more CPU-bound than k3s's, as predicted.

### Phase 4 — firecracker snapshot/restore: 75 ms to a live cluster

Snapshot a cluster-ready guest (pause → /snapshot/create), restore into
a fresh firecracker process: median **74.5 ms** from /snapshot/load
request to the first apiserver TLS response (3 restores from one
snapshot; ~88 ms including VMM process spawn). Target was <1s — beaten
13×. vmstate 68 KB + mem file 3.5 GB (demand-paged, warm host cache).

The one real discovery: on AMX hosts (Granite Rapids) a restored guest
kernel-panics in XRSTORS (#GP) — the fresh VMM never re-acquires AMX
xstate permission, and IA32_XSS/CET supervisor state doesn't restore
either. Fix shipped in the firecracker variant's kernel params:
`clearcpuid=amx_tile,amx_int8,amx_bf16 noxsaves` (no measured boot
cost). Full findings + kubenyx-snap design: air/v0.2/snapshot-restore.org.

### Phase 4b — kubenyx-snap: recreation productized at 66 ms

The flow above is now `nix run`-able tooling (third Rust tool pair):

| Step | Measured |
|---|---|
| `kubenyx-snap take` (one-time) | 9.1 s boot + **2.7 s** snapshot write (tmpfs) |
| `kubenyx-snap cycle -n 5` | median **65.6 ms** load→serving-apiserver, range 25–72 ms |
| guest wall clock after resume | correct to the second (`KUBENYX-CLOCKSTEP stepped=149s` on a deliberately aged snapshot) |

Recreating a cluster is ~120× cheaper than cold-booting one (7.8 s →
0.066 s). Two guest gaps found and fixed while productizing:

- **No time source in the guest**: firecracker 1.15 attaches no VMCLOCK
  ACPI device (in-guest probe; the earlier session note claiming
  ptp_vmclock was loaded was wrong) and there is no RTC — after restore
  CLOCK_REALTIME stays stale forever. `kubenyx-snap resume` now sends
  UDP time pokes; the in-guest `kubenyx-clockstep` daemon steps the
  clock (>500 ms offset only, so ordinary boots are untouched).
- **Clones shared CRNG state**: the FCVMGID device was present but the
  `vmgenid` driver never loaded, so restored clones kept the snapshot's
  entropy pool. `boot.kernelModules = [ "vmgenid" ]` fixes the reseed.

Implementation gotcha for the record: firecracker's API server ignores
`Connection: close` — read responses by Content-Length or every call
stalls to your socket timeout (this masqueraded as a 10 s
/snapshot/load until diagnosed).

## 2026-07-07 — Round 5: ratio 0.73 (declared-address flags fixed)

The review of the microVM delta caught the bench VM declaring k3svm's
VLAN IP (alphabetical assignment strikes again — the multi-node test
documented the rule; the bench repeated the mistake, inert until
`--node-ip` made it load-bearing). With the correct address, the full-VM
head-to-head improves again:

| Metric | k3s | Kubenyx |
|---|---|---|
| node Ready (in-VM clock) | 109.7 s | **79.7 s** |
| ratio | — | **0.73** (1.01 → 0.85 → 0.76 → 0.73) |

## 2026-07-07 — MicroVM guest: cluster-ready at 76.6s under pure TCG

New `nix run`-able microVM variants (microvm.nix input): firecracker and
cloud-hypervisor for KVM hosts, qemu/q35+`cpu=max` for KVM-less machines
(validated here end-to-end under TCG — software-emulating every guest
instruction). In-guest phase trace, TCG clock:

| Phase | uptime |
|---|---|
| kine accepting connections | 28.2 s |
| kubelet started | 32.6 s |
| apiserver `/readyz` | **47.0 s** |
| addons applied | 60.8 s |
| coredns ready | 65.8 s |
| node Ready (kubelet log, run 7) | ~53 s |
| `KUBENYX-CLUSTER-READY` marker | **76.6 s** |

The full NixOS test VM needs ~150 s+ to node-Ready under identical
emulation — the stripped guest (tmpfs root over squashfs store, no
initrd frills, no DHCP wait, volatile datastore, per-boot 6 ms PKI)
roughly halves it. Real-hardware translation at the observed 12–15×
TCG factor: kernel+userspace ~2 s, apiserver ~3.8 s, node Ready ~4.5 s,
marker ~6 s — **single-digit seconds to a fresh cluster per launch** on
any KVM machine via `nix run .#microvm-firecracker`.

Debug findings that also hardened the main modules:
- kube-apiserver exits when no default route exists and
  `--advertise-address` is unset → declared node addresses now ship as
  `--advertise-address` (control plane) and `--node-ip` (kubelet).
- microvm.nix guests run systemd-networkd with their own generated
  units; scripted `networking.interfaces` config silently loses — the
  variants write `systemd.network.networks` matching the NIC MAC.
- The `kubenyx-healthz` identity deliberately has zero RBAC grants:
  it passes only always-allowed /healthz-class paths. Reading a node
  object requires a bound identity (the report probe uses admin).

## 2026-07-06 — Rust boot-path tools: ratio 0.76, native 2.7s

Round 4 head-to-head (same harness as round 2, in-VM kubelet-line metric):

| Metric | k3s | Kubenyx |
|---|---|---|
| node Ready (in-VM clock) | 115.8 s | **87.7 s** |
| ratio | — | **0.76** (was 1.01 → 0.85 → 0.76) |

Native control plane: PKI **6 ms** (was 530 ms — rcgen in one process vs
~80 openssl forks), apiserver cold `/readyz` 2.30 s, warm 1.78 s, first
end-to-end write **2.70 s** (was 3.10 s).

What changed:

- `kubenyx-pki` (Rust): entire PKI + kubeconfigs in ~5 ms; also the agent
  renderer.
- `kubenyx-ready` (Rust): 10 ms fork-free rustls readiness probes with
  sd_notify (was 200 ms curl-fork polling), plus a unix-socket probe mode.
- PKI starts at local-fs time when the node address is declared (no
  network-online wait) — pulled the whole control-plane chain ~15 s
  earlier in VM boots.
- Datastores are now Type=notify ("started" = accepting connections):
  round 3 exposed the apiserver racing kine's dead socket and — worse —
  `kubenyx-addons` with `Requires=` having its job canceled forever after
  one transient apiserver failure. The applier now retries internally.

A/B: `--enable-priority-and-fairness=false` gains nothing (±25 ms) — APF
stays on.

Real-hardware extrapolation for the 20 s target: PKI 6 ms + datastore
~50 ms + apiserver 2.3 s + kubelet/containerd init in parallel +
registration ≈ **4–6 s single-node cluster-ready from service start**;
agents boot in parallel and add no serial cost.

## 2026-07-05 — VM head-to-head round 2: Kubenyx beats k3s

Identical 4-core/4GB airgapped VMs, sequential boots, k3s 1.35.6 with its
airgap images and bundled extras disabled, Kubenyx at commit b2d2d27b+.
Primary metric = the identical kubelet "node just became ready" journal
line on the in-VM monotonic clock (driver-side kubectl polling under TCG
adds ~55s of noise — both legs suffer it, but the in-VM line removes it).

| Metric | k3s | Kubenyx |
|---|---|---|
| node Ready (in-VM clock) | 113.2 s | **96.3 s** |
| node Ready (driver clock, noisy) | 117.3 s | 102.0 s |
| cluster portion (service start → Ready) | ~71 s | ~46 s |

Ratio 0.85 in-VM / 0.87 driver-clock. Round 1 (before the boot-speed
work) was 1.01 — the wins between rounds:

- kubeconfigs rendered by bash heredoc instead of forking kubectl (a
  50 MB Go binary) 32 times inside the PKI oneshot;
- PKI leaf issuance and kubeconfig writes parallelized (random serials
  instead of a shared .srl file);
- image seeding runs in parallel with kubelet (registration doesn't
  need the pause image; only the first sandbox does);
- CoreDNS no longer ordered before kubelet (its readiness waits on the
  addons RBAC chain — that serialized the whole boot);
- kcm shared identity (no per-controller SA token minting).

In-VM boot phase timings for Kubenyx (single-node test, same build):
kine up 36.6s, PKI 50.8→57.6s, kubelet start 57.6s, apiserver ready
84.2s, node registered 96.5s, Ready ~100s. The 26s kine→PKI gap is
NixOS userspace/network-online under TCG, not Kubenyx.

## 2026-07-05 — native, after kcm SA-credentials fix

Kubernetes 1.36.2, kine 0.16.0 (sqlite/WAL), ECDSA P-256 PKI.

| Metric | Value |
|---|---|
| PKI generation (18 certs + 8 kubeconfigs, serial) | 530 ms |
| apiserver `/readyz` (cold, fresh datastore) | 2 350 ms |
| apiserver `/readyz` (warm restart, bootstrap objects exist) | 1 630 ms |
| kcm `/healthz` | +180 ms after apiserver |
| scheduler `/healthz` | +10 ms after kcm |
| first end-to-end write (default SA in fresh namespace) | **3 100 ms** |

Findings:

- `--use-service-account-credentials=true` costs **+4.9 s** (8.1 s →
  3.2 s total): kcm mints a SA token per controller, serially, at every
  start. Testing profile now defaults it off.
- sqlite `_synchronous` (NORMAL/OFF vs FULL): no measurable difference on
  NVMe — bootstrap writes are not fsync-bound here.
- apiserver cold-vs-warm delta (~700 ms) = one-time bootstrap RBAC/priority
  class writes. The remaining ~1.6 s warm floor is TLS/storage init plus
  upstream post-start-hook poll intervals (~1 s granularity) — not
  reachable via flags.

k3s native baseline: **blocked on this host** — k3s hardcodes
`/etc/rancher` and `/etc` is immutable here (no mount namespaces either).
First attempt produced a bogus 2 726 ms reading because kubectl silently
fell back to ambient in-cluster credentials — see bench/k3s-native.sh
guard. The authoritative comparison is `checks.bench-vs-k3s` (identical
VMs, both airgapped).

Reference points from published research (see
air/context/research/fast-start.md): k3s boot-to-all-pods-ready is ~50 s
on real hardware; kubeadm ~30–60 s with images pre-pulled; bare apiserver
serving in ~2–10 s. A 3.1 s usable control plane is already at the top of
that field.
