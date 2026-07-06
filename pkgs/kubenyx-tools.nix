# Boot-path tools in Rust (air/v0.1/architecture.org D10 + pki.org):
# kubenyx-pki generates the entire cluster PKI in one process (~5ms vs
# ~530ms for the openssl-forking shell version), kubenyx-ready supplies
# sd_notify readiness with 10ms fork-free probing (vs 200ms curl forks).
{ rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "kubenyx-tools";
  version = "0.1.0";
  src = ../rust;
  cargoLock.lockFile = ../rust/Cargo.lock;
}
