# Benchmark Results Log

One table of current numbers first; the bench contract and the
mechanism notes that explain them stay below. Dated progression
entries that these numbers superseded were pruned on 2026-07-21 —
the full arc lives in git history (`git log -p -- bench/RESULTS.md`).

Host classes: **Native** = bare processes on the dev box (64-core
x86_64, NVMe, no virtualization) via `nix run .#native-bench`.
**VM** = NixOS test driver under QEMU TCG (no KVM on that box) —
absolute VM numbers are meaningless, only kubenyx-vs-k3s ratios in
identical VMs count. **KVM** = EC2 metal (Xeon 6975P-C Granite
Rapids, 384 cores, /dev/kvm): absolute numbers are real. Every kubenyx
microVM row and every rivals row below is the KVM host.

## Current numbers

| Measurement | Result | Measured | Conditions |
|---|---|---|---|
| cp1 cold boot → CLUSTER-READY | **3.4 s** p50 | 2026-07-09 (reconfirmed 3.31–3.37 s medians 2026-07-15) | pinned contract¹ |
| cp1 snapshot recreation (`kubenyx snap cycle`) | **~28–33 ms** — session medians 28.4–33.2, latest 31.9 / 31.4 ms; per-round raws down to ~25 | 2026-07-09 (reconfirmed 2026-07-15) | pinned contract¹ |
| cp1 snapshot take (one-time) | 1.84 s write, 3.5 GB on tmpfs | 2026-07-09 | single run |
| cp1w2 (1 CP + 2 workers) cold boot | **3.8 s** MESH-READY | 2026-07-12 (uncontrolled live smokes 3.84–4.03 s, 2026-07-12/14) | pinned contract¹ |
| cp1w2 mesh recreation (`mesh-cycle`) | **~44–46 ms** median | 2026-07-09 | pinned contract¹ |
| cp1w6 (1 CP + 6 workers) cold boot | **~4.2 s** — ~flat with node count | 2026-07-09 sweep | pinned contract¹ |
| cp1w6 mesh recreation | **~56 ms** median | 2026-07-09 sweep | pinned contract¹ |
| cp3 (3-CP etcd quorum) cold boot | **6.5 s** p50 (6338–7191 ms, 5 boots) | 2026-07-12 | pinned contract¹ |
| cp3 mesh recreation | **47.8 ms** median; first *committed* quorum write 97.1 ms | 2026-07-12 | 5-cycle medians, pinned band |
| cp3w2 (quorum + 2 workers) cold boot | ~9.4 s (9370 / 9562 ms) | 2026-07-12 | **single-run, unpinned** — indicative only |
| In-driver `savevm` (harness, 2-node, 4 G VMs, parallel wall) | 7.78 s | 2026-07-14 | single run |
| In-driver `loadvm` (parallel wall) | ~13 s (12.96 / 13.27 s); 4.93 s with the seed on /dev/shm | 2026-07-14 / 2026-07-15 | single run |
| CI snapshot artifact (mint drv / restore-to-healthy) | 26 s mint; **10.10 s** restore-to-healthy vs 20.90 s boot-to-Ready baseline (~2×) | 2026-07-15 | single run; baseline N=4 |
| Native bare-process control plane (no VM) | PKI **6 ms**; apiserver `/readyz` cold 2.30 s; first end-to-end write **2.70 s** | 2026-07-06 | dev box, quiet |
| k3s head-to-head (identical airgapped VMs, KVM) | ratio **0.67–0.80**: kubenyx 17–19 s vs k3s 23–26 s node-Ready | 2026-07-07 | in-VM clock, 3 runs |
| kind v0.31.0: create → node Ready | 31.30 s median (30.99–32.97) | 2026-07-21 | rivals conditions² |
| kind: delete + create (its only fresh-again path) | 42.58 s median (42.50–42.85) | 2026-07-21 | rivals conditions² |
| minikube v1.38.1: create → node Ready | 33.77 s median (32.85–33.96) | 2026-07-21 | rivals conditions² |
| minikube: delete + create | 42.92 s median (42.62–43.67) | 2026-07-21 | rivals conditions² |
| k3d v5.8.3 | **not benchable on this host** — k3s hard-requires the cpuset cgroup-v2 controller, which the rootless user slice doesn't delegate | 2026-07-21 | rivals conditions² |

¹ **pinned contract** = performance governor + idleness gate + taskset
pinning per the bench contract below. Pinned numbers are only
comparable to pinned numbers.

² **rivals conditions** = same 384-core KVM host, quiet (load 0.40 at
start), rootless podman 5.8.2; kind v0.31.0 (kindest/node = K8s
v1.35.0), k3d v5.8.3, minikube v1.38.1 (kicbase v0.0.50, K8s v1.35.1,
podman driver + containerd, rootless forced), kubectl v1.36.1. One
un-timed warm-up create/delete per tool (image caches warm), then ≥3
timed runs, medians; details in the dated rivals entry below.
**Isolation caveat:** the rivals run *containers sharing the host
kernel* (no hardware isolation) while kubenyx boots *hardware-isolated
microVMs* — kubenyx is doing strictly more work per cluster.
Placement: kind/minikube reach node Ready in ~31–34 s vs kubenyx cp1
3.4 s cold (~9×); their API-usable milestone (first `kubectl` success)
is ~15.4 / 16.2 s; their only fresh-cluster-again story is
delete+create at ~42.6–42.9 s vs kubenyx snapshot recreation at
~30–50 ms (~900–1300×).

## Bench contract & methodology

The bimodality this box shows is **host CPU contention, not the
guest**: a byte-identical runner booted 3.52 s and 5.36 s seven
minutes apart; 320 synthetic busy threads reproduce the slow mode with
uniform ~2.3× dilation of every phase; drop_caches changes nothing
(ZFS ARC serves the store). The consequence is a CONTRACT, not a guest
patch — `bench/microvm-boot.sh` / `bench/microvm-ab.sh` enforce:

- **performance governor** on all cpus;
- an **idleness gate**: min-of-3 runnable samples > 16 ⇒ refuse to
  bench (measured refusing at runnable=324 under a storm);
- **VMM pinned to one L3 neighborhood** (`taskset -c 8-15` single,
  `8-31` mesh) — pinning itself was worth +0.16 s paired median, and
  under an off-range storm it helps but does not immunize: the gate is
  the primary control.

Judging changes: **interleaved paired A/B**, alternating order, ≥6
pairs, decided on the paired median (keep or revert) — raw medians lie
on a shared box. Recreation A/Bs alternate `cycle -n 5` /
`mesh-cycle -n 5` runs against the SAME snapshot; the observation is
each run's median_total_ms. Every campaign also holds a byte-identity
gate on the default path (drv/store-path identity of the untouched
variants) before its numbers count.

Harness gotchas that shape method:

- **Concurrent NixOS test drivers collide**: the driver keys vde
  sockets and `vm-state-*` off `XDG_RUNTIME_DIR` with no per-run
  namespace — the loser hangs at "start all VLans". One
  `XDG_RUNTIME_DIR` per concurrent run.
- **TCG factor ≈ 6.5×** vs KVM on this project, not the 12–15×
  folklore. Absolute TCG numbers are still meaningless; only
  identical-VM ratios count.
- **k3s native on the dev box is blocked** (hardcoded `/etc/rancher`,
  immutable `/etc`; kubectl silently falling back to ambient
  credentials produced one bogus reading — see `bench/k3s-native.sh`
  guard). The authoritative comparison is `checks.bench-vs-k3s`:
  identical airgapped VMs.

## Mechanism notes that remain load-bearing

Numbers around these mechanisms are current; the progressions that
found them are in git history.

- **The cold-boot walls were client-go backoff quantizations inside
  kubelet** (registration retry ladder straddling apiserver-up, plus a
  2.5 s node-informer re-list backoff). Fix: ExecStartPre
  `kubenyx-ready --wait` gating kubelet (and coredns) on the exact
  first API request. Landmine: `%3D` in ExecStartPre is a systemd
  specifier and SILENTLY drops the gate — raw `=` only.
- **TCP_NODELAY on the apiserver probe socket**: the probe's TLS
  handshake parked ~40 ms on Nagle/delayed-ACK; load_to_api collapsed
  50 → 12–15 ms. This is most of why recreation is ~32 ms, not ~66.
- **etcd join-probe fast-exit**: TCP-classify peers before the health
  RPC (curl rc 7 = active refusal = fresh peer; rc 28 = silence = hold
  the window). No etcd patch: the 1–2 s BootstrapTimeout tail seen on
  the host bench was an artifact of staggered starts — synchronized
  founders hit connection-refused, etcd's fast path.
- **`Requires=` on the datastore is wrong under quorum**: a dependency
  stop is "deliberate" to systemd, so `Restart=always` never fires —
  one etcd blip permanently killed an API replica. Multi-server uses
  `Wants=`; single-server keeps `Requires=`.
- **Anonymous `/readyz` lies under `--anonymous-auth=false`** (401
  regardless of readiness) — probe authenticated.
- **Never build boot-path probes on watches**: first frames land
  seconds late during bring-up, and `curl -N | grep -q` lingers ~2.9 s
  after match waiting for SIGPIPE.
- **Firecracker fine print**: AMX hosts panic in XRSTORS on restore
  (`clearcpuid=amx_tile,amx_int8,amx_bf16 noxsaves`, or the amx-mask
  CPU template at KVM level); the API server ignores
  `Connection: close` — read by Content-Length; api-sock paths <
  SUN_LEN 108; no VMCLOCK device in 1.15 → UDP time pokes +
  `kubenyx-clockstep`; `vmgenid` module needed or clones share CRNG
  state; `--enable-pci` must match between take and resume.
- **Multi-server snapshots are volatile-only, ENFORCED**: firecracker
  snapshots exclude virtio disk contents, so a durable quorum resumed
  against a mutated disk corrupts. `mesh-take` refuses on durable
  posture or a missing run manifest before any API call.
- **Prebaked image stores**: 99.7 % of in-guest import cost becomes a
  mount (23.304 s → 0.063 s for a 300 MB incompressible set;
  `prebake-bench` enforces the ≥90 % contract). The bake is
  `--no-unpack`; the guest runs the native snapshotter when prebake is
  on (overlay-upper-on-overlayfs is rejected by the kernel).
- **kcm `--use-service-account-credentials=true` costs +4.9 s**
  (serial per-controller SA token minting at every start); the testing
  profile defaults it off.
- **9p negative-dentry caching bites at hardware speed**: a guest that
  stat-ed a not-yet-written shared-dir path never revalidates.
  Credential ships in tests are driver-mediated instead.

## Retained detail — entries whose numbers are still current

### 2026-07-21 — rivals on the same host: kind / k3d / minikube

Method: rootless podman 5.8.2 (active user socket, NO docker), tools
via nix shell, versions as footnoted above. One un-timed warm-up
create/delete per tool, then 4 timed create/delete runs each: create →
BOTH (first `kubectl get nodes` success AND node Ready) polled at
0.2 s — Ready always landed after kubectl-first, so create-to-BOTH ==
create-to-Ready.

| | kind | minikube |
|---|---|---|
| create → node Ready median | **31.30 s** (32.97/31.30/31.03/30.99) | **33.77 s** (32.85/33.96/33.77/32.93) |
| API-usable (kubectl-first) median | 15.41 s | 16.21 s |
| delete median | 11.54 s | 9.71 s |
| delete + create median | **42.58 s** (42.85/42.58/42.50) | **42.92 s** (43.67/42.62/42.92) |

Cold (first-ever) creates were not cleanly measured: kind's 941 MB
node-image pull blew the harness deadline; minikube's 46.35 s "cold"
had its 813 MB download cache pre-warmed by an aborted earlier attempt
(it measures image load, not network).

k3d: NOT benchable here. Both the nixpkgs-default k3s v1.21.7 image
and a modern v1.31.5 fatal with `failed to find cpuset cgroup (v2)` —
this host's rootless user slice delegates only `cpu io memory pids`,
and fixing that needs a root-level systemd Delegate change (out of
scope). kind/minikube survive because kubelet tolerates a missing
cpuset; k3s refuses. Not a k3d bug per se — it likely works rootful or
under docker. Gotcha for reruns: with passwordless sudo present,
minikube silently auto-escalates to ROOTFUL podman — force
`minikube config set rootless true`.

### 2026-07-15 — CI snapshot artifacts: mint once, restore in another derivation at ~2× bring-up speed

`checks.snapshot-mint` builds the artifact (2-node harness shape,
etcd, 4 G / 4-core VMs, derivation-built store image +
`-cpu Skylake-Server-v4,enforce`); `checks.snapshot-restore` consumes
it AS A DERIVATION INPUT, identity-gated exact-string before any qemu
spawn. KVM host, hot store: mint drv 26 s (parallel savevm cut
7.16 s); consumer check 19 s total — parallel loadvm 4.93 s (seed on
/dev/shm), restore to running guests 9.83 s, **restore-to-healthy
10.10 s** vs the same shape's 20.90 s boot-to-Ready baseline (N=4).

Artifact: self-contained qcow2 per node, vmstate inside — server
1.49 GiB → 368 MiB zstd-3 (4.2×), agent 0.97 GiB → 271 MiB (3.7×).
Honesty: ~4× compression, NOT the 13–14× once seen from firecracker
mem files (those were mostly zero pages). Honesty bar all green:
post-cut mint mutation ABSENT after restore, pre-cut provenance marker
PRESENT, fresh post-restore write lands.

**cpuModel pin A/B**: baseline median 20.90 s vs pinned 20.80 s
(−0.5 %, inside the baseline's own spread) — no measurable boot cost.
N=4 per variant, not a D5-grade N≥20.

### 2026-07-15 — CPU templates: amx-mask costs nothing measurable

`lib/cpu-templates/amx-mask.json` (sha256 `5dd93095…`) masks AMX/XTILE
at KVM level. D5 cost budget HOLDS (3 runs per variant, pinned
contract, cp1 firecracker): cold boot 3.31 s baseline vs 3.37 s
templated (+1.8 %, inside the baseline's own 3.31–3.49 spread); resume
31.4 ms vs 32.8 ms (+1.4 ms). Honesty: 3 runs each, not the D5-spec
N≥20 — a 20-run pass should confirm before template-by-default ships.

Proofs: userspace-CPUID prober in-guest (baseline all-ones on
amx/xtile bits, templated all-zeros — /proc/cpuinfo would lie);
template-keyed identity baked into the manifest (resume passes no CPU
config, post-restore prober still all-zeros; restore wall 24.9 ms +
14.0 ms TLS); mismatch drills refuse pre-spawn. Cross-host restore
remains UNPROVEN and gated — these numbers open the door mechanics,
not the door.

### 2026-07-14 — in-driver snapshot verbs (parallel walls)

`mkCluster { snapshotable = true; }` — store off 9p, savevm/loadvm
issued concurrently per node (monitor sockets are independent), serial
stop-all/cont-all barriers keep the consistent cut.
`checks.harness-snapshot` (2-node, 4 G VMs):

| Operation | agent | server | parallel wall |
|---|---|---|---|
| `savevm` (pristine cut) | 5.83 s | 7.78 s | **7.78 s** |
| `loadvm` #1 | 8.98 s | 12.95 s | **12.96 s** |
| `loadvm` #2 | 8.80 s | 13.27 s | **13.27 s** |

testScript total 62.35 s for one bring-up plus two full rewinds —
resets amortize against the ~28 s a pristine bring-up costs. The wall
is max(node), not sum(nodes), so a wider cluster pays one
slowest-node wall. Seconds-class by design (eager RAM load): rewind is
for amortizing subtests, not for the milliseconds path.

Same wave: per-mesh subnets (two meshes live concurrently, MESH-READY
4033 / 3973 ms uncontrolled smokes, scoped teardowns, zero leftovers)
and snapshot identity (take stamps closure/VMM/CPU triple; tampered
manifest refuses pre-spawn; combined-tree resume smoke 35.3 ms).

### 2026-07-12 — cp3 recreation gates (D8): the quorum back in ~48 ms, quorum-write-probed

Multi-server `mesh-resume`/`mesh-cycle` probe TWO things per round:
first apiserver TLS answer AND a committed etcd write (PATCH a
per-attempt-unique annotation via a *verifying* rustls client built
from the fetched admin kubeconfig — a 401 can fake TLS; only a quorum
commits a write). Live against `nix run .#cp3` (MESH-READY 6340 ms
that session; `mesh-take` cut 2.8 ms across 3 servers, snapshot 11 GB
on /dev/shm, written in 2.5 s):

| Cycle median (5) | total ms | tls ms | quorum write ms |
|---|---|---|---|
| | **47.8** | **17.9** | **97.1** |

Gates, all PASS: (1) raft term pinned at 2 across 15 reads over 5
cycles — zero elections on resume; (2) aged resumes (81 s and 630 s)
show zero Ready→NotReady flaps, zero taint churn, leases renewing at
clockstep-corrected wall time — the ~40 s node-monitor-grace hazard is
race-shaped, not eliminated: kubelet lease renewal wins on this host;
(3) a deliberately 2.0 s-skewed leader resume costs exactly ONE
pre-vote election (term 2→3, no second bump on rejoin), leader ≤377 ms
after the surviving pair, first committed write at 451 ms (cp3 runs
hb10/el100 timers, not defaults).

### 2026-07-12 — cp3 close-out: cp3w2 and failover, live-validated

cp3 pinned p50 6.545 s (7191/6545/6554/6541/6338 ms) — 1.72× the
cp1w2 mesh for a real quorum; quorum formation itself is ~120 ms
(leader 0.19 s after etcd exec). cp3w2 adds 2 workers via kubenyx-lb:
9370 / 9562 ms MESH-READY (uncontrolled singles, NOT comparable to
the pinned p50) — the extra ~2.9 s is the agent leg gating on the LB's
first healthy backend.

Failover (kill server1's VMM): reads via server2 at **+298 ms**, first
successful write **+369 ms**; kubenyx-lb evicts the dead backend at
+2.74 s on both workers (exactly the 500 ms × 3-failure policy
envelope); scheduler/kcm leader transitions 0 — leaders were never on
server1, so the leader-re-election leg remains unexercised; workers
stayed Ready; teardown exit 0 with the dead member. kcm flips the
killed node NotReady only after the ~40 s node-monitor grace —
expected k8s behavior, don't misread the Ready lines.

## Superseded history

Pruned 2026-07-21; every pruned entry is in git history
(`git log -p -- bench/RESULTS.md`): the cold-boot arc (11.85 s stock →
7.8 s → 3.4 s: perf-floor campaign, prebake, boot-path Rust tools),
the recreation arc (75 ms first restore → 66 ms productized →
~28–33 ms after TCP_NODELAY), the cp3 arc (31 s working → 6.5 s), the
pre-parallel serial savevm/loadvm walls, the 2026-07-08 mesh
recreation table (92.8 / 102.7 ms — pre-NODELAY; the current 3/7-node
numbers are the 2026-07-09 sweep's 46 / 56 ms), the TCG-era rounds
(ratio 1.01 → 0.85 → 0.76 → 0.73 and the 76.6 s TCG guest), the
2026-07-05 native baseline (superseded by the 2026-07-06 Rust-tools
numbers above), and the first-KVM-session phase tables. Mechanisms
worth keeping from those entries live in the notes section above;
their numbers do not.
