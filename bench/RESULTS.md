# Benchmark Results Log

Newest entries first. Native = bare processes on the dev box (64-core
x86_64, NVMe, no virtualization) via `nix run .#native-bench`. VM = NixOS
test driver under QEMU TCG (no KVM on this box) — absolute VM numbers are
meaningless, only kubenyx-vs-k3s ratios in identical VMs count.

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
