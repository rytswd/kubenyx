# kubenyx-lb: client-side apiserver load balancer for agents in
# multi-server clusters (air/v0.1/quorum/durable-ha.org §4, Decision 1).
#
# Historically a separate cargo build so single-server guest closures
# carried zero LB weight. The multicall refactor measured that argument
# away: with the tools deduped into one `kubenyx` binary, lb is a 52 KiB
# delta (4,059,952 B with vs 4,007,904 B without, release profile) —
# its real weight was the rustls/ring stack the other tools already
# carry. So this is now a thin view over kubenyx-tools: bin/kubenyx-lb
# is an argv[0]-dispatch symlink to the same multicall binary, and a
# guest that enables lb references the kubenyx-tools derivation it
# already had — the added closure is this symlink. Modules still
# reference this package only when lb.enable gates it on, so the unit
# and option shape is unchanged. (If a future guest build must exclude
# lb bytes entirely, the cargo feature "lb" — default on — still
# exists; build kubenyx-tools with --no-default-features.)
{ callPackage, runCommand }:
let
  tools = callPackage ./kubenyx-tools.nix { };
in
runCommand "kubenyx-lb-0.1.0" { } ''
  mkdir -p $out/bin
  ln -s ${tools}/bin/kubenyx $out/bin/kubenyx-lb
''
