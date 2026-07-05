# Research: Networking & Addons (2026-07-05)

Raw research report from the networking/addons research pass.

## 1. CNI Choice

### Plain CNI plugins (zero-daemon)

`bridge` + `host-local` + `portmap` + `loopback` from containernetworking/plugins: pure one-shot executables invoked by containerd. No agent, no DaemonSet.

Since k8s 1.24 kubelet has NO CNI flags — the runtime owns CNI. containerd reads `/etc/cni/net.d` (first `.conflist`, `max_conf_num=1`) and executes from configured bin dir:

```toml
version = 3
[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dirs = ['/opt/cni/bin']   # bin_dir deprecated since 2.1
  conf_dir = '/etc/cni/net.d'
```

Conflist per node (subnet = node's pod CIDR):

```json
{
  "cniVersion": "1.0.0",
  "name": "k8s-pod-network",
  "plugins": [
    { "type": "bridge", "bridge": "cni0", "isGateway": true,
      "isDefaultGateway": true, "hairpinMode": true, "ipMasq": true,
      "ipam": { "type": "host-local",
                "ranges": [[ { "subnet": "10.244.0.0/24" } ]],
                "routes": [ { "dst": "0.0.0.0/0" } ] } },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
```

- `loopback` invoked implicitly; keep binary present. `portmap` only for hostPort.
- `host-local` stores allocations as flat files under /var/lib/cni/networks/ — no DB.
- `hairpinMode: true` so a pod can reach itself via Service VIP.
- host-local CANNOT read node.spec.podCIDR from the API (kubenet is gone). For Nix: statically assign per-node subnets (node N -> 10.244.N.0/24) — deterministic, no allocation races. Optionally still run --allocate-node-cidrs so spec.podCIDR matches for observability.
- ptp vs bridge: negligible perf difference. bridge simpler/most-tested; REQUIRES br_netfilter + net.bridge.bridge-nf-call-iptables=1 or same-bridge service DNAT silently fails (classic gotcha). ptp routes everything via host L3 (no br_netfilter need).
- Same-node bridge is the theoretical max — no CNI daemon beats it; cross-node with static routes = flannel host-gw datapath exactly.

### Flannel

flanneld per node writes a bridge conflist + handles cross-node. Backends: vxlan (~8Gbit/s, 40-50% CPU, 0.5ms), host-gw (~9.5Gbit/s, 25-30% CPU, 0.3ms — near-native, needs L2 adjacency), wireguard. vxlan DirectRouting=true = hybrid. On a LAN, flannel host-gw's entire job is N-1 static routes — NixOS can do that with zero daemons, making flanneld redundant.

### Cilium

Best service datapath in existence (socket-LB: DNAT at connect() time, no per-packet NAT/conntrack), but: agent ~180MB->450MB RAM, operator, BPF compile at startup (15-60s normal), most complex operationally. Advantages unmeasurable at <1000 services. Not for a 1-5 node drop-in.

### kube-router

One daemon: BGP pod routing + IPVS service proxy + policy. Uses stock bridge plugin locally. BGP overkill for 3-node LAN; smaller community.

### Verdict

**bridge+host-local rendered by Nix, zero daemons; NixOS static routes for multi-node.** Fastest single-node, equal-fastest multi-node-on-LAN. Validated end-to-end by Stéphan's Nov 2025 vanilla-k8s-on-NixOS writeup (stephank.nl).

## 2. kube-proxy

- **nftables mode GA in 1.33** (KEP-3866), kernel >=5.13. O(1) via verdict maps: p50 ~5µs regardless of service count (iptables: O(n), ~100µs @5k, ~600µs @30k; at 30k services nftables p99 < iptables p01). SIG-Network: "matches or exceeds IPVS without its drawbacks; recommended replacement". iptables remains default purely for compatibility. IPVS effectively legacy.
- At dozens of services all modes indistinguishable — choose nftables anyway (future, no iptables-restore stalls). Caveats: no NodePort on 127.0.0.1, stricter martian handling.
- Skipping kube-proxy entirely: only possible when CNI provides the service path (cilium/kube-router). ClusterIPs are virtual; something must DNAT. apiserver's endpoint reconciler maintains the `kubernetes` Service EndpointSlice but pods reach its ClusterIP via normal DNAT. `kubectl expose` requires a service dataplane => **kube-proxy nftables required** in our design (~20-40MB, near-zero CPU).
- Run as systemd service with KubeProxyConfiguration file: `mode: nftables`, `clusterCIDR`.

## 3. CoreDNS

- coredns/deployment repo deprecated; best templates to vendor: kubeadm's embedded manifest or k3s's coredns.yaml. 5 objects: ServiceAccount, ClusterRole (endpoints/services/pods/namespaces + endpointslices list/watch), Binding, ConfigMap (Corefile), Deployment + Service kube-dns.

Corefile:
```
.:53 {
    errors
    health { lameduck 5s }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
    prometheus :9153
    forward . /etc/resolv.conf { max_concurrent 1000 }
    cache 30
    loop
    reload
    loadbalance
}
```

- ClusterDNS IP convention: 10th address of service CIDR (10.96.0.10 for 10.96.0.0/12; .1 is apiserver). Pure convention — clusterIP in Service must match kubelet clusterDNS.
- Defaults: requests 100m/70Mi, limit 170Mi, liveness :8080/health, readiness :8181/ready; 1 replica for single node. CoreDNS delays serving up to 5s at startup while syncing watches.
- **Host-systemd CoreDNS (Nix-native option)**: kubernetes plugin with `kubeconfig` instead of in-cluster config; bind to node IP or dummy 169.254.20.10; kubelet clusterDNS points there; no kube-dns Service needed; removes DNS dependency on service dataplane (no bootstrap loop), no conntrack for DNS (avoids UDP conntrack race/5s timeouts). Same pattern as NodeLocal DNSCache / AKS LocalDNS (ships as host systemd service). Cons: version tied to NixOS, per-node API watch (trivial), nonstandard resolv.conf target (same as node-local-dns).
- Recommendation: in-cluster Deployment = boring default; host-systemd = Nix-native perf option. Both declarative.

## 4. Addon management without helm

- k3s model: manifests dir, applied on start + fsnotify change; tracked as AddOn CR; deletion does not prune.
- kube-addon-manager: retired bash loop; one good idea: Reconcile vs EnsureExists.
- **Best pattern**: systemd oneshot `kubectl apply --server-side --force-conflicts -f <nix-store-dir>` after /readyz; ExecStart path changes on manifest change -> unit restarts on nixos-rebuild switch -> convergence per deploy. Optional pruning: `--prune --applyset=<set>` (beta).
- Nix manifest rendering: kubenix (hall/kubenix, typed from swagger, slow-moving), nixidy (ArgoCD-oriented), easykubenix (Lillecarl 2025: pkgs.formats.json + build-time validation against ephemeral etcd+apiserver — standout idea; bundles kluctl). Minimal: plain attrsets + builtins.toJSON, server validates via SSA.

## 5. Multi-node

- KCM --allocate-node-cidrs assigns spec.podCIDR but nothing installs routes on bare metal, and host-local won't read it. Invert: **Nix is source of truth for per-node subnets**, rendered into conflist + every node's static routes.
- host-gw pattern: `ip route add 10.244.M.0/24 via <nodeM-IP>` — networking.interfaces.<if>.ipv4.routes / systemd-networkd. Needs L2 adjacency + ip_forward. Careful with ipMasq: NAT only internet-bound traffic, exclude cluster CIDR.
- WireGuard mesh for untrusted links: peers' podCIDRs in AllowedIPs (cryptokey routing = routing table). In-kernel WG fast; on trusted LAN skip encryption.

## 6. Minimal set for kubectl run + expose + DNS

Host prereqs: br_netfilter, ip_forward=1, bridge-nf-call-iptables=1, swap off or failSwapOn=false, cgroup v2.

1. etcd (single member)
2. kube-apiserver (--service-cluster-ip-range)
3. kube-controller-manager — mandatory even single-node (ServiceAccount token controller; deployments; node lifecycle)
4. kube-scheduler — mandatory
5. kubelet + containerd + 4 CNI binaries + 1 conflist
6. kube-proxy (nftables)
7. CoreDNS (in-cluster deployment or host systemd) + kubelet clusterDNS/clusterDomain match

= 6 host services + 4 CNI binaries + 1 manifest bundle. NOT needed: cloud-controller-manager, CNI daemon, addon-manager, helm, metrics-server, ingress. k3s ships exactly this set.

## Recommended architecture

- CNI: Nix-rendered bridge+host-local+portmap; per-node podCIDRs from node index; zero network daemons.
- Multi-node: NixOS static routes on trusted LAN; WG mesh option for untrusted.
- Services: kube-proxy systemd service, nftables mode.
- DNS: CoreDNS in-cluster (orthodox) or host-systemd (Nix-native, no bootstrap loop).
- Addons: systemd oneshot kubectl apply --server-side over nix-store dir; manifests as Nix attrsets (toJSON).

Key sources: kubernetes.io network-plugins & virtual-ips & nftables blog (2025-02-28); KEP-3866; containerd CRI config docs; cni.dev bridge/ptp; flannel backends; MachineZone CNI study; Cilium benchmark & kube-proxy-free docs; kube-router docs; coredns.yaml.sed; k3s coredns.yaml & packaged-components; NodeLocal DNSCache; AKS LocalDNS; kubenix; nixidy; easykubenix discourse; stephank.nl 2025-11-17 vanilla k8s on NixOS.
