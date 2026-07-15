# Benchmark Results Log

Newest entries first. Native = bare processes on the dev box (64-core
x86_64, NVMe, no virtualization) via `nix run .#native-bench`. VM = NixOS
test driver under QEMU TCG (no KVM on this box) — absolute VM numbers are
meaningless, only kubenyx-vs-k3s ratios in identical VMs count. KVM =
EC2 metal (Xeon 6975P-C Granite Rapids, 384 cores, /dev/kvm): absolute
numbers are real.

## 2026-07-15 — phase 9 CPU templates: amx-mask costs nothing measurable, identity goes template-keyed

air/v0.1/snapshot/portable-snapshots.org D1–D3 landed together; single-node cp1
(firecracker, KVM host), bench contract enforced (idleness gate, cpuset
8-15, performance governor). Template: `lib/cpu-templates/amx-mask.json`
(sha256 `5dd93095…`, authored from `cpu-template-helper template dump`,
`template verify` green) — masks AMX/XTILE at KVM level: leaf 0x7.0 EDX
22/24/25, leaf 0x7.1 EAX 21 (AMX-FP16 — present on Granite Rapids,
missed by SDM recall, caught by the dump), leaf 0xD.0 EAX 17/18.

**D5 A/B cost budget — HOLDS** (3 runs per variant, medians; per-variant
snapshot dirs, both on /dev/shm):

| Wall | baseline | amx-mask template | delta | budget |
|---|---|---|---|---|
| cold boot median (3×) | 3.31 s (3.49/3.31/3.31) | 3.37 s (3.37/3.43/3.36) | +1.8% | >2% ⇒ investigate |
| resume median-of-medians (3× cycle -n 10) | 31.4 ms (30.9/31.4/33.0) | 32.8 ms (32.8/31.9/33.3) | +1.4 ms | >2 ms ⇒ investigate |

Honesty notes: 3 runs each per this session's scope, not the D5-spec
N≥20 — the +1.8% cold delta sits inside the measured idle-host
envelope (baseline's own spread was 3.31–3.49 s) but a 20-run pass
should confirm before template-by-default ships. Template application
itself is pre-boot KVM_SET_CPUID2/SET_MSRS; no boot-phase regression
visible at this resolution.

**D4 one-host proofs — all green (2026-07-15):**

- Mask proof: in-guest *userspace CPUID* prober (`pkgs/cpuid-probe.nix`;
  /proc/cpuinfo would lie — clearcpuid scrubs it kernel-side):
  baseline guest `amx_bf16=1 amx_tile=1 amx_int8=1 amx_fp16=1
  xtilecfg=1 xtiledata=1`, templated guest all-zeros. Cross-checked
  against `cpu-template-helper template dump -t` on the host (same
  bits flip, KVM level).
- Bake-in proof: take under template → manifest records
  `identity cpu template:sha256:5dd93095…` + advisory
  `identity cpu-host <fingerprint>`; the runner-rendered
  cpu-config.json is byte-identical to the committed template (same
  sha256). Resume passes no CPU config by construction — post-restore
  prober tick in resume-console.log still all-zeros. Restore wall of
  the proof run: load 24.9 ms, TLS answer +14.0 ms.
- Mismatch drills, all refuse pre-spawn: wrong `--cpu-template`
  literal; templated artifact without the flag; `--cpu-template`
  against an untemplated artifact.

Identity detection is from the live VMM's `--config-file`, never a
caller claim; template-less snapshots keep the phase 8 host-keyed
refusal unchanged (base-snap in the same session recorded the host
fingerprint, byte-for-byte the old spelling). Cross-host restore
remains UNPROVEN and gated (§D4) — these numbers open the door
mechanics, not the door.

## 2026-07-14 — phase 8 test amplification: in-driver savevm/loadvm, per-mesh subnets, snapshot identity

air/v0.1/snapshot/test-amplification.org D1–D3 landed together; numbers below are
from the combined-tree verification run (KVM host).

**D1 — `lib.harness` snapshot verbs** (`mkCluster { snapshotable = true; }`,
store off 9p via `useNixStoreImage` + `readonly=on` store drive). The
dogfood check `checks.harness-snapshot` (2-node, 4 G VMs): snapshot after
Ready, mutation proven gone after restore (real NotFound from a serving
apiserver), fresh post-restore write lands, second rewind pristine.
Seconds-class by design (eager RAM load):

| Operation | agent | server |
|---|---|---|
| `savevm` (pristine cut) | 5.44 s | 7.29 s |
| `loadvm` #1 | 8.04 s | 11.88 s |
| `loadvm` #2 | 7.58 s | 10.61 s |

testScript total 81.6 s — one bring-up plus two full rewinds; resets
amortize against the ~28 s a full pristine bring-up costs in the plain
harness check, exactly the D1 economics.

**D1 follow-up — parallel verbs (2026-07-14, same host)**: savevm/loadvm
now issue concurrently across nodes (each VM's monitor socket is
independent; one worker thread per machine, shared logger behind a
lock). The stop-all/cont-all barriers stay serial, so the consistent
cut is unchanged. `checks.harness-snapshot` re-run green:

| Operation | agent | server | parallel wall | serial-sum equiv |
|---|---|---|---|---|
| `savevm` (pristine cut) | 5.83 s | 7.78 s | **7.78 s** | ~13.6 s |
| `loadvm` #1 | 8.98 s | 12.95 s | **12.96 s** | ~21.9 s |
| `loadvm` #2 | 8.80 s | 13.27 s | **13.27 s** | ~22.1 s |

testScript total 81.6 → 62.35 s. The wall is max(node), not sum(nodes),
so this 2-node leg understates the gain: a 5-VM consumer cluster pays
one slowest-node wall where serial paid five. Drv gate: the plain
`harness` check drv stayed byte-identical; only `harness-snapshot`
moved (intended).

**D2 — per-mesh subnets**: `mkCluster { subnet = "10.101.0.0/24"; }`
derives `kubenyx-br-4c6d` + `kx-4c6d-tN`; live two-mesh smoke ran cp1w2
(default subnet, MESH-READY 4033 ms) concurrently with a 2-node mesh on
10.101.0.0/24 (MESH-READY 3973 ms), kubectl Ready against both, each
teardown scoped to its own mesh, zero leftover processes/bridges/taps.
Not a bench — the contention contract stands.

**D3 — snapshot identity**: `take` stamps the snapshot-dir manifest with
the identity triple (node closure, VMM binary, host CPU fingerprint).
Combined-tree smoke: cp1 take → identity-stamped manifest → `resume`
35.3 ms total to a serving apiserver (node Ready via kubectl); a
tampered-CPU manifest refuses before any VMM spawn, naming
field/recorded/live and the XRSTORS #GP history. Drv gate for the whole
wave: cp1w2 program + check drvs move *only* through the kubenyx-tools
`rust` src input (nix-diff verified — no rendered unit text changed).

## 2026-07-12 — cp3 recreation: the quorum back in ~48 ms, quorum-write-probed

air/v0.1/quorum/quorum-mesh.org D8 — the gated fast-follow — closed. `kubenyx-snap` grew real
multi-server support (conventional addressing now mirrors the
launcher's `mkMembers` exactly: `server`→.2 stays byte-stable,
`serverN`→.1+N, agents shift after the servers; mesh ordering is
servers-first so the probe endpoint is always server/server1) and the
honesty bar D8 demanded: a **quorum-write probe**. The old resume probe
counted ANY TLS answer — a 401 passes, which proves a listening socket,
not a quorum. Multi-server `mesh-resume`/`mesh-cycle` now also fetch
the admin kubeconfig from `:10124`, build a *verifying* rustls client
from its CA + system:masters cert (no NoVerify), and PATCH a
per-attempt-unique annotation onto the default namespace — the
apiserver cannot answer that without a committed etcd write. Both
numbers print per round; single-server output stays byte-identical.

All gates ran live against `nix run .#cp3` (MESH-READY 6340 ms this
session; `mesh-take` cut 2.8 ms across 3 servers, snapshot written in
2.5 s, **11 GB** on /dev/shm — the predicted cp3 budget; 1.5 T total /
39 G used observed before the take, back to 39 G after teardown):

| Cycle | total ms | tls ms | quorum write ms |
|---|---|---|---|
| 1 | 49.0 | 17.9 | 82.6 |
| 2 | 45.3 | 13.7 | 81.0 |
| 3 | 49.5 | 17.3 | 97.1 |
| 4 | 47.8 | 19.2 | 97.4 |
| 5 | 41.4 | 22.0 | 102.6 |
| median | **47.8** | **17.9** | **97.1** |

The predicted envelope (~45 ms + ≤150 ms to the first committed write)
holds.

**Gate 1 — no term bump across 5 cycles: PASS.** Raft term read after
every cycle via etcd's grpc-gateway `/v3/maintenance/status` on every
server's `:2379` (the admin kubeconfig's system:masters cert works
there — one launcher CA signs both planes): term pinned at **2** on all
15 reads, leader never moved, zero elections. Method note: this ran as
5× `mesh-resume` + kill rather than the `mesh-cycle` verb — the term
must be read while each round's mesh is live and cycle has no
between-round hook; the measured code path is byte-identical to
cycle's rounds.

**Gate 2 — aged resume, no node flaps: PASS.** Snapshots aged 81 s and
630 s, then 60 s of 1 s-cadence observation plus an event/lease audit
after each resume: zero Ready→NotReady flaps, zero taint churn, zero
NotReady/unreachable events, `lastTransitionTime` untouched, leases
renewing at clockstep-corrected wall time (resume totals 35.1 / 53.5 ms,
quorum writes 84.5 / 90.8 ms). The ~40 s node-monitor-grace hazard —
latent on the cp1 meshes too, never tested until now — never trips:
kubelet lease renewal wins the race. That's race-shaped, not
eliminated; a heavily contended host could still lose it.

**Gate 3 — deliberately skewed resume: PASS.** The raft leader
(server3) resumed 2.0 s behind the other two via raw firecracker
`/snapshot/load` calls (the tool has no skew flag and deliberately
didn't grow one). Two runs, both: exactly **one** election (term 2→3),
and NO second bump when the old leader rejoined at ~2.03 s — etcd 3.6
pre-vote held. Leader elected ≤377 ms after the surviving pair resumed
(poll-quantized: true completion lies in (29, 377] ms), first committed
write at **451 ms** — far under the doc's 1–1.3 s guess, because cp3
runs hb10/el100 timers, not defaults.

Volatile-only is now *enforced*, not documented: the cp3 launcher
writes a run manifest (members + posture) and multi-server `mesh-take`
refuses loudly on durable posture OR a missing manifest, before any
firecracker API call — firecracker snapshots exclude virtio disk
contents, so a durable quorum resumed against a mutated disk corrupts;
cp3's tmpfs state rides inside `snap.mem` exactly like etcd-mem did.

Bench conditions: shared 384-core box; recreation medians are
same-snapshot, same-session medians in the same band as the 2026-07-09
mesh numbers (~45 ms) — cross-entry deltas of a few ms are inside box
noise. Drv gate held: a worktree carrying only the lib/microvm.nix
change builds cp1w2 to the identical store path; the rust change
necessarily moves the embedded kubenyx-tools in guests (true of ANY
kubenyx-snap change), launcher text diff confirmed to be only the
embedded runner paths.

## 2026-07-12 — cp3: honest 3-CP quorum mesh, 31 s → 6.5 s

air/v0.1/quorum/quorum-mesh.org closed. `nix run .#cp3` boots a 3-control-plane
firecracker mesh with a REAL 3-member etcd quorum (volatile, tmpfs,
launcher-minted per-run CA). Phase 2 landed it working at **29.9–31.2 s**
MESH-READY; phase 3 instrumented first (a mesh-only journal-dump oneshot,
placed after kubenyx-report so observation sits outside the measured
window), then attacked in evidence order.

Final five consecutive boots under the contention contract (governor +
idleness gate + pinning, per the 2026-07-09 perf-floor entry — shared
384-core box, pinned numbers only comparable to pinned numbers):
**7191 / 6545 / 6554 / 6541 / 6338 ms** MESH-READY, p50 **6545 ms** —
**1.72×** the cp1w2 mesh (3.8 s) for a real quorum; cp1 reference 3.4 s.

**Where the 31 s actually lived** — not in the quorum (~120 ms formation;
leader elected 0.19 s after etcd exec on hb10/el100):

| Cost | Mechanism | Fix |
|---|---|---|
| ~13 s (default-15 meshes; 3 s on the cp3 preset) | etcd join-probe window fully burned on every fresh boot — nobody serves yet, so every server waits out the whole window | **D3 fast-exit**: peers TCP-classified before the health RPC (curl rc 7 = active refusal = fresh peer; rc 28 = silence = hold the window, skip the doomed 2 s etcdctl dial). Five 0.5 s-spaced all-refused sweeps ⇒ "everyone is fresh", bootstrap declared/new immediately; the streak span still exceeds the RestartSec=2 crash-refuse window and the member-set fingerprint guard bounds the partition blast radius |
| ~19 s addons-to-READY (coredns spread 11.9/19.0/22.6 s) | TWO client-go backoff quantizations inside kubelet — the node-registration retry ladder (2.4/2.6/3.0/3.8/5.4/8.6 s attempts straddling apiserver-up) and a 2.5 s node-informer re-list backoff AFTER successful registration. Everything else eliminated with evidence: addons applied first try 9/9, no lease contention, no coredns crash-loop, ca-fetch 0.35 s not 2 s | mesh-server kubelet gains an ExecStartPre `kubenyx-ready --wait` on the EXACT node-informer request — kubelet starts ~40 ms after its own apiserver serves, both ladders vanish, READY spread across servers tightens to 0.05 s. (Landmine: `%3D` in ExecStartPre is a systemd specifier and SILENTLY drops the gate — raw `=` only.) Same twin gate on coredns: convergence 9.4–10.8 s → ~6.0 s |

**D4 verdict — no etcd patch.** The host bench had shown a 1–2 s
BootstrapTimeout tail in 10–27% of launches (etcd's member probe
TCP-connects to a bound-but-not-serving peer listener and hangs the full
1 s default). In-guest: **0/8 bootstraps showed the tail** — the D3
fast-exit synchronizes founders within ~130 ms, so peer probes hit
connection-refused, which is etcd's fast path. The host tail was an
artifact of staggered starts; the patch would have been maintenance
liability for a phantom. A future topology staggering founders >1 s
revisits this (the why-not lives in the probe comments).

**cp3w2 (+2 workers via kubenyx-lb) and failover, live-validated:**

| What | Measured |
|---|---|
| cp3w2 MESH-READY nodes=5 | 9370 ms / 9562 ms (two boots; uncontrolled singles — no contract pinning, indicative only, NOT comparable to the pinned cp3 p50) |
| the extra ~2.9 s over cp3 | the agent leg: worker kubelets gate on kubenyx-lb's first healthy backend (~8.5 s); the server quorum leg matched cp3's envelope (CLUSTER-READY spread 7.55–7.56 s) |
| kill server1 (`pkill -f '^microvm@server1'`) | reads via server2 back at **+298 ms**, first successful write at **+369 ms**, cross-read via server3 OK |
| kubenyx-lb evicts the dead backend | +2741 / +2737 ms on the two workers — the policy envelope exactly (500 ms probes × 3 failures); cross-clock measurement, but guests are clockstepped at boot so ms-accurate in practice |
| leader leases | scheduler on server2, kcm on server3, transitions **0** — leaders were never on server1, so the re-election leg is vacuously satisfied; a leader-on-the-killed-server run remains unexercised |
| workers | Ready at +5/+15/+30 s and stayed Ready; kcm flipped server1 NotReady only after the ~40 s node-monitor grace (expected k8s behavior, don't misread the Ready lines) |
| teardown | exit 0 twice — including once with server1 already dead (ladder skips the dead VMM cleanly); zero firecracker / pki-serve survivors, iptables 10123 rule + CA bundle reaped |

Second boot after the failover run: fresh write OK, the failover-era
configmap absent — fresh trust root + state, no leftover dependence.
Evict/kubeconfig evidence was extracted through the SURVIVING quorum via
a node-pinned forensics pod (hostPath /nix/store + journalctl against
the guest journal) — itself a post-failover scheduler→kubelet→lb→apiserver
datapath proof.

Also landed: `checks.quorum-volatile` (20th leg, 34 s) — the cp3 posture
in the NixOS driver with the driver playing the launcher (mint-ca +
custody pre-seed), proving the require-shipped-ca gate refuses BEFORE
the ship, quorum on tmpfs with no /var/lib/etcd, the D3 fast-exit
firing (2/3 servers in the green run; the third legitimately held the
window and took the rejoin path), 3/3 Ready, and a cross-server
write/read. Gate held throughout: single-node and cp1w2 drvs
byte-identical after every change, re-verified from git+file:// at
close-out.

## 2026-07-09 — Recreation micro-pass: TCP_NODELAY kills a ~40 ms Nagle stall, 66 → ~32 ms

The parked kubenyx-snap fixed-cost pass (perf-floor.org item 3),
host-tool changes only — zero guest bytes. A/B protocol: alternating
`cycle -n 5` (single) / `mesh-cycle -n 5` (3-node mesh) runs against
the SAME snapshot, observation = the run's median_total_ms, ≥6 pairs,
judged by paired median; pinned (`taskset -c 8-15` single, `8-31`
mesh), governor + idleness contract as everywhere else.

Kept (paired A/B in the commit message):

| Change | Paired A/B |
|---|---|
| `TCP_NODELAY` on the apiserver probe socket | **+36.8 ms** over 6 pairs, 6/6 faster (66.0–73.5 → 29.7–37.1); the dominant slow mode was the probe's TLS handshake parked on Nagle/delayed-ACK for ~40 ms — load_to_api collapses 50 → 12–15 ms. Dense 5 ms time-pokes had already ruled out clock-gating (mode unmoved). |
| probe poll 3 → 1 ms | +0.5 ms over 10 pairs (mechanism-consistent: mean residual sleep 1.5 → 0.5 ms) |
| `cycle` prints spawn_to_sock_ms per round | observability only, covered by the cumulative A/B |

Tried and REJECTED: sock-wait poll 200 → 50 µs (+0.1 ms paired on
spawn_to_sock — a segment excluded from the tool's own total — with a
noise-level −2.3 ms paired read on total; microseconds, ambiguity, no);
mesh probe overlapped with agent load tails via a server-loaded signal
(−0.6 ms paired over 6 pairs, 3/6 — server load returns ~6 ms before
the agents and post-NODELAY there is nothing left to hide).

**Cumulative** (final vs campaign base, same snapshots): single paired
median **+38.4 ms**, 6/6 faster (65.9–72.3 → 28.5–33.2 run medians);
mesh paired median **+40.8 ms**, 6/6 faster (76.7–84.7 → 41.8–44.9).

Re-validated from the committed rev (nix-built tool + runners):
fresh `take` (snapshot written in 1.84 s) + `cycle -n 5` → 5/5, median
**31.9 ms** (24.5–53.2; round 1 is the cold-ARC outlier); launcher-booted
3-node mesh (MESH-READY 4.0 s) + `mesh-take` (2.6 s) + `mesh-cycle -n 5`
→ 5/5, median **43.9 ms** (39.0–59.2).

## 2026-07-09 — Performance floor: profiled attack, cold boot 7.3 s → 3.4 s

air/v0.1/perf/perf-floor.org rules of engagement executed: instrumented
ranked costs, attacked in rank order, every change judged by an
interleaved paired A/B (alternating order, paired median or revert) on
the in-guest `KUBENYX-CLUSTER-READY` marker, single-node +
multi-node-mem legs green after each keep. Instruments: probe-variant
`systemd-analyze time/blame/critical-chain` + short-monotonic journals
over the autologin console, host-timestamped console markers, in-guest
poll probes, host reachability probes, `kubenyx-snap cycle`.

**The bimodality is the host, not the guest** (profiler, confirmed
here): byte-identical runner booted 3.52 s and 5.36 s seven minutes
apart; a sibling cargo-test storm spanned exactly the slow window; 320
synthetic busy threads reproduce 8.07/13.90 s with uniform ~2.3×
dilation of every phase; drop_caches changes nothing (ZFS ARC serves
the store). Consequence is a bench CONTRACT, not a guest patch —
`bench/microvm-boot.sh` / `bench/microvm-ab.sh` now enforce:
performance governor on all cpus; an idleness gate (min-of-3 runnable
samples > 16 ⇒ refuse, measured refusing at runnable=324 under the
storm); VMM pinned to one L3 neighborhood (`taskset -c 8-15` — itself
+0.16 s paired median over 6 pairs vs free placement on an idle host,
envelope 3.30–3.49 vs 3.38–3.73). Pinned numbers are not comparable to
pre-contract logs. Under the off-range storm pinning helps but does
not immunize (4.61 s vs 5.12 s free): frequency/LLC bleed — the gate
is the primary control.

Keeps this campaign (each with its A/B in the commit message; console
TERM=dumb ~2×1.0 s, PID1 mount-dispatch unthrottle ~2×0.95 s, report
probe 50 ms, microVM prebake +0.035 s landed earlier in-campaign):

| Rank | Change | Paired A/B (prior/new) |
|---|---|---|
| 0 | udev coldplug scoped to net+tty (undoes the mask rev's DEAD tap networking + 90 s ttyS0 hang; virtio_net pinned into initrd — pci replay in stage 2 is a legacy-probe storm, 3.5 s → 32 s) | +0.08 s over 6 pairs vs mask, 3.57→3.48 raw; vs full revert −0.01 s (tie) but envelope 3.44–3.62 vs 3.48–3.93; ping 3/3, :10124=200, :6443=401, snap resume 5/5 median 77.9 ms |
| 1 | bench contention contract (host-side only, zero guest bytes) | pin +0.16 s/6 pairs idle; gate refuses runnable=324 |
| 2 | report probes over ONE persistent TLS session (`curl --rate 20/s` URL-list; fork+handshake per 50 ms leaves the boot) | +0.055 s over 10 pairs, 9/10 faster 0 slower, 3.41→3.35 raw |
| 3 | kcm ExecStartPre gate on the exact configmap GET it crashed on (`kubenyx-ready --wait`, 10 ms fork-free) | +0.015 s over 10 pairs marker (kcm is off the marker path); kcm crash 10/10 → 0/10, functional 5.26 s → 3.61 s |

Tried and REJECTED (numbers in perf-floor.org History): stage-2
udev-trigger blanket mask (its +0.110 s was partly networkd doing
nothing — host-facing networking dead, resume blocked);
`nodes?watch=1` readiness probe (watch first-frame lands seconds late
during bring-up: node Ready 3.03 s, match 5.61 s ⇒ 5.4–5.6 s boots;
plus `curl -N | grep -q` sits ~2.9 s after match waiting for SIGPIPE).

**Cumulative** (final vs campaign base = pre-perf-floor prebake rev,
8 pairs, contract harness): paired median **+3.875 s**, final faster
8/8 — 7.42/3.47 7.25/3.40 7.26/3.43 7.31/3.41 7.31/3.46 7.30/3.44
7.31/3.42 7.25/3.31; raw medians **7.305 s → 3.425 s**. kcm now joins
crash-free at ~3.6 s; kubenyx-snap recreation re-validated at median
77.9 ms/5 cycles.

## 2026-07-09 — Pre-baked image stores: 99.7% of import cost becomes a mount

air/v0.1/perf/prebake.org implemented — the last phase 4 item. The seed set
(pause + seedImages, both formats) is imported into a containerd
content store at BUILD time (`pkgs/prebake-store.nix`: containerd
2.3.1 `--root $out` in the sandbox, CRI/runtime plugins disabled,
sockets owned via config uid/gid) and overlay-mounted under
`/var/lib/containerd` with a tmpfs upper; `kubenyx-seed-images`
disappears from the boot path entirely.

Two forced calls, both probed rather than assumed:

- **The bake is `--no-unpack`** (content blobs + bolt metadata, no
  snapshots): unpacking needs a bind mount even for the native
  snapshotter and mount(2) is EPERM in the build userns (probe kept in
  the doc); nix store normalization (0444/0555, uid 0) would corrupt
  snapshot dirs anyway. Blobs are opaque tars — immune.
- **The guest runs the `native` snapshotter when prebake is on**: the
  kernel rejects an overlay upperdir living on an overlayfs — exactly
  what the overlayfs snapshotter would create under the mounted store
  (in-guest failed-mount probe in `tests/prebake.nix`). Layers unpack
  lazily at first use into the tmpfs upper (CRI unpacks non-unpacked
  images on sync; pods run from baked images of both seed formats).

| Leg | Proves | Wall |
|---|---|---|
| `prebake-bench` | 10×30 MB AES-CTR layers (incompressible): in-guest import wall 23.304 s vs prebaked mount 0.063 s — **99.7% eliminated** (contract ≥90%) | 38.5 s |
| `prebake` | seed unit ABSENT; baked refs listed with zero imports; pods from baked images; unpack lands in tmpfs upper; overlay-upper probe fails as recorded | 35.3 s |
| `local-storage` | prebake OFF unchanged (seeds both formats at boot) | 84.6 s |

Gate: default-config eval dump (85 unit texts + built-unit store
paths, 97 etc sources, tmpfiles) identical; microvm-firecracker runner
**bit-identical store path** base vs implementation. Cluster-ready
unregressed by the overlay: interleaved firecracker A/B, 6 pairs,
paired median **−0.17 s with prebake ON** (on faster in 4/6 pairs —
the vanished seed unit offsets the mount + native COW; raw medians
7.98/8.08 s sit inside the box's bimodal envelope).

## 2026-07-09 — IPv6 single-stack: all-v6 clusters, v4 path bit-identical

air/v0.1/network/ipv6.org implemented in one campaign. The sizing insight
held: the runtime layer was already family-agnostic (kubenyx-pki,
component flags, CoreDNS) — everything landed in the eval layer:

- `lib/`: hextet-wise v6 CIDR math (never one 128-bit number — Nix
  ints are signed 64-bit): `::` expansion, carry-propagating add,
  RFC 5952 rendering; node N owns the Nth /64 of the cluster prefix.
  **29 eval-level unit tests as `checks.lib-tests` (~1s, no VM)** —
  CIDR math regressions now cost seconds to catch, forever.
- Family-switched dataplane: NAT66 ip6 nftables (family-matched
  ExecStop — a v6-only bug caught at eval before any VM run),
  ip6tables accepts, `ip -6 route` carve, v6 forwarding sysctls.
- Bracket audit: every address-into-URL site routed through
  `klib.hostPort` (apiserverUrl, etcd quorum URLs, kubenyx-lb
  backends, guest hint sites); bare-address flags stay bare.
- Single-family assertion: mixing clusterCidr/serviceCidr/node
  address families is a clear eval error. Dual-stack rejected.

| Leg | Proves | Wall |
|---|---|---|
| `lib-tests` | 29 CIDR/hostPort cases, pure eval | ~1 s |
| `ipv6` | Single node all-ULA: pod IP in the carved /64, v6 service VIP + DNS, live ip6 NAT/filter | 36–39 s |
| `ipv6-multi` | server+agent: bracketed `https://[fd00:1::2]:6443` join (grepped from the rendered kubeconfig), cross-node pod-to-pod over `ip -6` routes | 40–41 s |

Design note recorded in the test: `dns.address` lives OUTSIDE the
service CIDR (own ULA), mirroring the v4 default's design — the
nftables kube-proxy drops unallocated ClusterIPs inside the CIDR.

Gate — the strongest identity result of any campaign: the
microvm-firecracker runner and system toplevel are **bit-identical
store paths** base vs final, despite an 833-insertion diff across 8
modules — the family switch fully cancels on the v4 default path, so
the cold-boot A/B was degenerate (regression impossible by
construction; raw medians 8.61/8.35/7.49 s were the box's known
bimodal envelope). Six-leg sweep green: lib-tests, ipv6, ipv6-multi,
single-node, external-cni, multi-node.

## 2026-07-08 — phase 4 tier-1: bring-your-own-dataplane, gate held

Three hand-offs landed (air/v0.1/hosts/byod.org), each replacing a kubenyx
opinion with a clean absence, each proven by its own test leg and an
eval-level byte-identity dump of the default path (all 85 systemd unit
texts + built-unit store paths + all 97 environment.etc sources):

| Capability | Leg | Wall |
|---|---|---|
| `network.cni = "external"` — conflist ABSENT (containerd loads the lexically first conflist, so a stub would still shadow the external CNI), routes/NAT gone, firewall accepts interface-free | `external-cni` | 38–47 s |
| `storage.localVolumes` — no-provisioner default StorageClass + declared local PVs via the addons applier; WaitForFirstConsumer honored, data survives pod recreate | `local-storage` | 85 s |
| `seedImages` archive branch — non-executable OCI/docker tars via `ctr import`; coverage rides the storage leg | (same leg) | — |

Gate: unit list identical (295 entries); the ONLY delta on the whole
recursive /etc diff is the documented seed-script `[ -x ]` branch hash.
Cold boot: raw 3-run median 8.36 s tripped the 8.2 s bar → the
interleaved A/B protocol settled it (post-campaign faster in 4/6
paired rounds, paired median −0.14 s; combined 9-boot median 8.07 s).
Sweep green: single-node 61 s, external-cni 47 s, local-storage 85 s,
multi-node-mem 37 s.

## 2026-07-08 — Mesh recreation: 7-node cluster in 103 ms

`kubenyx-snap mesh-take` / `mesh-resume` / `mesh-cycle` extend the
snapshot flow to whole meshes. The consistency model: pause EVERY node
before snapshotting ANY (the cut lands in 4.1 ms across 3 nodes) —
monotonic clocks freeze together so the guests never observe it, and
cross-VM TCP survives restore because both endpoints resume. Verified:
after each restore `kubectl get nodes` shows every node Ready with the
original kubelet connections intact, and every guest clock is stepped
to the second (per-node UDP pokes, off the measured path).

| Cluster | Cold boot (launch→all-Ready) | Recreation (5-cycle median) | Snapshot take |
|---|---|---|---|
| 1 node | 7.8 s | 66 ms | 2.7 s (3.5 GB) |
| 3 nodes | 8.13 s | **92.8 ms** (58–102) | 3.0 s parallel (11 GB) |
| 7 nodes (`.#microvm-cluster7`) | 8.96 s | **102.7 ms** (58–109) | 2.6 s parallel (25 GB) |

Both axes are ~flat in node count: cold boot because nodes boot in
parallel (the wall is the server's own chain), recreation because
restores are per-tap-independent VMMs demand-paging from tmpfs — 7
concurrent loads finish in ~40 ms, barely above a single one. The
per-round breakdown: all-loaded ~35–45 ms + first apiserver TLS answer
~20–66 ms.

One measurement bug caught and fixed while building this: the clock
pokes (5 × 100 ms sleeps) sat inside the measured path, inflating
every mesh round by ~400 ms and quietly inflating the single-VM
`resume` wall too (reported totals were honest, but the tool held the
caller ~400 ms longer than needed). Pokes now ride a parallel thread
overlapping the API probe, joined before return.

## 2026-07-08 — Multi-node campaign complete: fast path held, HA proven

The phase 2 mesh + phase 3 durable/HA work landed as one campaign
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

`nix run .#microvm-cluster` (air/v0.1/microvm/multinode-microvm.org §2–4): 1 server + 2 agent
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
cost). Full findings + kubenyx-snap design: air/v0.1/snapshot/snapshot-restore.org.

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
