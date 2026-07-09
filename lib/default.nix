# CIDR math shared by modules and tests. Pure integer arithmetic on IPv4
# and hextet-wise arithmetic on IPv6 (Nix integers are signed 64-bit, so a
# 128-bit v6 address is never materialized as one number); kept
# dependency-free so it can be imported from any context.
{ lib }:
rec {
  # Family detection (ipv6.org §1-2): ":" appears in every IPv6 literal
  # and never in a dotted quad. Works on bare addresses and CIDRs alike.
  isV6 = s: lib.hasInfix ":" s;

  # host:port interpolation for URLs and hostports: v6 needs brackets,
  # v4 (and DNS names) must stay bare. The single helper every
  # address-in-URL site routes through (ipv6.org §4).
  hostPort =
    host: port: if isV6 host then "[${host}]:${toString port}" else "${host}:${toString port}";

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

  # ---- IPv6 hextet arithmetic (ipv6.org §1) -------------------------------

  hexToInt =
    s:
    let
      digits = {
        "0" = 0;
        "1" = 1;
        "2" = 2;
        "3" = 3;
        "4" = 4;
        "5" = 5;
        "6" = 6;
        "7" = 7;
        "8" = 8;
        "9" = 9;
        "a" = 10;
        "b" = 11;
        "c" = 12;
        "d" = 13;
        "e" = 14;
        "f" = 15;
        "A" = 10;
        "B" = 11;
        "C" = 12;
        "D" = 13;
        "E" = 14;
        "F" = 15;
      };
    in
    lib.foldl' (acc: c: acc * 16 + digits.${c}) 0 (lib.stringToCharacters s);

  # Expand an IPv6 literal into its 8 hextet values ("::" fills zeros).
  v6ToHextets =
    addr:
    let
      halves = lib.splitString "::" addr;
      compressed = lib.length halves == 2;
      groups = half: lib.filter (g: g != "") (lib.splitString ":" half);
      left = groups (builtins.elemAt halves 0);
      right = if compressed then groups (builtins.elemAt halves 1) else [ ];
      fill = 8 - lib.length left - lib.length right;
    in
    assert lib.assertMsg (
      lib.length halves <= 2 && (if compressed then fill >= 1 else lib.length left == 8)
    ) "kubenyx: invalid IPv6 address literal '${addr}'";
    map hexToInt left ++ lib.optionals compressed (lib.genList (_: 0) fill) ++ map hexToInt right;

  # Render 8 hextets per RFC 5952: lowercase, no leading zeros, longest
  # zero run of two-or-more compressed to "::" (leftmost wins ties).
  hextetsToV6 =
    hextets:
    let
      hex = h: lib.toLower (lib.toHexString h);
      zeroRunAt = i: if i >= 8 || builtins.elemAt hextets i != 0 then 0 else 1 + zeroRunAt (i + 1);
      best =
        lib.foldl'
          (
            acc: i:
            let
              len = zeroRunAt i;
            in
            if len > acc.len then
              {
                start = i;
                inherit len;
              }
            else
              acc
          )
          {
            start = -1;
            len = 1;
          }
          (lib.range 0 7);
      before = lib.sublist 0 best.start hextets;
      after = lib.sublist (best.start + best.len) (8 - best.start - best.len) hextets;
    in
    if best.len < 2 then
      lib.concatMapStringsSep ":" hex hextets
    else
      "${lib.concatMapStringsSep ":" hex before}::${lib.concatMapStringsSep ":" hex after}";

  # Add n at hextet position pos (0 = most significant), carrying leftward.
  # Hextet-wise on purpose: each intermediate stays far below 2^63.
  v6Add =
    hextets: pos: n:
    (lib.foldr
      (
        h: acc:
        let
          v = h + acc.carry;
        in
        {
          carry = v / 65536;
          out = [ (lib.mod v 65536) ] ++ acc.out;
        }
      )
      {
        carry = 0;
        out = [ ];
      }
      (lib.imap0 (i: h: if i == pos then h + n else h) hextets)
    ).out;

  # Nth host address inside a CIDR, e.g. cidrHost "10.96.0.0/16" 1 ->
  # "10.96.0.1", cidrHost "fd00::/112" 10 -> "fd00::a".
  cidrHost =
    cidr: n:
    if isV6 cidr then
      hextetsToV6 (v6Add (v6ToHextets (cidrBase cidr)) 7 n)
    else
      intToIp (ipToInt (cidrBase cidr) + n);

  # Pod CIDR owned by the node with the given index (architecture.org D6):
  # deterministic, derived from declared membership, never allocated at
  # runtime. v4: node N owns the Nth /nodeMask of the cluster CIDR (the
  # Nth /24 of a /16 by default). v6: the same carve on hextets — node N
  # owns the Nth /64 of the cluster prefix (ipv6.org §1).
  nodePodCidr =
    clusterCidr: nodeMask: index:
    if isV6 clusterCidr then
      let
        shift = 128 - nodeMask;
        pos = 7 - shift / 16;
        scale = pow2 (lib.mod shift 16);
      in
      "${
        hextetsToV6 (v6Add (v6ToHextets (cidrBase clusterCidr)) pos (index * scale))
      }/${toString nodeMask}"
    else
      "${intToIp (ipToInt (cidrBase clusterCidr) + index * pow2 (32 - nodeMask))}/${toString nodeMask}";
}
