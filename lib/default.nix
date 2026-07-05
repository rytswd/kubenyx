# CIDR math shared by modules and tests. Pure integer arithmetic on IPv4;
# kept dependency-free so it can be imported from any context.
{ lib }:
rec {
  ipToInt =
    ip:
    let
      p = map lib.toInt (lib.splitString "." ip);
    in
    (builtins.elemAt p 0) * 16777216
    + (builtins.elemAt p 1) * 65536
    + (builtins.elemAt p 2) * 256
    + (builtins.elemAt p 3);

  intToIp =
    n:
    lib.concatMapStringsSep "." toString [
      (n / 16777216)
      (lib.mod (n / 65536) 256)
      (lib.mod (n / 256) 256)
      (lib.mod n 256)
    ];

  cidrBase = cidr: builtins.elemAt (lib.splitString "/" cidr) 0;
  cidrPrefix = cidr: lib.toInt (builtins.elemAt (lib.splitString "/" cidr) 1);

  pow2 = n: if n == 0 then 1 else 2 * pow2 (n - 1);

  # Nth host address inside a CIDR, e.g. cidrHost "10.96.0.0/16" 1 -> "10.96.0.1"
  cidrHost = cidr: n: intToIp (ipToInt (cidrBase cidr) + n);

  # Pod CIDR owned by the node with the given index (architecture.org D6):
  # deterministic, derived from declared membership, never allocated at runtime.
  nodePodCidr =
    clusterCidr: nodeMask: index:
    "${intToIp (ipToInt (cidrBase clusterCidr) + index * pow2 (32 - nodeMask))}/${toString nodeMask}";
}
