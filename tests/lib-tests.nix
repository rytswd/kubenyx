# Eval-level unit tests for lib/ CIDR math (ipv6.org §1): lib.runTests,
# no VM — surfaced as checks.<system>.lib-tests, which fails the build on
# any non-empty failure list. Covers the v4 behavior contract (existing
# example values, must never move) and the v6 branches.
{ lib }:
let
  klib = import ../lib { inherit lib; };
in
lib.runTests {
  # ---- v4 behavior unchanged (the byte-identity contract's eval side) ----
  testV4CidrHostApiserver = {
    expr = klib.cidrHost "10.96.0.0/16" 1;
    expected = "10.96.0.1";
  };
  testV4CidrHostDns = {
    expr = klib.cidrHost "10.96.0.0/16" 10;
    expected = "10.96.0.10";
  };
  testV4CidrHostOctetCarry = {
    expr = klib.cidrHost "10.96.0.0/16" 256;
    expected = "10.96.1.0";
  };
  testV4NodePodCidrIndex0 = {
    expr = klib.nodePodCidr "10.244.0.0/16" 24 0;
    expected = "10.244.0.0/24";
  };
  testV4NodePodCidrIndex1 = {
    expr = klib.nodePodCidr "10.244.0.0/16" 24 1;
    expected = "10.244.1.0/24";
  };
  testV4NodePodCidrIndex255 = {
    expr = klib.nodePodCidr "10.244.0.0/16" 24 255;
    expected = "10.244.255.0/24";
  };

  # ---- family detection ---------------------------------------------------
  testIsV6OnV4 = {
    expr = klib.isV6 "10.244.0.0/16";
    expected = false;
  };
  testIsV6OnV6 = {
    expr = klib.isV6 "fd42:dead:beef::/56";
    expected = true;
  };
  testIsV6OnBareV6 = {
    expr = klib.isV6 "fd00::1";
    expected = true;
  };

  # ---- v6 cidrHost ----------------------------------------------------------
  testV6CidrHostOne = {
    expr = klib.cidrHost "fd00::/112" 1;
    expected = "fd00::1";
  };
  testV6CidrHostTen = {
    expr = klib.cidrHost "fd00::/112" 10;
    expected = "fd00::a";
  };
  testV6CidrHostTopOfSlice = {
    expr = klib.cidrHost "fd00::/112" 65535;
    expected = "fd00::ffff";
  };
  testV6CidrHostHextetCarry = {
    expr = klib.cidrHost "fd00::ffff/112" 1;
    expected = "fd00::1:0";
  };
  testV6CidrHostUncompressedInput = {
    expr = klib.cidrHost "fd00:0:0:0:0:0:0:0/112" 1;
    expected = "fd00::1";
  };
  testV6CidrHostLoopbackStyle = {
    expr = klib.cidrHost "::/112" 1;
    expected = "::1";
  };

  # ---- v6 nodePodCidr (Nth /64 of the cluster prefix) ----------------------
  testV6NodePodCidrIndex0 = {
    expr = klib.nodePodCidr "fd42:dead:beef::/56" 64 0;
    expected = "fd42:dead:beef::/64";
  };
  testV6NodePodCidrIndex1 = {
    expr = klib.nodePodCidr "fd42:dead:beef::/56" 64 1;
    expected = "fd42:dead:beef:1::/64";
  };
  testV6NodePodCidrIndex255 = {
    expr = klib.nodePodCidr "fd42:dead:beef::/56" 64 255;
    expected = "fd42:dead:beef:ff::/64";
  };
  testV6NodePodCidrWideCluster = {
    # /48 cluster prefix: index lands in the whole low half of hextet 3.
    expr = klib.nodePodCidr "fd42:dead:beef::/48" 64 255;
    expected = "fd42:dead:beef:ff::/64";
  };
  testV6NodePodCidrCarryAcrossHextet = {
    # Base hextet 3 already near the top: the carve must carry leftward.
    expr = klib.nodePodCidr "fd42:0:0:ffff::/64" 64 1;
    expected = "fd42:0:1::/64";
  };

  # ---- hostPort -------------------------------------------------------------
  testHostPortV4 = {
    expr = klib.hostPort "10.100.0.2" 6443;
    expected = "10.100.0.2:6443";
  };
  testHostPortV6 = {
    expr = klib.hostPort "fd00::2" 6443;
    expected = "[fd00::2]:6443";
  };
  testHostPortV6Etcd = {
    expr = klib.hostPort "fd42:dead:beef::2" 2380;
    expected = "[fd42:dead:beef::2]:2380";
  };
  testHostPortName = {
    # DNS names must stay bare too (controlPlaneEndpoint accepts names).
    expr = klib.hostPort "cp.example.org" 6443;
    expected = "cp.example.org:6443";
  };

  # ---- v6 parsing/rendering internals --------------------------------------
  testV6ToHextets = {
    expr = klib.v6ToHextets "fd42:dead:beef::a";
    expected = [
      64834
      57005
      48879
      0
      0
      0
      0
      10
    ];
  };
  testHextetsToV6AllZero = {
    expr = klib.hextetsToV6 [
      0
      0
      0
      0
      0
      0
      0
      0
    ];
    expected = "::";
  };
  testHextetsToV6NoCompressibleRun = {
    # Single zeros never compress (RFC 5952: "::" is for runs of 2+).
    expr = klib.hextetsToV6 [
      1
      0
      1
      0
      1
      0
      1
      0
    ];
    expected = "1:0:1:0:1:0:1:0";
  };
  testHextetsToV6LongestRunWins = {
    expr = klib.hextetsToV6 [
      1
      0
      0
      1
      0
      0
      0
      1
    ];
    expected = "1:0:0:1::1";
  };
  testHextetsToV6LeftmostRunOnTie = {
    expr = klib.hextetsToV6 [
      0
      0
      1
      1
      0
      0
      1
      1
    ];
    expected = "::1:1:0:0:1:1";
  };
}
