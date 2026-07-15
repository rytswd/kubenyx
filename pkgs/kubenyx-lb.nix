# kubenyx-lb: client-side apiserver load balancer for agents in
# multi-server clusters (air/v0.1/quorum/durable-ha.org §4, Decision 1).
#
# Deliberately NOT part of kubenyx-tools: that package rides every guest's
# boot path, and the single-node/single-server invariant is zero added
# closure weight. Same workspace, same Cargo.lock, separate build target —
# only agents of multi-server clusters ever reference this derivation.
{ rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "kubenyx-lb";
  version = "0.1.0";
  src = ../rust;
  cargoLock.lockFile = ../rust/Cargo.lock;
  cargoBuildFlags = [
    "--package"
    "kubenyx-lb"
  ];
  # Runs the crate's unit tests AND the failover/drain smoke (two dummy TCP
  # backends behind a real LB process — loopback only, sandbox-safe).
  cargoTestFlags = [
    "--package"
    "kubenyx-lb"
  ];
}
