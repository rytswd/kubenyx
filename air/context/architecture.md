# System Architecture — Kubenyx

Authoritative decision record: `air/v0.1/core/architecture.org` (D1–D13).
This file is the quick orientation copy for tooling; when they disagree,
the Air doc wins.

## Core Philosophy

Stock upstream Kubernetes binaries, custom wiring. Performance comes from
*how* components are deployed (Nix store binaries, systemd supervision,
tuned flags, no image pulls, kine/sqlite datastore), never from forking
Kubernetes. Primary use case: a k3s alternative for real-cluster testing;
production readiness is a later milestone that the design must not
preclude.

## Design Principles

- **Declarative everything** — PKI, kubeconfigs, CNI config, addon
  manifests derive from NixOS options; `nixos-rebuild switch` is the whole
  lifecycle. No init/join commands.
- **Zero daemons where a file will do** — CNI is a rendered conflist +
  static routes, not an agent; addons are a server-side-apply oneshot,
  not a manager; PKI is an openssl oneshot, not a CA service.
- **Zero registry dependency for the platform** — control plane runs from
  the Nix store; pause and CoreDNS images are nix-built and preloaded.
- **Profiles move defaults, options move behavior** — `profile = testing`
  (default) vs `balanced`; every default is individually revertible.
- **Anti-patterns we explicitly reject** (from the nixpkgs
  `services.kubernetes` post-mortem): networked CA with shared token,
  single flat CA, role options that force-enable subsystems, imperative
  join scripts, kubectl-loop addon manager, loopback-etcd hardcoding.

## System Architecture

```
kubenyx-cc/
├── flake.nix            # nixpkgs-only input; modules, packages, checks
├── modules/             # NixOS modules (pki, datastore, control-plane,
│                        #   node, network, dns, addons)
├── pkgs/                # readiness wrapper, pause/coredns images, utils
├── lib/                 # CIDR math, assertions
├── tests/               # NixOS VM tests (single-node, etcd, multi-node)
└── air/                 # planning documents (this system)
```

### Service topology (single node)

kine (or etcd) → kube-apiserver (Type=notify readiness wrapper) →
{controller-manager, scheduler, kube-proxy, addons oneshot};
containerd → pause-import → kubelet; CoreDNS on the host (default),
independent of the cluster dataplane. All under `kubenyx.target`.

### Key defaults

- Kubernetes 1.36.x, containerd 2.3 + crun, etcd 3.6 / kine 0.16
- Service CIDR 10.96.0.0/16, cluster CIDR 10.244.0.0/16 (node N owns
  10.244.N.0/24, computed in Nix), cluster domain cluster.local
- kube-proxy nftables mode; bridge+host-local CNI; host CoreDNS at
  169.254.20.10
- PKI: one cluster CA (ECDSA P-256), distinct front-proxy CA slot
  reserved; certs under /var/lib/kubenyx/pki

## Research Base

Five verbatim research reports under `air/context/research/`:
`prior-art.md`, `control-plane-pki.md`, `runtime-node.md`,
`networking-addons.md`, `fast-start.md`. Air docs cite them; supersede
with new dated files rather than editing.
