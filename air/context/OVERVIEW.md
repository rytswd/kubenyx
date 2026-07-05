# Project Overview — Kubenyx

## Description

Kubenyx is a drop-in, Nix-native Kubernetes distribution for NixOS. It runs
**stock upstream Kubernetes binaries** (kube-apiserver, kube-controller-manager,
kube-scheduler, kubelet) as plain systemd services, wired together entirely
through NixOS modules — no kubeadm, no k3s/k0s, no in-cluster control plane,
and explicitly **not** the nixpkgs `services.kubernetes` module.

Initial target: a **k3s alternative for real-cluster testing** — fast to
bring up, disposable, honest stock Kubernetes. Production readiness is a
later milestone the design must not preclude. Two goals dominate every
design decision:

1. **Extreme performance** — fast boot-to-Ready, low idle footprint, fast pod
   start. Kubenyx should be competitive with k3s while remaining 100% stock
   Kubernetes (conformant API surface, standard components).
2. **Ease of use** — a single NixOS module import plus a handful of options
   yields a working cluster. `nixos-rebuild switch` is the only lifecycle
   command; certificates, networking, DNS, and addons are all handled
   declaratively.

## Why not the existing options

- **nixpkgs `services.kubernetes`**: effectively unmaintained, complex
  cert bootstrap (easyCerts/cfssl/certmgr), outdated defaults, poor
  startup behaviour. Replacing it is the founding motivation.
- **k3s / k0s / minikube**: fast and easy, but patched/bundled distributions.
  Kubenyx targets *stock* Kubernetes: every running binary is the upstream
  component as packaged in nixpkgs.

## Core Principles

- **Stock components, custom wiring** — performance comes from how components
  are configured, supervised, and fed (Nix store binaries, no image pulls for
  the control plane), never from forking Kubernetes.
- **Declarative everything** — PKI, kubeconfigs, CNI config, addon manifests
  are derived from NixOS options; no imperative init step.
- **systemd-native** — proper unit dependencies, readiness gating, sandboxing,
  and journal logging; the control plane is just services.
- **Single-node first, multi-node capable** — the drop-in experience is
  optimized for one machine; the same modules scale to small static clusters.

## Technology Stack

- **Language / packaging**: Nix (flake + NixOS modules); nixpkgs for all
  binaries (kubernetes 1.36.x, etcd, containerd, crun, cni-plugins, coredns).
- **Init/supervision**: systemd.
- **Runtime**: containerd + crun, cgroup v2.
- **Testing**: NixOS VM tests (`nixos-lib.runTest`) driving a full cluster.

## Project Structure

- Nix flake: `./flake.nix`
- NixOS modules: `./modules/`
- Packages/helpers: `./pkgs/`
- Rendered addon manifests: `./modules/addons/`
- NixOS VM tests: `./tests/`
- Planning documents: `./air/` (milestones under `air/v0.1/`, …)
- Air context: `./air/context/`

## Current Focus

`v0.1` — a bootable single-node cluster from one module import: PKI,
control plane, node runtime, pod networking, CoreDNS, and a NixOS VM test
proving `kubectl run` + Service + DNS end-to-end. See `air/v0.1/OVERVIEW.org`.
