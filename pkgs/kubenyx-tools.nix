# Boot-path tools in Rust (air/v0.1/core/architecture.org D10 + pki.org):
# kubenyx-pki generates the entire cluster PKI in one process (~5ms vs
# ~530ms for the openssl-forking shell version), kubenyx-ready supplies
# sd_notify readiness with 10ms fork-free probing (vs 200ms curl forks).
#
# Since the multicall refactor every tool is a library crate behind one
# `kubenyx` binary (rust/kubenyx) that dispatches on argv[0] basename or
# the first subcommand. The compat symlinks below keep every historical
# `.../bin/kubenyx-<tool>` ExecStart path resolving unchanged — rendered
# unit text is identical modulo the store hash.
#
# kubenyx-lb is folded in (cargo feature "lb", default on): measured on
# the release profile (lto + strip), the unified binary is 4,059,952 B
# with lb vs 4,007,904 B without — a 52 KiB delta, because lb's weight
# was the rustls/ring stack it already shared with kubenyx-ready and
# kubenyx-snap. The old separate-package rationale (guest closures must
# not grow when lb is off) is moot at 52 KiB against one binary that
# replaced five; pkgs/kubenyx-lb.nix is now a thin symlink to this
# derivation, so lb-enabled guests add ~nothing on top of it either.
{ rustPlatform, protobuf }:
rustPlatform.buildRustPackage {
  pname = "kubenyx-tools";
  version = "0.1.0";
  src = ../rust;
  cargoLock.lockFile = ../rust/Cargo.lock;
  # The multicall bin pulls in every tool crate; no per-member pinning
  # needed for the build. Tests run workspace-wide (default flags): each
  # tool's unit tests now live in its library crate, and the kubenyx
  # crate adds the dispatch tests plus the lb failover/drain smoke (two
  # dummy TCP backends behind a real LB process — loopback only,
  # sandbox-safe).
  cargoBuildFlags = [
    "--package"
    "kubenyx"
  ];
  # etcd-mem uses tonic-build which requires protoc at build time.
  nativeBuildInputs = [ protobuf ];
  postInstall = ''
    # Compat symlinks: argv[0]-basename dispatch keeps the legacy CLIs
    # (and every module/guest ExecStart path) working byte-for-byte.
    for tool in kubenyx-snap kubenyx-pki kubenyx-ready kubenyx-clockstep etcd-mem; do
      ln -s kubenyx "$out/bin/$tool"
    done
  '';
}
