# Research: Control Plane, PKI & Bootstrap (2026-07-05)

Raw research report from the control-plane research pass.

## 1. Minimal PKI

### kubeadm reference layout (superset to prune from)

3 CAs under /etc/kubernetes/pki: cluster CA (`kubernetes-ca`), etcd CA, front-proxy CA.

Leaf certs (CN / O / kind / signer / SANs):

| File | CN | O | Kind | Signer | SANs |
|---|---|---|---|---|---|
| apiserver | kube-apiserver | — | server | cluster CA | see below |
| apiserver-kubelet-client | kube-apiserver-kubelet-client | (modern kubeadm: kubeadm:cluster-admins) | client | cluster CA | — |
| front-proxy-client | front-proxy-client | — | client | front-proxy CA | — |
| apiserver-etcd-client | kube-apiserver-etcd-client | — | client | etcd CA | — |
| etcd server/peer | kube-etcd / kube-etcd-peer | — | server+client | etcd CA | host, IP, localhost, 127.0.0.1 |
| sa.key / sa.pub | — | — | keypair, not a cert | — | — |

Kubeconfig identities (client certs from cluster CA):

| kubeconfig | CN | O |
|---|---|---|
| admin | kubernetes-admin | kubeadm:cluster-admins (pre-1.29 system:masters) |
| super-admin | kubernetes-super-admin | system:masters (break-glass, bypasses RBAC) |
| kubelet | system:node:<nodeName> | system:nodes |
| controller-manager | system:kube-controller-manager | — |
| scheduler | system:kube-scheduler | — |

CNs are load-bearing: built-in ClusterRoleBindings key on exactly these names; Node authorizer keys on system:nodes group + system:node: CN prefix. Avoid system:masters for anything long-lived (irrevocable without CA rotation).

### apiserver serving SANs

kubernetes, kubernetes.default, kubernetes.default.svc, kubernetes.default.svc.<clusterDomain>; **first IP of service CIDR** (e.g. 10.96.0.1 — forgetting it is THE classic failure); node advertise IP + hostname; 127.0.0.1/localhost for loopback clients; any LB/VIP for multi-node.

### Pruning for a pragmatic Nix setup

- **One CA suffices for cluster + etcd** (separation is defense-in-depth, not functional).
- **Front-proxy CA MUST be distinct from client CA when used** (spoofing risk otherwise) — but it's skippable entirely until the aggregation layer is wanted (metrics-server / kubectl top). Adding later = apiserver restart only. apiserver publishes extension-apiserver-authentication ConfigMap from these flags.
- **etcd localhost plaintext**: fine single-node (KTHW current edition does this); any local process can read secrets — acceptable tradeoff, or keep etcd TLS. etcd itself does NOT support unix sockets; kine does.
- One client cert per identity, all from one CA (cheap in Nix; keeps least-privilege).
- apiserver->kubelet client cert: kubelet authorization.mode=Webhook delegates to apiserver SAR; bind cert user to system:kubelet-api-admin ClusterRole.

**Minimal viable set (secure single-node):** ca; apiserver serving; apiserver-kubelet-client; sa.key/sa.pub; client certs for admin/kcm/scheduler/per-node kubelet; kubelet serving cert (+ apiserver --kubelet-certificate-authority=ca.crt); etcd nothing (localhost) or full etcd PKI multi-node; front-proxy deferred.

### Rotation

- kubelet client rotation: rotateCertificates: true; renewals auto-approved via system:certificates.k8s.io:certificatesigningrequests:selfnodeclient bound to system:nodes (must create binding).
- kubelet serving rotation: serverTLSBootstrap + RotateKubeletServerCertificate — but kubelet-serving CSRs are NEVER auto-approved upstream (need kubelet-csr-approver or manual). => pre-generate serving certs in Nix instead. (Also k8s#138763: 1.34 kubelets occasionally skip serving rotation.)
- Control-plane certs: no built-in rotation — regenerate via Nix + restart. kubeadm defaults: leaf 1y, CA 10y; --cluster-signing-duration default 8760h.
- CSR approving/signing controllers on by default in KCM; signing needs --cluster-signing-cert/key-file.

## 2. Component flags

### kube-apiserver (minimal-secure)

```
--advertise-address=<node-ip> --secure-port=6443
--allow-privileged=true
--authorization-mode=Node,RBAC          # default is AlwaysAllow!
--client-ca-file=ca.crt
--tls-cert-file=apiserver.crt --tls-private-key-file=apiserver.key
--kubelet-client-certificate/... --kubelet-certificate-authority=ca.crt
--etcd-servers=http://127.0.0.1:2379    # or https+etcd certs; unix:// works (kine)
--service-cluster-ip-range=10.96.0.0/16
--service-account-issuer=https://kubernetes.default.svc.cluster.local
--service-account-key-file=sa.pub --service-account-signing-key-file=sa.key
--enable-admission-plugins=NodeRestriction   # NOT default; required companion to Node authorizer
```

SA trio mandatory since bound-token GA. Default admission set (1.36-era) includes PodSecurity, ValidatingAdmissionPolicy etc.; safe to disable in minimal setups: DefaultIngressClass, DefaultStorageClass, PersistentVolumeClaimResize, StorageObjectInUseProtection, ResourceQuota/LimitRanger if unused. Never disable ServiceAccount, NamespaceLifecycle, TaintNodesByCondition, Priority.

Other: --enable-bootstrap-token-auth (only for TLS bootstrap), --event-ttl (default 1h; 10m for dev), --anonymous-auth default true (health endpoints; 1.31+ AnonymousAuthConfigurableEndpoints can restrict to health only), --profiling=false.

RBAC for apiserver->kubelet: bind its user to system:kubelet-api-admin.

### kube-controller-manager

```
--kubeconfig/--authentication-kubeconfig/--authorization-kubeconfig=controller-manager.conf
--client-ca-file=ca.crt --root-ca-file=ca.crt
--service-account-private-key-file=sa.key
--cluster-signing-cert-file=ca.crt --cluster-signing-key-file=ca.key
--use-service-account-credentials=true
--allocate-node-cidrs=true --cluster-cidr=10.244.0.0/16 --node-cidr-mask-size=24
--service-cluster-ip-range=10.96.0.0/16
--controllers=*                          # '-name' disables individual
--leader-elect=false                     # single instance: skip lease wait
--secure-port=10257
```

### kube-scheduler

Config file preferred:
```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection: { kubeconfig: scheduler.conf }
leaderElection: { leaderElect: false }
```
Health on :10259 https.

### kubelet (KubeletConfiguration v1beta1)

cgroupDriver: systemd; containerRuntimeEndpoint; clusterDNS/clusterDomain; failSwapOn:false + memorySwap.swapBehavior: NoSwap (NodeSwap GA 1.34); authentication anonymous off + webhook on + x509 clientCAFile; authorization.mode: Webhook; rotateCertificates: true; serverTLSBootstrap: false + tlsCertFile/tlsPrivateKeyFile (pre-generated); staticPodPath: ""; readOnlyPort: 0; healthzBindAddress 127.0.0.1:10248; resolvConf /run/systemd/resolve/resolv.conf on resolved hosts; serializeImagePulls: false.
CLI remainder: --config --kubeconfig --node-ip --hostname-override (must match cert CN system:node:<name>).

## 3. Startup performance

- Why k3s is faster: single process (shared informers, no inter-component TLS), sqlite (no raft/WAL fsync), stripped controllers, in-memory PKI. Tuned stock single-node: apiserver ready 5-15s, full plane ~20-30s — near-parity achievable.
- apiserver: --runtime-config=<group>/<v>=false to disable groups (modest win); keep watch cache (protects etcd); --profiling=false; APF leave on; --leader-elect=false for CM/sched removes multi-second lease wait; --shutdown-delay-duration=0 single-node; --event-ttl 10m dev.
- etcd single node: --snapshot-count=10000 (lower=less RAM), --quota-backend-bytes 2-8GiB, --auto-compaction-mode=periodic --auto-compaction-retention=30m (apiserver also compacts every 5m via --etcd-compaction-interval), heartbeats irrelevant single-node. **--unsafe-no-fsync**: massive latency win, corruption on crash — only for disposable dev clusters. tmpfs data-dir same tradeoff + loss on reboot.
- **kine works with vanilla kube-apiserver** (explicitly supported standalone; k0s uses this with unmodified apiserver). `kine --endpoint 'sqlite:///var/lib/kine/state.db?_journal=WAL&cache=shared' --listen-address unix:///run/kine/kine.sock`; apiserver --etcd-servers=unix:///run/kine/kine.sock. Caveats: not full etcd (txn subset), kine-side compaction, sqlite single-writer, no HA. Removes raft/fsync startup cost entirely — biggest step to k3s-like startup with stock binaries. Still a k3s-io project, not upstream.
- systemd: no socket activation; parallelize etcd/kine + containerd + kubelet; apiserver After=etcd; CM/sched can just crash-loop (Restart=always RestartSec=2) — often faster than gating.

## 4. Node bootstrap

**Pre-generate kubelet certs; skip TLS bootstrapping.** Nix IS the trust channel. No token distribution, no CSR race, kubelet functional immediately, reproducible.

1. Client cert CN=system:node:<name>, O=system:nodes -> kubelet.conf
2. Serving cert SANs=name+IPs -> tlsCertFile; apiserver --kubelet-certificate-authority
3. --authorization-mode=Node,RBAC + NodeRestriction admission; Node authorizer handles per-node perms automatically
4. Optionally rotateCertificates + selfnodeclient auto-approve binding

TLS bootstrapping path documented (bootstrap tokens, system:bootstrappers -> node-bootstrapper + nodeclient auto-approve) — only for dynamic node joining later.

## 5. Health & systemd ordering

| Component | Port | Endpoints |
|---|---|---|
| apiserver | 6443 https | /livez /readyz (/healthz deprecated); ?exclude=etcd; per-check /readyz/<check> |
| kcm | 10257 https | /healthz |
| scheduler | 10259 https | /healthz |
| kubelet | 10248 http | /healthz |
| etcd | 2379 | /health /readyz /livez (3.5.12+) |

- Health endpoints anonymously reachable by default; if anonymous-auth off, probe with client cert or 1.31+ anonymous-endpoints carve-out.
- **No sd_notify in apiserver/kcm/scheduler** (k8s#8311 open since 2015). Use Type=exec.
- **kubelet: systemd watchdog supported since 1.32** (SystemdWatchdog gate, beta on) — set WatchdogSec=30s. Not Type=notify readiness.
- Ordering patterns: (A) ExecStartPre poll of /readyz (blocks in activating; set TimeoutStartSec); (B) Type=notify wrapper polling /readyz then systemd-notify --ready with NotifyAccess=all (rke2-style); (C) no gating, Restart=always crash-loop convergence (kubeadm static-pod equivalent). Recommended combo: hard After= for etcd->apiserver; soft for the rest.

Key sources: kubernetes.io certs best-practices, kubelet-tls-bootstrapping, component references, kubelet-config v1beta1, admission-controllers, aggregation-layer, health-checks, systemd-watchdog; etcd tuning/maintenance docs; k3s-io/kine; kelseyhightower/kubernetes-the-hard-way units; k8s#8311; rke2#989; k8s#138763.

Version-accuracy note: admission default list and /livez per-check endpoints cited from 1.36-era docs — verify against pinned binaries with `kube-apiserver -h`.
