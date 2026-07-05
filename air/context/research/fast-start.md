# Research: Fast-Start & Lean-Footprint Techniques (2026-07-05)

Raw research report from the fast-start research pass.

## 1. How k3s does it — transferability

- Single process (shared Go runtime/informers/TLS): **NOT transferable**.
- Removed in-tree cloud providers/legacy: since k8s 1.31 upstream removed in-tree cloud providers anyway — stock binaries already have most of the code-stripping. Stock equivalents: no --cloud-provider, trim KCM --controllers.
- kine instead of etcd: **transferable** (k3s runs apiserver with --etcd-servers=unix://kine.sock).
- Bundled addons (traefik/servicelb/metrics-server) are what makes k3s *heavier* at idle than assumed.

## 2. kine deep dive

- Standalone use with stock apiserver is first-class ("Can be ran standalone so any k8s can use Kine"). Implements KV/Watch/Lease/Cluster subset of etcd v3 gRPC.
- Key flags (pkg/app/app.go): --listen-address (unix:// supported; k3s/k0s use unix sockets), --endpoint (empty => SQLite), --compact-interval **0 default = off, "so that compact may be managed by the apiserver"** (k0s passes 0 explicitly), --watch-progress-notify-interval 5s (needed for apiserver consistent reads), --emulated-etcd-version 3.6.x (apiserver feature-detects on it), --poll-batch-size 500 (watch = SQL log polling), --metrics-bind-address :8080 (0 disables).
- Wiring confirmations: k3s; k0s (`--etcd-servers=unix://<KineSocketPath>`, kine launched with `--endpoint <dsn> --listen-address unix://<sock> --compact-interval 0`); Martin Heinz kubeadm+Postgres walkthrough.
- Conformance: k3s CNCF-certified across backends incl. sqlite; MySQL path had failures (k3s #10023); sqlite best-tested. kine emits no etcd db-size metrics.
- Performance: vCluster load tests — 300 secrets @30qps: sqlite 0.17s vs etcd 0.05s API response; 5000 @200qps: 1.4s vs 0.35s; sqlite = higher CPU under load but significantly less RAM. k3s resource profiling: total server RAM nearly identical kine vs embedded etcd (1596 vs 1606 MB) — the win is process floor + fsync behavior + startup, not order-of-magnitude. Watch-heavy workloads (Knative) hurt kine/sqlite (k3s #5033). No multi-master with sqlite.
- **Keep apiserver watch cache ON with kine** — disabling multiplies SQL polling.

## 3. k0s — closest prior art (stock binaries + custom supervision)

Verified from k0sproject/k0s@main pkg/component/controller/*.go:

apiserver defaults: allow-privileged=true; requestheader-extra-headers-prefix/group/username headers; secure-port 6443; **anonymous-auth=false**; authorization-mode=Node,RBAC; **enable-admission-plugins=NodeRestriction (only ONE beyond defaults)**; profiling=false; tls-min-version=VersionTLS12; service-account-issuer=https://kubernetes.default.svc; endpoint-reconciler-type=none when disabled; --etcd-servers=unix://<kine.sock>. k0s does NOT trim runtime-config or admission below defaults — leanness = supervision + kine + not running things (no CCM; controllers run no kubelet).

KCM defaults: allocate-node-cidrs=true; bind-address=127.0.0.1; controllers=*,bootstrapsigner,tokencleaner; leader-elect=true (false in --single); use-service-account-credentials=true; profiling=false; terminated-pod-gc-threshold=12500; node-cidr-mask-size 24.

Scheduler: bind-address=127.0.0.1, leader-elect (false single), profiling=false.

Kine supervision: dedicated user; readiness = write/read /k0s-health-check key via etcd client over socket. apiserver readiness = poll /readyz?verbose with admin client cert. Good recipes for systemd readiness gates.

etcd supervision: near-stock args; --enable-pprof=false; no snapshot/compaction tuning.

--single: no leader election, no konnectivity. Konnectivity only needed because k0s controllers lack kubelets — **not needed on flat networks** (kubeadm doesn't run it). --disable-components list incl. metrics-server, coredns, kube-proxy etc.

## 4. etcd small-cluster tuning

- --unsafe-no-fsync (ETCD_UNSAFE_NO_FSYNC): dev/ephemeral only; removes dominant latency term.
- --snapshot-count: v3.5 default 100k; **v3.6 reduced default to 10k** — part of v3.6's ">=50% memory reduction" + ~10% throughput gain + safe downgrade support. On 3.5 set 5000-10000 manually.
- Compaction: apiserver already compacts every 5m; etcd-side can stay off/coarse (k3s/kine same stance).
- Memory reality: etcd caches full keyspace + index; small-DB ballooning reported (350MB RSS for 60MB DB; pathological 6GB). Fresh cluster idles 50-150MB.
- tmpfs /var/lib/etcd: established for CI/dev (kind #845, DevStack). Durability = none across power loss.
- MicroShift productizes **GOMEMLIMIT on etcd** (etcd.memoryLimitMB, min 128MB; near-min slows queries).

## 5. apiserver/controller startup & lean flags

- Bare apiserver reaches serving in ~2-10s on fast hardware (envtest budget 20s; slow machines 90s observed).
- OpenAPI v2 marshal is lazy since kube-openapi #251 (~35% memory saved pre-first-hit). Aggregation controller single-threaded — **broken/unneeded APIServices cost startup CPU + latency; don't register aggregated APIs you don't need**.
- --runtime-config <group>/<v>=false: fewer storage/watch caches, smaller OpenAPI. Safe-ish: batch/v1 (if also disabling job/cronjob/ttl controllers + no Jobs), autoscaling/*, policy/v1. KEEP: apps/v1 (CoreDNS), networking.k8s.io/v1, rbac, **coordination (kubelet heartbeat leases!)**, discovery.k8s.io (EndpointSlice — kube-proxy), storage.k8s.io (kubelet CSI). Pair disabled groups with --controllers=-foo or KCM error-loops.
- Admission: k0s adds only NodeRestriction; can disable webhook plugins + PodSecurity for dev; startup impact small.
- --enable-priority-and-fairness=false: saves APF bookkeeping; loses overload fairness — acceptable single-tenant. 
- --goaway-chance: keep 0 (docs: single-apiserver should NOT enable; 0.001 cost ~8% throughput).
- Watch cache: keep on (esp. with kine); sizes dynamic since 1.19.
- --emulated-version (KEP-4330): safe binary upgrades/rollbacks for nix-store flips; not a latency tool.
- KCM: --controllers foo/-foo trim; **--leader-elect=false = one of the biggest single-node startup wins** (also scheduler).
- Ordering gotcha: k3s #4340 — scheduler-vs-node-taint race added ~75s backoff (50s -> 135s ready). Ordering matters more than raw speed: gate scheduler/workloads on node readiness or accept backoff.

## 6. Memory footprints (real numbers)

- k3s resource profiling: server+workload 1596MB (sqlite) / 1606MB (etcd); agent 275MB.
- Portainer (1GB VMs, whole OS idle): k0s 658MB, k3s 750MB, MicroK8s 685MB; 2GB practical floor.
- ICPE'23: MicroK8s 1103MB, k3s 757MB, k0s 847MB idle; controller CPU idle 12.5-20.4%.
- **Sidero: vs kubeadm baseline at idle — k3s +15%, k0s ~same, RKE2 +150%. Stock separated components are NOT the memory loser; a stripped stock control plane can beat k3s.**
- Rough per-component idle RSS: apiserver 250-500MB, etcd 50-150MB, kcm 60-120MB, scheduler 20-50MB, kubelet 70-120MB, containerd 30-80MB.
- GOMEMLIMIT/GOGC: k8s-1m recommends GOMEMLIMIT 10-20% under available + GOGC few hundred for apiserver/etcd (fewer GC cycles); inverse (low GOMEMLIMIT, default GOGC) trades CPU for smaller floor (MicroShift's approach). Set via systemd Environment= — touches nothing in-tree.

## 7. Boot-to-ready

- kubeadm: image pulls dominate cold start (up to 4min allowance); pre-pulled ~30-60s (certs + static pods + healthz waits).
- k3s: ~50s to all pods Ready normal; regression to 135s from taint race.
- kind: preloaded images -> 20-40s.
- **Structural advantage of nix-store systemd control plane: zero control-plane image pulls, zero static-pod circularity, parallel systemd start. Remaining terms: PKI gen (<1s target), apiserver serve (2-5s), kcm/sched informer sync (1-3s with leader-elect off), kubelet register + CNI, first workload pulls (preload coredns via ctr import). Sub-15s boot-to-Ready plausible.**

## 8. Transferability matrix

single-binary: no. kine+sqlite: yes (k0s-proven). in-process cert gen: yes (oneshot). leader-elect off / no konnectivity / no CCM / KCM controllers trim / runtime-config trim / admission trim: yes (all flags). etcd tmpfs / unsafe-no-fsync / v3.6 / GOMEMLIMIT: yes. preloaded images: yes — Nix does it better than anyone.

Sources: k0s component sources (verified), kine app.go/README, docs.k3s.io resource-profiling & architecture, vcluster load tests, Portainer & ICPE'23 & Sidero comparisons, etcd v3.6 announcement, KEP-4330, k8s-1m, MicroShift etcd docs, k3s #4340/#5033/#10023, kind #845.
