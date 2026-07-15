# Boot-path tools in Rust (air/v0.1/core/architecture.org D10 + pki.org):
# kubenyx-pki generates the entire cluster PKI in one process (~5ms vs
# ~530ms for the openssl-forking shell version), kubenyx-ready supplies
# sd_notify readiness with 10ms fork-free probing (vs 200ms curl forks).
{ rustPlatform, protobuf }:
let
  # Explicit member list: the workspace also carries kubenyx-lb, which is
  # multi-server-agent-only and packaged separately (pkgs/kubenyx-lb.nix) so
  # single-node guest closures don't grow — an unpinned workspace build
  # would install every member's binary here.
  members = [
    "kubenyx-pki"
    "kubenyx-ready"
    "etcd-mem"
    "kubenyx-snap"
    "kubenyx-clockstep"
  ];
  memberFlags = builtins.concatMap (p: [
    "--package"
    p
  ]) members;
in
rustPlatform.buildRustPackage {
  pname = "kubenyx-tools";
  version = "0.1.0";
  src = ../rust;
  cargoLock.lockFile = ../rust/Cargo.lock;
  cargoBuildFlags = memberFlags;
  cargoTestFlags = memberFlags;
  # etcd-mem uses tonic-build which requires protoc at build time.
  nativeBuildInputs = [ protobuf ];
}
