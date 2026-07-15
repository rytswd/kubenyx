# Research: Runtime & Node Layer (2026-07-05)

Raw research report from the runtime/node research pass. Source of truth for
decisions recorded in `air/v0.1/core/*`; keep verbatim, do not edit conclusions in
place — supersede via new dated files.

## 1. Container Runtime Choice

### 1.1 containerd vs CRI-O

Both CNCF-graduated and roughly equivalent on the hot path. Differences:

- **Memory footprint**: CRI-O lighter (conmon ~8MB/container, crio daemon ~50MB idle); divergence meaningful only above ~150 pods/node.
- **Churn robustness**: containerd better hardened at hyperscale.
- **Image pulls**: containerd slightly ahead (snapshotter ecosystem + transfer service).
- **CRI-O 1.31+ defaults to crun**; also drops the pause container entirely when no shared PID ns (`drop_infra_ctr`, default since ~1.22) — containerd has no shipped pauseless mode (Sandbox API exists but default podsandbox sandboxer still uses pause).

**Verdict for NixOS**: containerd — first-class `virtualisation.containerd` module in nixpkgs, containerd 2.3.1 available. CRI-O worth a benchmark only at very high density.

### 1.2 crun vs runc vs youki

| Source | Result |
|---|---|
| crun README | 100x /bin/true: crun 1.69s vs runc 3.34s (~49% faster); crun runs in 512KB cgroup limit where runc fails at 4MB |
| youki README (v0.3.3 bench, create+start+delete) | crun 47.3ms, youki 111.5ms, runc 224.6ms |
| Henrik Gerdes CRI bench 2024 | ~21% end-to-end pod-level advantage crun vs runc; youki had 3.6% error rate |
| Podman 5.0 + crun study | 37% startup latency reduction across 10k containers |

**Choose crun** (C, no Go runtime init; default in CRI-O >=1.31, OpenShift 4.18+, Podman). Pod-level end-to-end gain realistic ~20%.

### 1.3 containerd + crun config

crun has no shim of its own; use runc shim `io.containerd.runc.v2` with `BinaryName` (containerd discussion #6162; containerd 2.1 CRI config docs).

Config version 3 (containerd 2.x renames: CRI runtime config -> `io.containerd.cri.v1.runtime`, image config -> `io.containerd.cri.v1.images`):

```toml
version = 3

[plugins.'io.containerd.cri.v1.runtime'.containerd]
  default_runtime_name = 'crun'

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.crun]
  runtime_type = 'io.containerd.runc.v2'
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.crun.options]
    BinaryName = '/path/to/crun'      # NixOS: ${pkgs.crun}/bin/crun
    SystemdCgroup = true

[plugins.'io.containerd.cri.v1.images']
  snapshotter = 'overlayfs'
  [plugins.'io.containerd.cri.v1.images'.pinned_images]
    sandbox = 'registry.k8s.io/pause:3.10.1'
```

Version 2 equivalent still accepted by containerd 2.x (auto-migrated); nixpkgs module emits v2 today.

## 2. containerd Configuration Specifics (NixOS)

### 2.1 nixpkgs `virtualisation.containerd`

- `settings` attrset -> TOML; default emits `version = 2`, `cni.bin_dir = ${pkgs.cni-plugins}/bin`, zfs snapshotter if zfs enabled.
- Unit: Delegate=yes, LimitNPROC/CORE/TasksMax=infinity, OOMScoreAdjust=-999, Type=notify, Restart=always. **LimitNOFILE not set** — set explicitly.
- v3 settings possible but module's v2-keyed defaults merge oddly — use lib.mkForce or full configFile (nixpkgs issue #293708).

### 2.2 Snapshotter

- **overlayfs**: default, fastest mature choice — baseline.
- **erofs** (containerd 2.1+, experimental): ~14% faster unpack, fsverity; NixOS kernels have EROFS. Watch, not adopt yet.
- **stargz/nydus lazy pull**: solves cold-pull latency (~76% of startup), but needs image conversion + FUSE daemon. Redundant with nix-preloaded images — skip.
- **nix-snapshotter** (pdtpartners): resolves layers directly to nix store paths — zero pull, zero unpack, host dedup. v0.4.0, nascent. Experimental endgame option.

### 2.3 Pause/sandbox image

- Current: `registry.k8s.io/pause:3.10.1` (kubeadm warns older for 1.34).
- containerd 2.x: `pinned_images.sandbox` (v3) / `sandbox_image` (v2); pinned images exempt from GC.
- Avoid network pull: build pause with dockerTools (nixpkgs kubernetes has `pause` output with the binary), seed via `ctr -n k8s.io image import` in ExecStartPre — same pattern as nixpkgs kubelet module `seedDockerImages`.
- No pauseless mode in containerd CRI as of 2.3.

### 2.4 containerd 2.x perf features

- Transfer service default pull path in 2.1+; 2.1 parallel range-request downloads per layer; **2.2 parallel layer unpacking** (overlayfs, erofs). Tune `max_concurrent_downloads`.
- **NRI enabled by default in 2.0+** — disable for minimal surface:
  `[plugins.'io.containerd.nri.v1.nri'] disable = true`
- `SystemdCgroup = true` + kubelet `cgroupDriver: systemd` mandatory pairing (cgroup v2 single-writer). K8s 1.28+ can auto-detect from CRI (KubeletCgroupDriverFromCRI) but set both.

## 3. Kubelet Performance Tuning

KubeletConfiguration highlights (kubelet.config.k8s.io/v1beta1):

```yaml
serializeImagePulls: false        # parallel pulls (KEP-3673, v1.27+)
maxParallelImagePulls: 10
imageGCHighThresholdPercent: 85
maxPods: 110                      # node pod CIDR must be 2x maxPods
staticPodPath: ""                 # disables static pod file watcher entirely
nodeStatusUpdateFrequency: 10s
nodeStatusReportFrequency: 5m
housekeepingInterval: 10s
protectKernelDefaults: true       # requires sysctls pre-set by NixOS
failSwapOn: false                 # NodeSwap GA in 1.34; LimitedSwap or NoSwap
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
resolvConf: /run/systemd/resolve/resolv.conf   # with systemd-resolved
```

- **EventedPLEG: do NOT enable** — beta but default-off through 1.34, open correctness bugs (k8s #121349, #124704, containerd #9070). Generic 1s relist is fine.
- cpuManagerPolicy static / memoryManager / topologyManager only for pinned latency-critical workloads.
- Swap: extreme-perf default is none; if added use LimitedSwap.

### Kernel sysctls (required by protectKernelDefaults + practice)

```nix
boot.kernel.sysctl = {
  "vm.overcommit_memory" = 1;
  "vm.panic_on_oom" = 0;
  "kernel.panic" = 10;
  "kernel.panic_on_oops" = 1;
  "kernel.keys.root_maxkeys" = 1000000;
  "kernel.keys.root_maxbytes" = 25000000;
  "net.ipv4.ip_forward" = 1;
  "net.bridge.bridge-nf-call-iptables" = 1;
  "net.bridge.bridge-nf-call-ip6tables" = 1;
  "fs.inotify.max_user_watches" = 1048576;
  "fs.inotify.max_user_instances" = 8192;
  "fs.file-max" = 2097152;
  "net.netfilter.nf_conntrack_max" = 1048576;
};
```

## 4. NixOS-Specific Node Concerns

- **Kernel modules**: `br_netfilter`, `overlay` (nixpkgs module loads exactly these); plus CNI-specific (vxlan, wireguard) as needed.
- **cgroup v2**: unconditional on modern NixOS; systemd accounting default-on.
- **CNI bin dir**: classic pain point. Convention `/opt/cni/bin`; DaemonSet CNI installers write there. Pattern: real mutable `/opt/cni/bin` (tmpfiles), symlink nix plugins in, containerd `bin_dir`/`bin_dirs` points there. kubelet `--cni-bin-dir` is long gone (CNI owned by runtime).
- **resolv.conf**: with systemd-resolved use `/run/systemd/resolve/resolv.conf` (not the 127.0.0.53 stub).
- **hostname/machine-id**: node name from hostname (unique, lowercase RFC-1123); unique /etc/machine-id per node (cloned VMs must regenerate).
- **PATH in kubelet unit**: kubelet shells out to mount, nsenter, iptables, socat, ip, util-linux — must inject full PATH; #1 NixOS-kubelet gotcha.

## 5. Offline/Airgapped Images via Nix

1. `ctr -n k8s.io image import` pre-seeding (simplest; streamLayeredImage pipe).
2. nix2container — archive-less builds, skopeo push; best for CI/registry flows.
3. nix-snapshotter — zero-pull/zero-unpack nix-store-backed images; experimental.
4. Spegel — P2P registry mirror DaemonSet (embedded in k3s/rke2); worth it for multi-node with upstream pulls; redundant if everything nix-preloaded.

## Recommended Stack Summary

containerd 2.3.x + crun via runc.v2 BinaryName; overlayfs; pause built by dockerTools + ctr-imported + pinned; NRI disabled; SystemdCgroup; kubelet with parallel pulls, staticPodPath="", protectKernelDefaults, EventedPLEG off, swap off; NixOS modules br_netfilter+overlay, sysctl block, /opt/cni/bin symlink convention, full PATH in kubelet unit; streamLayeredImage + ctr import for airgapped core.

Key sources: containerd 2.1 CRI config docs; containerd #6162; Samuel Karp containerd 2.1; containerd 2.2.0 release; crun/youki READMEs; Gerdes CRI bench 2024; KEP-3673; KEP-3386/EventedPLEG issues; KEP-2400 NodeSwap; nixpkgs kubelet.nix; NixOS wiki Kubernetes; nix2container; nix-snapshotter; spegel.dev.
