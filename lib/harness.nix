# Test-harness embedding (air/v0.6/harness.org): one members attrset in,
# everything a NixOS VM test needs to host a kubenyx cluster out — the
# per-node modules (roles, addresses incl. v6, external-CNI toggle) and
# the driver-side Python (credential ship, readiness gates, kubectl
# wrapper). Reachable as flake `lib.harness` AND as a plain
#   import <kubenyx>/lib/harness.nix { inherit lib; }
# — no flakes required; the module tree is referenced by relative path.
{ lib }:
let
  klib = import ./. { inherit lib; };

  # The test driver derives Python variables from node names by mapping
  # `-` to `_`; generating both from one members set keeps them in sync.
  pyVar = name: lib.replaceStrings [ "-" ] [ "_" ] name;
in
rec {
  inherit pyVar;

  mkCluster =
    {
      # { <name> = { index, role ? "agent", address ? null, module ? { } }; }
      # `address = null` resolves from the driver's assigned primary
      # address (family keyed off clusterCidr); explicit always wins.
      # `module` is a per-member NixOS module for anything else.
      members,
      # Family selectors and structural toggles are ARGUMENTS, not
      # `defaults` keys — the helper owns them so it can key address
      # resolution, waitReady shape, and friendly assertions off them.
      clusterCidr ? null,
      serviceCidr ? null,
      externalCni ? false,
      # Only meaningful with externalCni: the external CNI also replaces
      # the service plane, so kubenyx's kube-proxy must not run.
      cniReplacesServicePlane ? false,
      # kubenyx.* option overlay applied to every member (plain values;
      # structural keys above are rejected — pass them as arguments).
      defaults ? { },
      # Extra NixOS modules applied to every member.
      extraModules ? [ ],
    }:
    let
      v6 = clusterCidr != null && klib.isV6 clusterCidr;

      roleOf = m: m.role or "agent";
      serverNames = lib.attrNames (lib.filterAttrs (_: m: roleOf m == "server") members);
      agentNames = lib.attrNames (lib.filterAttrs (_: m: roleOf m != "server") members);
      memberNames = lib.attrNames members;
      primaryServer = lib.head serverNames;

      # Structural keys the helper owns; catching them here turns
      # module-system conflict spew into a pointed eval error.
      ownedPaths = [
        [ "enable" ]
        [ "role" ]
        [ "nodeName" ]
        [ "nodes" ]
        [ "controlPlaneEndpoint" ]
        [
          "network"
          "cni"
        ]
        [
          "network"
          "clusterCidr"
        ]
        [
          "network"
          "serviceCidr"
        ]
        [
          "network"
          "kubeProxy"
          "enable"
        ]
      ];
      offendingPaths = lib.filter (p: lib.hasAttrByPath p defaults) ownedPaths;

      checkedMembers =
        assert lib.assertMsg (members != { }) "kubenyx.harness: members must not be empty";
        assert lib.assertMsg (
          serverNames != [ ]
        ) "kubenyx.harness: at least one member must declare role = \"server\"";
        assert lib.assertMsg (offendingPaths == [ ]) ''
          kubenyx.harness: defaults sets kubenyx.${lib.concatStringsSep "." (lib.head offendingPaths)}, which mkCluster owns — pass it as an mkCluster argument
          (members / clusterCidr / serviceCidr / externalCni /
          cniReplacesServicePlane) instead.'';
        assert lib.assertMsg (
          externalCni || !cniReplacesServicePlane
        ) "kubenyx.harness: cniReplacesServicePlane only makes sense with externalCni = true";
        assert lib.assertMsg
          (serviceCidr == null || clusterCidr != null && klib.isV6 serviceCidr == klib.isV6 clusterCidr)
          "kubenyx.harness: clusterCidr and serviceCidr must be set together and share one family (kubenyx is single-stack)";
        members;

      mkNodeModule =
        name: m:
        {
          config,
          lib,
          options,
          nodes ? { },
          ...
        }:
        let
          # Driver-assigned primary addresses are the default; explicit
          # member addresses win. Outside the test driver `nodes` is
          # empty and explicit addresses are required (kubenyx's own
          # multi-node assertion reports omissions).
          resolveAddress =
            n: spec:
            if (spec.address or null) != null then
              spec.address
            else if nodes ? ${n} then
              (if v6 then nodes.${n}.networking.primaryIPv6Address else nodes.${n}.networking.primaryIPAddress)
            else
              null;
          resolvedNodes = lib.mapAttrs (n: spec: {
            index = spec.index;
            role = roleOf spec;
            address = resolveAddress n spec;
          }) checkedMembers;
        in
        {
          imports = [ ../modules ] ++ extraModules ++ lib.optional (m ? module) m.module;

          config = lib.mkMerge [
            {
              kubenyx = lib.mkMerge [
                {
                  enable = true;
                  # Pinned to the member attr name so the surrounding
                  # harness's hostname conventions cannot desync
                  # membership.
                  nodeName = name;
                  nodes = resolvedNodes;
                }
                (lib.optionalAttrs (roleOf m != "server") {
                  role = "agent";
                  # Bare v6 literal on purpose: klib.hostPort owns the
                  # brackets when kubeconfigs are rendered.
                  controlPlaneEndpoint = resolvedNodes.${primaryServer}.address;
                })
                (lib.optionalAttrs (clusterCidr != null) { network = { inherit clusterCidr; }; })
                (lib.optionalAttrs (serviceCidr != null) { network = { inherit serviceCidr; }; })
                (lib.optionalAttrs externalCni { network.cni = "external"; })
                (lib.optionalAttrs cniReplacesServicePlane { network.kubeProxy.enable = false; })
                # Test-oriented soft defaults — consumers always win.
                {
                  # Airgapped by default: driver VMs have no upstream, and
                  # forwarding against an empty resolv.conf turns every
                  # out-of-zone miss into a timeout instead of a fast
                  # NXDOMAIN.
                  dns.upstream = lib.mkDefault [ ];
                }
                (lib.optionalAttrs v6 {
                  # The module default is v4 link-local — unreachable from
                  # v6-only pods. Same ULA convention as the ipv6 legs;
                  # deliberately outside typical service CIDRs (see
                  # tests/ipv6.nix for why it must stay off the service
                  # dataplane).
                  dns.address = lib.mkDefault "fd44::a";
                })
                defaults
              ];
            }
            # House-convention driver sizing, only where the qemu-vm
            # options exist — the same modules must still eval outside
            # the test driver (microVM hosts size themselves).
            (lib.optionalAttrs (options ? virtualisation.memorySize) {
              virtualisation = {
                memorySize = lib.mkDefault 4096;
                cores = lib.mkDefault 4;
                diskSize = lib.mkDefault 8192;
              };
            })
            # Kubenyx must work with the firewall on; keep the tests
            # honest by default.
            { networking.firewall.enable = lib.mkDefault true; }
          ];
        };

      driverDefs = ''
        # ── kubenyx.harness driver helpers (air/v0.6/harness.org) ────────
        def kubenyx_kubectl(node, args, ns="default"):
            """kubectl through the node-local admin kubeconfig (kubenyx
            preconfigures KUBECONFIG for root on servers)."""
            return node.succeed(f"kubectl -n {ns} {args}")

        def kubenyx_wait_apiserver(server):
            server.wait_for_unit("kube-apiserver.service", timeout=1800)
            server.wait_for_file(
                "/var/lib/kubenyx/kubeconfigs/admin.kubeconfig", timeout=300
            )

        def kubenyx_ship_agent_credentials(server, agent, name):
            """Driver-mediated operator channel: tar the server-minted
            per-node credential dir into the agent. Never a shared 9p
            dir — the guest kernel caches the negative dentry and stays
            blind to the server's write (see tests/multi-node.nix)."""
            server.wait_until_succeeds(
                f"test -s /var/lib/kubenyx/pki/nodes/{name}/kubelet.crt",
                timeout=300,
            )
            blob = server.succeed(
                f"tar c -C /var/lib/kubenyx/pki/nodes {name} | base64 -w0"
            ).strip()
            agent.succeed(
                f"echo '{blob}' | base64 -d | tar x -C /tmp"
                f" && mkdir -p /var/lib/kubenyx/pki"
                f" && cp /tmp/{name}/* /var/lib/kubenyx/pki/"
            )
            # The path unit also catches the arrival; an explicit start
            # is deterministic.
            agent.succeed("systemctl restart kubenyx-pki.service")
            agent.wait_until_succeeds(
                "test -s /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig",
                timeout=300,
            )

        def kubenyx_wait_seeded(node):
            """Boot-time image seeding settled. Passes immediately when
            the seed unit does not exist (prebaked store mode)."""
            node.wait_until_succeeds(
                "! systemctl cat kubenyx-seed-images.service >/dev/null 2>&1"
                " || systemctl is-active kubenyx-seed-images.service",
                timeout=600,
            )

        def kubenyx_wait_node(server, name, ready=True):
            """Node registered; ready=True additionally waits for the
            Ready condition (leave False when an external CNI owns
            readiness and has not been deployed yet)."""
            server.wait_until_succeeds(f"kubectl get node {name}", timeout=1800)
            if ready:
                server.wait_until_succeeds(
                    f"kubectl get node {name} -o jsonpath="
                    "'{.status.conditions[?(@.type==\"Ready\")].status}'"
                    " | grep -q True",
                    timeout=1800,
                )

        def kubenyx_wait_workloads_admittable(server):
            """Pod admission needs the default ServiceAccount, created
            async by kcm."""
            server.wait_until_succeeds(
                "kubectl -n default get serviceaccount default", timeout=600
            )
      '';

      serverVar = pyVar primaryServer;

      waitReady =
        if lib.length serverNames != 1 then
          throw ''
            kubenyx.harness: the generated waitReady covers single-server
            clusters; multi-server bring-up requires the operator CA
            custody ceremony (offline mint + per-server ship — see
            tests/multi-server.nix). Use driverDefs and write the
            ceremony explicitly.''
        else
          driverDefs
          + ''

            # ── kubenyx bring-up (generated from the members attrset) ────────
            kubenyx_wait_apiserver(${serverVar})
          ''
          + lib.concatMapStrings (a: ''
            kubenyx_ship_agent_credentials(${serverVar}, ${pyVar a}, "${a}")
          '') agentNames
          + lib.concatMapStrings (n: ''
            kubenyx_wait_seeded(${pyVar n})
          '') memberNames
          + lib.concatMapStrings (n: ''
            kubenyx_wait_node(${serverVar}, "${n}", ready=${if externalCni then "False" else "True"})
          '') memberNames
          + lib.optionalString externalCni ''
            # externalCni: Ready arrives only after the consumer deploys
            # its CNI — gate on registration here, Ready is the
            # consumer's milestone.
          ''
          + ''
            kubenyx_wait_workloads_admittable(${serverVar})
          '';
    in
    {
      nodes = lib.mapAttrs mkNodeModule checkedMembers;
      inherit
        driverDefs
        waitReady
        serverVar
        pyVar
        primaryServer
        ;
    };
}
