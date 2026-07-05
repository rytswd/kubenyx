# Implementation Guide — Kubenyx

## Development Environment

- Nix with flakes (repo is a flake; `nixpkgs` is the only input).
- The repo is jj-managed (`.jj/` present) with a git backing store.
- Evaluate fast, build only what changed:
  - `nix flake check --no-build` for eval-level validation
  - `nix build .#checks.x86_64-linux.single-node` for the main VM test
  - `nix eval .#nixosModules.default` smoke for module syntax

## Working Conventions

- Planning-first: find the Air doc (`airctl status --state ready`), set it
  `work-in-progress` before touching code, `complete` only when its
  Acceptance Criteria are covered by a passing VM test.
- Commit trailers: `Air-Doc: v0.1/<doc>.org` on commits that advance a doc.
- Module boundaries: modules communicate only via
  `config.kubenyx.internal.*` read-only options — never reach into another
  module's implementation details.
- Every performance-motivated default must (a) cite the research file that
  justifies it in a comment, (b) remain user-overridable.
- Shell embedded in units: `writeShellApplication` only (shellcheck at
  build time); no raw `script =` strings for anything nontrivial.

## Testing

- NixOS VM tests under `tests/` are the only merge gate; they run without
  network (sandbox), which is also the zero-registry proof.
- Timing metrics printed as `KUBENYX-METRIC key=value` lines; keep them
  greppable, don't gate hard on them in v0.1.
- When a test needs an image, build it with
  `dockerTools.streamLayeredImage` in the flake — never reference a
  registry.

## Gotchas Already Researched (do not rediscover)

- kubelet PATH must include util-linux, iproute2, nftables/iptables,
  socat, conntrack-tools, kmod — missing PATH is the #1 NixOS kubelet
  failure.
- `br_netfilter` + `net.bridge.bridge-nf-call-iptables=1` or same-bridge
  service DNAT silently fails.
- resolv.conf for kubelet must be `/run/systemd/resolve/resolv.conf` when
  systemd-resolved is enabled.
- k8s control-plane binaries have no sd_notify (kubernetes#8311) — use the
  Kubenyx readiness wrapper; kubelet does support the systemd watchdog
  (1.32+).
- Keep the apiserver watch cache ON, especially with kine.
- EventedPLEG stays off (open correctness bugs through 1.34).
- containerd settings are TOML schema v2 in the nixpkgs module; v3 keys
  merge oddly with the module defaults — stay on v2 or mkForce.
- kubelet 1.36 spams "Unable to register mirror pod because node is not
  registered yet" at 10/s until node registration — upstream
  `fastStaticPodsRegistration` polls unconditionally even with zero
  static pods. Harmless noise; do not chase it.
- NixOS test driver assigns VLAN IPs by *alphabetical* node order
  (agent=.1, server=.2 in the multi-node test) — declared kubenyx node
  addresses must match or components dial the wrong machine.
