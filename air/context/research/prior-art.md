# Research: Prior Art & nixpkgs Module Failure Analysis (2026-07-05)

Raw research report from the prior-art research pass.

## 1. nixpkgs `services.kubernetes` — what it is and why it's broken

### Mechanics (verified against master)

- Roles abstraction: `roles = ["master" "node"]` force-enables easyCerts + flannel (mkDefault) + addon-manager + etcd-on-loopback.
- easyCerts PKI: **cfssl CA HTTP server on 0.0.0.0:8888** on master + certmgr daemon on every node renewing over the network with a shared 32-hex token; node join = paste token into `nixos-kubernetes-node-join` script; TOFU CA fetch via `curl -k` (pkiTrustOnBootstrap default true); RSA-2048, 30-day certs; single flat CA for everything.
- Single-master only by construction (source comment: "easyCerts doesn't support multimaster clusters anyway atm"; etcd pinned to loopback).
- Runtime: now containerd (docker criticism is historical); coupling problem is flannel + cfssl/certmgr + addon-manager.
- addon-manager: module's own TODO admits "basically just a shell script wrapped around kubectl... assumes clusterAdmin... would be better with a more Nix-oriented way".

### Evidence of brokenness

- Discourse 3922 (2019) "Kubernetes: The NixOS-module of the future" — principal maintainer johanot: bootstrap is "hacked-up together and broken"; ~145 options, ~3 maintainers; proposed out-of-tree flake; outcome inconclusive; only janitorial commits since.
- Open issues: **#196486** aggregation layer impossible with easyCerts (single CA vs required separate front-proxy CA — blocks metrics-server/HPA; open since 2022; PR #531462 still trying in 2026); #59364 etcd cert race on first boot (open since 2019); #124037 etcd start failure; #96083 Go 1.15 SAN enforcement vs cfssl certs; #345400 flannel/kubeconfig coupling; #398895 non-multi-arch addon images.
- **PR #379688 (Feb 2025)**: cfssl `newcert` endpoint was UNAUTHENTICATED by default — "allowing anyone who can access the cfssl http endpoint to create any certificate including kubernetes super admin access". Same PR fixed certmgr restarting k8s components every 30 minutes.
- Wiki hedges: "probably not best-practice", don't use easyCerts in production, recommends k3s.
- Community sentiment (discourse 70899, Oct 2025): nobody defends the module; camps are "use k3s" or "wrap kubeadm" (impure).

### Distilled failings (design anti-patterns to avoid)

1. Networked CA with shared token + TOFU; single flat CA; sidecar renewal daemon restarting components; first-boot state races.
2. Roles force-enabling CNI/PKI/addon-manager; etcd forced to loopback.
3. Single-master by construction.
4. Imperative join flow.
5. kubectl-in-a-loop addon manager requiring cluster-admin.
6. Maintainer vacuum; 145-option surface; non-multi-arch defaults.

## 2. Prior art

### saschagrunert/kubernix (819 stars, v0.3.2 May 2026, active)
Rust supervisor, phased bootstrap: etcd -> apiserver -> (scheduler, kcm, CRI-O, kube-proxy) -> kubelet. K8s 1.36.1, etcd 3.6.11, CRI-O 1.36, cni-plugins 1.9. PKI: cfssl **as CLI at bootstrap**, not a network service. Nix overlays to swap locally-built component binaries (great dev story). Local/test only, not systemd/NixOS.

### justinas/nixos-ha-kubernetes (334 stars)
KTHW-as-NixOS-config, HA: 3x external etcd, 3x control plane, 2x workers, 2x LB (keepalived+haproxy). Drives nixpkgs module low-level options with easyCerts disabled. PKI: out-of-band make-certs, static pre-generated, distributed by deploy tool (Colmena). Best HA-topology reference. Fork: starcraft66/nixos-kubernetes.

### stephank (Nov 2025) — freshest, closest in spirit
stephank.nl 2025-11-17 + codeberg kosinus/nixos-kubernetes-experiment. Own systemd units for everything; CRI-O; kube-proxy **nftables**; **CoreDNS as host systemd service**; deterministic per-node pod subnets (10.88.N.0/24) on a bridge, no flannel; WireGuard between nodes; nftables rules; agenix secrets; working QEMU setup. Quote: NixOS modules "have their own opinions".

### adieu/nixos-k8s-flake
Aborted (1 commit) but README = our thesis: module "mandates Flannel and cfssl"; expose low-level composable options. Validates demand; cautionary re scope.

### Typhoon (poseidon)
Best "distribution of stock upstream k8s" reference. terraform-render-bootstrap renders TLS/static-pods/manifests; **separate tls-k8s.tf / tls-etcd.tf / tls-aggregation.tf CAs** (fixes exactly nixpkgs' #196486 class); one-shot bootstrap.service applies rendered manifests; declarative node provisioning (Ignition ~ NixOS config analog); cilium or flannel first-class.

### kubeadm-on-NixOS
joshrosso: nix packages + hand kubelet unit + imperative kubeadm — "a little impure". Lillecarl: kubeadm+ClusterAPI, unpublished module rendering kubeadm config. Weakness: /etc/kubernetes mutated imperatively, kubeadm owns certs/upgrades — everything NixOS wants to own. Kubenyx differentiation: kubeadm-equivalent results, fully declarative.

### Manifest-side Nix
kubenix (typed manifests), easykubenix (build-time validation against ephemeral etcd+apiserver — steal for `nix flake check`), Tweag kubenix post.

## 3. nixpkgs versions (verified July 2026)

kubernetes 1.36.2 (one derivation, multi-output incl. `pause`; `components` overridable), containerd 2.3.1, etcd 3.6.12 (also 3.4/3.5), cni-plugins 1.9.1, cri-tools 1.36.0, cri-o 1.36.1, coredns 1.14.3, kine 0.16.0. **No custom packaging needed — this is purely a module/PKI/bootstrap problem.**

## 4. Kubernetes the Hard Way (current edition, ~2024 refresh)

Targets k8s 1.32, containerd 2.1, cni-plugins 1.6, etcd 3.6. Modern edition **dropped cfssl for plain openssl with a single declarative ca.conf**. One root CA (RSA-4096, 3653-day leaves). Eight leaf certs: admin, node-0, node-1 (system:node:<n>), kube-proxy, kube-scheduler, kube-controller-manager, kube-api-server, service-accounts. Control plane = 3 plain systemd units; encryption-config.yaml; one RBAC object (system:kube-apiserver-to-kubelet). Workers: runc/containerd/kubelet/kube-proxy/crictl; CNI = 10-bridge.conf + 99-loopback.conf, per-node subnets, **static routes between nodes**; br_netfilter + sysctls; socat conntrack ipset kmod.

Canonical minimal target: ~8 certs, 1 CA, 6 systemd services + etcd + containerd, bridge CNI + static routes, 1 RBAC bootstrap object, 1 encryption config.

## 5. Patterns to steal

1. KTHW openssl-conf-style declarative PKI generation, offline — plus Typhoon's multi-CA separation (cluster/etcd/front-proxy).
2. Typhoon asset-render + idempotent one-shot bootstrap unit (replaces addon-manager).
3. kubernix phased startup + per-component package override for dev.
4. justinas HA topology (external etcd, VIP) — design for N masters from day one.
5. stephank: nftables kube-proxy, deterministic per-node subnets, proper firewall integration, host CoreDNS.
6. adieu: low-level composable options, no mandated CNI/PKI.
7. easykubenix: build-time manifest validation against ephemeral apiserver.
8. Avoid all nixpkgs-module anti-patterns (networked CA, role coupling, imperative join, addon manager, flat CA, boot races, non-multi-arch images).

Competitive framing: community splits into "use k3s" / "wrap kubeadm" / "drive the broken module manually". Nobody ships a maintained, declarative, stock-binary NixOS distribution. The niche is empty and packages are current.

(Full URL list retained in original agent report; key: discourse 3922 / 20403 / 70899, nixpkgs issues 196486/59364/124037/96083/345400/398895, PRs 379688/531462, kubernix, justinas repo, stephank.nl, typhoon + terraform-render-bootstrap, KTHW repo.)
