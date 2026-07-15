# Test-harness embedding (air/v0.1/harness/harness.org): one members attrset in,
# everything a NixOS VM test needs to host a kubenyx cluster out — the
# per-node modules (roles, addresses incl. v6, external-CNI toggle) and
# the driver-side Python (credential ship, readiness gates, kubectl
# wrapper). Reachable as flake `lib.harness` AND as a plain
#   import <kubenyx>/lib/harness.nix { inherit lib; }
# — no flakes required; the module tree is referenced by relative path.
#
# phase 8 (air/v0.1/snapshot/test-amplification.org D1) adds opt-in snapshot verbs:
# mkCluster { snapshotable = true; } wires the nodes for in-driver QEMU
# savevm/loadvm and folds kubenyx_snapshot_all / kubenyx_restore_all /
# kubenyx_fresh_subtest into driverDefs. Reset-to-pristine costs
# SECONDS (loadvm loads guest RAM eagerly), not the milliseconds of the
# microVM snapshot path — it amortizes bring-up across subtests; it
# does not make resets free.
#
# phase 10 (air/v0.1/snapshot/ci-artifacts.org) splits the cut from the reuse:
# mkSnapshotMint builds a MINT derivation (boot, waitReady, savevm, quit,
# package the per-node qcow2s zstd + identity manifest into $out) and
# mkRestoreTest builds a CONSUMER test that takes the mint output as a
# derivation input, verifies identity exact-string, and adopts the
# restored guests without ever running one cold-boot instruction. Both
# require cpuModel (pinned guest CPUID — artifacts must not be
# host-generation-locked) and mintable = true (store image lifted into
# its own derivation so mint and consumer share it by store path).
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
      # In-driver QEMU snapshot support (air/v0.1/snapshot/test-amplification.org
      # D1): savevm refuses VMs whose store rides 9p (un-snapshottable
      # backend), so this flips the nodes onto useNixStoreImage with
      # readonly=on on the store drive (readonly drives are exempt from
      # the snapshot set; the driver's qcow2 root disk carries the
      # vmstate), and folds the snapshot verbs into driverDefs. The
      # snapshot point policy is fixed, not configurable: cut AFTER
      # generic bring-up (waitReady complete), BEFORE any per-test
      # mutation. Default off — at `false` every generated node and
      # Python string is byte-identical to the pre-phase-8 output.
      snapshotable ? false,
      # Cross-derivation snapshot artifacts (ci-artifacts.org): implies
      # the snapshotable wiring, but lifts the store image out of the
      # per-boot tar|mkfs.erofs into its own derivation and points the
      # (readonly) store drive at it. Mint and consumer then reference
      # the SAME store path on their qemu command lines — byte-identity
      # of the erofs the frozen guest page cache indexes into holds BY
      # CONSTRUCTION, and the per-boot mkfs.erofs cost disappears.
      # Requires cpuModel: qemu never validates the readonly drive or
      # the CPUID surface on loadvm, so both must be pinned, not lucky.
      mintable ? false,
      # Pinned guest CPU model, rendered as `-cpu <model>,enforce` AFTER
      # the qemu-common baked `-cpu max` (last -cpu wins — verified on
      # the pinned qemu). `enforce` turns fleet heterogeneity into loud
      # spawn-time refusals instead of silent CPUID divergence. null =
      # today's behavior: every generated drv stays byte-identical.
      cpuModel ? null,
    }:
    let
      v6 = clusterCidr != null && klib.isV6 clusterCidr;
      # mintable is snapshotable plus the derivation-built store image.
      snapWiring = snapshotable || mintable;

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
        assert lib.assertMsg (mintable -> cpuModel != null) ''
          kubenyx.harness: mintable requires cpuModel — snapshot artifacts
          that cross derivations (and eventually hosts) must pin the guest
          CPUID surface; `-cpu max` freezes the mint host's generation into
          the vmstate and qemu does not fully validate it on loadvm.'';
        members;

      mkNodeModule =
        name: m:
        {
          config,
          lib,
          options,
          pkgs,
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
            # Pinned CPU model (ci-artifacts.org §1): rendered by
            # qemu-vm.nix AFTER its baked `-cpu max`; the last -cpu wins
            # (verified empirically on the pinned qemu — a bogus model
            # BEFORE a valid one is ignored, after it refuses). enforce
            # makes a host that cannot satisfy the model refuse to spawn
            # instead of silently filtering CPUID bits.
            (lib.optionalAttrs (cpuModel != null && options ? virtualisation.qemu) {
              virtualisation.qemu.options = [ "-cpu ${cpuModel},enforce" ];
            })
            # Snapshotable wiring (D1): savevm demands every writable
            # block device be snapshot-capable. The store comes off 9p
            # onto a raw erofs drive marked readonly=on — readonly
            # drives are exempt — and the vmstate lands in the qcow2
            # root disk. Guarded like the sizing block: only where the
            # qemu-vm options exist.
            #
            # mintable (ci-artifacts.org §2) keeps the same drive shape
            # but builds the erofs ONCE, in its own derivation, instead
            # of at every VM start: the guest's frozen page cache holds
            # erofs block addresses, and qemu excludes readonly drives
            # from the loadvm validation set — a divergent store image
            # is silent corruption, not an error. Sharing one store path
            # between mint and consumer makes divergence inexpressible.
            (lib.optionalAttrs (snapWiring && options ? virtualisation.useNixStoreImage) (
              let
                # Byte-for-byte the runtime recipe from nixpkgs
                # qemu-vm.nix (tar|mkfs.erofs, fixed UUID/label, -T 0)
                # lifted to build time. regInfo replicates qemu-vm's own
                # closureInfo over additionalPaths so the regInfo=...
                # kernel-cmdline path resolves inside this image (the
                # mint testScript asserts it does).
                regInfo = pkgs.closureInfo { rootPaths = config.virtualisation.additionalPaths; };
                storeImage =
                  pkgs.runCommand "kubenyx-store-image"
                    {
                      nativeBuildInputs = [
                        pkgs.gnutar
                        pkgs.erofs-utils
                      ];
                      closureInfo = pkgs.closureInfo {
                        rootPaths = [
                          config.system.build.toplevel
                          regInfo
                        ];
                      };
                    }
                    ''
                      mkdir -p $out
                      tar --create \
                        --absolute-names \
                        --verbatim-files-from \
                        --transform 'flags=rSh;s|/nix/store/||' \
                        --transform 'flags=rSh;s|~nix~case~hack~[[:digit:]]\+||g' \
                        --files-from $closureInfo/store-paths \
                        | mkfs.erofs \
                          --quiet \
                          --force-uid=0 \
                          --force-gid=0 \
                          -L nix-store \
                          -U eb176051-bd15-49b7-9e6b-462e0b467019 \
                          -T 0 \
                          --hard-dereference \
                          --tar=f \
                          $out/store.img
                    '';
              in
              {
                virtualisation = lib.mkMerge [
                  (
                    if mintable then
                      {
                        # useNixStoreImage stays OFF: its only jobs are the
                        # per-boot image build (replaced by ${storeImage})
                        # and the mounts, replicated verbatim below.
                        mountHostNixStore = false;
                        fileSystems."/nix/.ro-store" = {
                          device = "/dev/disk/by-label/nix-store";
                          fsType = "erofs";
                          neededForBoot = true;
                          options = [ "ro" ];
                        };
                        fileSystems."/nix/store" = {
                          device = "/nix/.ro-store";
                          fsType = "none";
                          options = [ "bind" ];
                        };
                      }
                    else
                      { useNixStoreImage = true; }
                  )
                  {
                    # qemu-vm.nix renders `virtualisation.qemu.drives` as a
                    # plain list — no per-entry merge — so readonly=on can
                    # only reach the store drive by forcing the whole list.
                    # Mirrors the stock root + nix-store entries (nixpkgs
                    # nixos/modules/virtualisation/qemu-vm.nix) byte-for-byte
                    # in rendered flags, plus the one readonly.
                    qemu.drives = lib.mkForce [
                      {
                        name = "root";
                        file = ''"$NIX_DISK_IMAGE"'';
                        driveExtraOpts = {
                          cache = "writeback";
                          werror = "report";
                        };
                        deviceExtraOpts = {
                          bootindex = "1";
                          serial = "root";
                        };
                      }
                      {
                        name = "nix-store";
                        file = if mintable then "${storeImage}/store.img" else ''"$TMPDIR"/store.img'';
                        driveExtraOpts = {
                          format = "raw";
                          readonly = "on";
                        };
                        deviceExtraOpts.bootindex = "2";
                      }
                    ];
                  }
                ];
                assertions = [
                  {
                    assertion = config.virtualisation.emptyDiskImages == [ ];
                    message = ''
                      kubenyx.harness: snapshotable forces the qemu drive list (the
                      store drive must carry readonly=on for savevm), which would
                      silently drop virtualisation.emptyDiskImages entries. Extend
                      the forced list in lib/harness.nix or disable snapshotable.'';
                  }
                  {
                    assertion = config.virtualisation.diskImage != null;
                    message = ''
                      kubenyx.harness: snapshotable needs the driver's qcow2 root
                      disk — savevm writes the VM state there. diskImage = null
                      leaves no snapshot-capable device.'';
                  }
                ];
              }
            ))
          ];
        };

      # Snapshot verbs (air/v0.1/snapshot/test-amplification.org D1), folded into
      # driverDefs when snapshotable and exported standalone as
      # snapshotDefs. Verified mechanics (2026-07-14): the driver's
      # backdoor shell SURVIVES loadvm (restore is in-process, no channel
      # re-establishment); measured 4-5 s savevm / 7.4 s loadvm for a 3 G
      # VM — a seconds-class verb, never to be conflated with the
      # milliseconds-class microVM recreation path. The per-node walls
      # run CONCURRENTLY across nodes (independent monitor sockets), so
      # a cut or restore costs ~the slowest node regardless of cluster
      # width; the stop-all/cont-all barriers around them stay serial.
      #
      # Resumed-state tolerance rule for consumers: wait-for-condition
      # gates (the style waitReady generates) survive a restore; "assert
      # event observed since boot" style does not. Subtests cheaper than
      # one restore should not use these verbs at all.
      snapshotPython = ''
        # ── kubenyx.harness snapshot verbs (air/v0.1/snapshot/test-amplification.org) ──
        import time as _kubenyx_time
        import contextlib as _kubenyx_contextlib
        import threading as _kubenyx_threading
        import concurrent.futures as _kubenyx_futures

        # The driver's log machinery is shared across machines and not
        # promised thread-safe; every log emitted from a worker thread
        # goes through this lock. Monitor sockets need no lock — each
        # machine's socket is touched only by that machine's own worker.
        _kubenyx_log_lock = _kubenyx_threading.Lock()

        def _kubenyx_monitor(machine, cmd):
            out = machine.send_monitor_command(cmd)
            lowered = out.lower()
            # HMP reports failure as prose, not a status code; savevm's
            # classic refusals ("is writable but does not support
            # snapshots", "Error: ...", "Device ... not found") must not
            # scroll past silently. Keep snapshot tags free of these words.
            for needle in ("error", "failed", "does not support", "not found"):
                if needle in lowered:
                    raise Exception(
                        f"kubenyx.harness: monitor command {cmd!r} on "
                        f"{machine.name} failed: {out}"
                    )
            return out

        def _kubenyx_monitor_parallel(ms, verb, tag):
            """Issue `<verb> <tag>` on every machine concurrently: each
            VM's monitor socket is independent, so the per-node savevm/
            loadvm walls overlap and the multi-VM cut costs ~max(node)
            instead of sum(nodes). The stop-all before and cont-all
            after (in the callers) stay serial — they are the barriers
            that make the cut consistent, and this helper never runs
            outside them. Thread rule: a machine's send_monitor_command
            is called only from that machine's own worker thread; the
            shared logger is serialized via _kubenyx_log_lock."""
            def one(m):
                t0 = _kubenyx_time.monotonic()
                _kubenyx_monitor(m, f"{verb} {tag}")
                dt = _kubenyx_time.monotonic() - t0
                with _kubenyx_log_lock:
                    m.log(f"kubenyx: {verb} '{tag}' took {dt:.2f}s")

            t0 = _kubenyx_time.monotonic()
            with _kubenyx_futures.ThreadPoolExecutor(
                max_workers=len(ms), thread_name_prefix=f"kubenyx-{verb}"
            ) as pool:
                # list() before result(): submit them all, then reap —
                # result() re-raises the worker's _kubenyx_monitor
                # exception in the driver thread, failing the test.
                for f in [pool.submit(one, m) for m in ms]:
                    f.result()
            ms[0].log(
                f"kubenyx: parallel {verb} '{tag}' across {len(ms)} node(s) "
                f"took {_kubenyx_time.monotonic() - t0:.2f}s"
            )

        def kubenyx_snapshot_all(tag="pristine", nodes=None):
            """Consistent multi-VM cut: stop all, savevm ALL CONCURRENTLY
            (each monitor socket is independent; cut wall ≈ slowest node,
            not the sum), cont all — monotonic clocks freeze together, so
            guests never observe the pause. Detaches the driver's 9p
            shares first: virtio-9p attach
            installs a QEMU migration blocker and savevm is migration to
            disk; unmounting clunks the fids and lifts it. Policy: call
            AFTER generic bring-up (waitReady), BEFORE any mutation."""
            # machines_qemu, not machines: the driver types the latter
            # list[BaseMachine], and send_monitor_command exists only on
            # QemuMachine (savevm is a QEMU-only verb anyway).
            ms = machines_qemu if nodes is None else nodes
            for m in ms:
                m.succeed(
                    "for d in /tmp/shared /tmp/xchg /etc/ssl/certs; do "
                    "if mountpoint -q $d; then umount $d; fi; done"
                )
            for m in ms:
                m.send_monitor_command("stop")
            _kubenyx_monitor_parallel(ms, "savevm", tag)
            for m in ms:
                m.send_monitor_command("cont")

        def kubenyx_restore_all(tag="pristine", nodes=None):
            """Rewind every VM to `tag`: stop all, loadvm ALL CONCURRENTLY
            (restore wall ≈ slowest node, not the sum), cont all, then
            hwclock --hctosys in every guest over the surviving
            backdoor shell (guest time froze at the snapshot; the emulated
            RTC kept tracking host time). Seconds-class: loadvm loads
            guest RAM eagerly."""
            ms = machines_qemu if nodes is None else nodes
            for m in ms:
                m.send_monitor_command("stop")
            _kubenyx_monitor_parallel(ms, "loadvm", tag)
            for m in ms:
                m.send_monitor_command("cont")
            for m in ms:
                m.succeed("hwclock --hctosys")

        @_kubenyx_contextlib.contextmanager
        def kubenyx_fresh_subtest(name, tag="pristine", nodes=None):
            """Subtest that starts from genuinely virgin state: restore
            the pristine snapshot, then run the body under subtest(name).
            A retried subtest restores again — retry-from-pristine instead
            of hoping cleanup was complete."""
            kubenyx_restore_all(tag, nodes)
            with subtest(name):
                yield
      '';

      driverDefs = ''
        # ── kubenyx.harness driver helpers (air/v0.1/harness/harness.org) ────────
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
      ''
      # Additive fold: at snapshotable = false the concatenation is the
      # identity, keeping driverDefs (and every existing consumer's
      # testScript, and with it the check drv) byte-identical.
      + lib.optionalString snapWiring snapshotPython;

      # The verbs standalone, for consumers that assemble their own
      # driver Python instead of using driverDefs/waitReady. Gated at
      # eval: without the snapshotable node wiring, savevm refuses the
      # store-over-9p backend at runtime — fail loud and early instead.
      snapshotDefs =
        if snapWiring then
          snapshotPython
        else
          throw ''
            kubenyx.harness: snapshotDefs requires mkCluster { snapshotable = true; } —
            without it the nix store rides 9p, which QEMU savevm refuses
            (un-snapshottable backend). snapshotable moves the store to a
            readonly raw drive and sizes the drive list for savevm.'';

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
        snapshotDefs
        waitReady
        serverVar
        pyVar
        primaryServer
        ;
    };

  # Identity manifest shared by mkSnapshotMint (written into $out) and
  # mkRestoreTest (regenerated from the consumer's OWN node eval and
  # compared exact-string before any qemu spawn). One line per node
  # carrying the run-vm script store path: that drv closes over the
  # qemu binary, the pinned -cpu line, the drive list (and with it the
  # derivation-built store image) and the kernel cmdline — equality of
  # these strings is equality of everything loadvm assumes and cannot
  # itself validate.
  mkSnapshotManifest =
    {
      tag,
      cpuModel,
      memberNames,
      getVm,
    }:
    ''
      kubenyx snapshot-mint manifest v1
      tag ${tag}
      cpu ${cpuModel},enforce
    ''
    + lib.concatMapStrings (n: "node ${n} ${getVm n}\n") memberNames;

  # The MINT derivation (ci-artifacts.org §2.2): boot a mintable
  # cluster through the test driver, cut the multi-node pristine
  # snapshot after waitReady, plant the post-cut honesty leak, quit the
  # VMMs, then package each node's self-contained qcow2 (the savevm
  # vmstate lives INSIDE it — the qcow2 is the whole artifact) zstd
  # into $out next to the identity manifest. State dirs survive the
  # driver's exit by construction (cleanup only happens at a LATER
  # driver's machine init), so the packaging step is a plain copy.
  mkSnapshotMint =
    {
      pkgs,
      name ? "kubenyx-snapshot-mint",
      # Everything mkCluster takes EXCEPT the snapshot/identity knobs,
      # which this helper owns so mint and consumer cannot diverge.
      clusterArgs,
      # Required: the artifact crosses derivations, so the guest CPUID
      # surface must be pinned (see the mkCluster mintable assertion).
      cpuModel,
      tag ? "pristine",
      zstdLevel ? 3,
    }:
    assert lib.assertMsg
      (!(clusterArgs ? snapshotable) && !(clusterArgs ? mintable) && !(clusterArgs ? cpuModel))
      ''
        kubenyx.harness: mkSnapshotMint owns snapshotable/mintable/cpuModel —
        pass cpuModel to mkSnapshotMint itself and leave the rest out of
        clusterArgs (the consumer must reconstruct the exact same cluster).'';
    let
      cluster = mkCluster (
        clusterArgs
        // {
          mintable = true;
          inherit cpuModel;
        }
      );
      memberNames = lib.attrNames clusterArgs.members;

      mintTest = pkgs.testers.runNixOSTest {
        name = "${name}-driver";
        nodes = cluster.nodes;
        testScript = ''
          start_all()

          ${cluster.waitReady}

          # Store-image identity smoke: the regInfo path burned into the
          # kernel cmdline must resolve inside the derivation-built
          # erofs (it replicates qemu-vm.nix's own closureInfo — a
          # drift here would strand the guest nix db, silently).
          for m in machines_qemu:
              m.succeed(
                  "grep -o 'regInfo=[^ ]*' /proc/cmdline"
                  " | cut -d= -f2- | xargs test -e"
              )

          # Provenance marker, deliberately BEFORE the cut (the one
          # documented exception to cut-before-any-mutation): a genuine
          # restore MUST carry it — a consumer that cold-boots and
          # merely answers TLS would not.
          kubenyx_kubectl(${cluster.serverVar}, "create configmap mint-provenance --from-literal=mint=${name}")
          ${cluster.serverVar}.wait_until_succeeds(
              "kubectl -n default get configmap mint-provenance", timeout=300
          )

          kubenyx_snapshot_all("${tag}")

          # Post-cut honesty leak: lands in the ACTIVE qcow2 layer only,
          # never in the snapshot. A consumer that boots the shipped
          # disk instead of loadvm-ing the tag WILL see it; the restore
          # leg asserts it is gone.
          kubenyx_kubectl(${cluster.serverVar}, "create configmap mint-leak --from-literal=made=after-cut")
          ${cluster.serverVar}.wait_until_succeeds(
              "kubectl -n default get configmap mint-leak", timeout=300
          )

          # Monitor quit per machine: qemu flushes and closes the qcow2
          # cleanly (bdrv close), leaving a consistent image whose
          # active layer we never boot.
          for m in machines_qemu:
              m.crash()
        '';
      };

      manifest = pkgs.writeText "${name}-manifest" (mkSnapshotManifest {
        inherit tag cpuModel memberNames;
        getVm = n: "${mintTest.nodes.${n}.system.build.vm}";
      });
    in
    pkgs.runCommand name
      {
        requiredSystemFeatures = [
          "kvm"
          "nixos-test"
        ];
        nativeBuildInputs = [ pkgs.zstd ];
        passthru = {
          inherit
            clusterArgs
            cpuModel
            tag
            mintTest
            manifest
            ;
        };
      }
      ''
        mkdir -p $out driver-out

        # Pin the driver's state-dir root: driver.py prefers
        # XDG_RUNTIME_DIR over TMPDIR when picking tmp_dir, and the
        # packaging step below must find vm-state-* where the driver
        # put them.
        export XDG_RUNTIME_DIR="$TMPDIR"
        export LOGFILE=/dev/null
        export QEMU_AUDIO_DRV=none

        ${mintTest.driver}/bin/nixos-test-driver -o "$PWD/driver-out"

        cp ${manifest} $out/manifest
        : > $out/sizes
        ${lib.concatMapStrings (n: ''
          src="$TMPDIR/vm-state-${n}/${n}.qcow2"
          if ! test -s "$src"; then
            echo "kubenyx mint: expected snapshot-bearing qcow2 at $src" >&2
            exit 1
          fi
          echo "${n} $(stat -c %s "$src")" >> $out/sizes
          zstd -q -T"''${NIX_BUILD_CORES:-0}" -${toString zstdLevel} "$src" -o "$out/${n}.qcow2.zst"
        '') memberNames}
      '';

  # The CONSUMER test (ci-artifacts.org §2.3): takes a mkSnapshotMint
  # output as a DERIVATION INPUT, reconstructs the identical cluster
  # from the mint's own passthru (mint and consumer cannot diverge by
  # API shape), gates on the identity manifest before any qemu spawn,
  # then starts every node paused (-S: not one cold-boot instruction),
  # loadvm-s the tag concurrently, adopts the surviving backdoor
  # shells (the banner was printed exactly once, at the mint's real
  # boot — connect() would hang; drain + probe replaces it), fixes
  # guest clocks, health-gates, and only then runs the caller's
  # testScript.
  mkRestoreTest =
    {
      mint,
      name ? "kubenyx-snapshot-restore",
      testScript ? "",
    }:
    let
      inherit (mint) clusterArgs cpuModel tag;
      cluster = mkCluster (
        clusterArgs
        // {
          mintable = true;
          inherit cpuModel;
        }
      );
      memberNames = lib.attrNames clusterArgs.members;
      externalCni = clusterArgs.externalCni or false;
    in
    {
      inherit name;
      nodes = cluster.nodes;
      # Pure-python zstd so the driver needs nothing on PATH.
      extraPythonPackages = p: [ p.zstandard ];
      testScript =
        { nodes, ... }:
        cluster.driverDefs
        + ''

          # ── kubenyx mint restore (air/v0.1/snapshot/ci-artifacts.org) ──────
          import os as _kubenyx_os
          import zstandard as _kubenyx_zstd
          from pathlib import Path as _KubenyxPath

          _kubenyx_mint = "${mint}"

          # Identity gate — BEFORE any qemu spawn. Exact string equality
          # between the mint's recorded manifest and one regenerated
          # from THIS test's node eval: qemu validates neither the
          # readonly store drive nor the CPUID surface on loadvm, so
          # anything short of drv equality is silent-corruption bait.
          _kubenyx_expected_manifest = """${
            mkSnapshotManifest {
              inherit tag cpuModel memberNames;
              getVm = n: "${nodes.${n}.system.build.vm}";
            }
          }"""
          with open(_kubenyx_mint + "/manifest") as _f:
              _kubenyx_actual_manifest = _f.read()
          assert _kubenyx_actual_manifest == _kubenyx_expected_manifest, (
              "kubenyx.harness: mint/consumer identity mismatch — refusing to restore.\n"
              f"mint shipped:\n{_kubenyx_actual_manifest}\n"
              f"consumer expects:\n{_kubenyx_expected_manifest}"
          )

          _kubenyx_raw_bytes = {}
          with open(_kubenyx_mint + "/sizes") as _f:
              for _line in _f:
                  _n, _s = _line.split()
                  _kubenyx_raw_bytes[_n] = int(_s)

          def _kubenyx_seed(m):
              """Decompress the mint qcow2 into the machine's state dir —
              into /dev/shm (symlinked; startVM readlink -f follows) when
              it verifiably fits with headroom for post-restore guest
              writes, since loadvm is memory-bound and the image is the
              hottest file in the test."""
              m.state_dir.mkdir(mode=0o700, exist_ok=True)
              src = _kubenyx_mint + f"/{m.name}.qcow2.zst"
              dest = m.state_dir / f"{m.name}.qcow2"
              raw = _kubenyx_raw_bytes[m.name]
              target = dest
              try:
                  _st = _kubenyx_os.statvfs("/dev/shm")
                  if _st.f_frsize * _st.f_bavail > 2 * raw:
                      target = _KubenyxPath(f"/dev/shm/kubenyx-{_kubenyx_os.getpid()}-{m.name}.qcow2")
              except OSError:
                  pass
              with open(src, "rb") as _i, open(target, "wb") as _o:
                  _kubenyx_zstd.ZstdDecompressor().copy_stream(_i, _o)
              if target != dest:
                  if dest.is_symlink() or dest.exists():
                      dest.unlink()
                  dest.symlink_to(target)
              m.log(f"kubenyx: seeded {dest} from mint ({raw} raw bytes, via {target})")

          def _kubenyx_adopt(m):
              """The pristine cut happened mid-session on the backdoor
              shell: 'Spawning backdoor root shell...' was printed once,
              at the mint's real boot, and a restored guest never
              re-emits it — connect() would hang for its banner. Drain
              stale chardev bytes, bypass the banner wait, and let an
              echo probe be the ground truth."""
              assert m.shell
              m.shell.setblocking(False)
              _stale = b""
              try:
                  while True:
                      try:
                          _chunk = m.shell.recv(4096)
                      except BlockingIOError:
                          break
                      if not _chunk:
                          break
                      _stale += _chunk
              finally:
                  m.shell.setblocking(True)
              if _stale:
                  m.log(f"kubenyx: drained {len(_stale)} stale shell byte(s) before adopt")
              m.connected = True
              _status, _out = m.execute("echo kubenyx-adopt-ok")
              assert _status == 0 and _out.strip() == "kubenyx-adopt-ok", (
                  f"kubenyx.harness: adopted shell on {m.name} failed the probe:"
                  f" {_status} {_out!r}"
              )

          _kubenyx_restore_t0 = _kubenyx_time.monotonic()

          # -S: qemu spawns with vcpus paused — the seeded disk is
          # provably untouched until loadvm, and the guest never
          # executes a single cold-boot instruction. The driver's
          # start() works unchanged against a paused VMM (sockets and
          # monitor prompt are host-side).
          _kubenyx_os.environ["QEMU_OPTS"] = "-S"
          for m in machines_qemu:
              _kubenyx_seed(m)
          for m in machines_qemu:
              m.start()
          del _kubenyx_os.environ["QEMU_OPTS"]

          _kubenyx_monitor_parallel(machines_qemu, "loadvm", "${tag}")
          for m in machines_qemu:
              m.send_monitor_command("cont")
          for m in machines_qemu:
              _kubenyx_adopt(m)
          for m in machines_qemu:
              # Guest time froze at the cut; the emulated RTC kept
              # tracking host time.
              m.succeed("hwclock --hctosys")

          machines_qemu[0].log(
              "kubenyx: mint restore to running guests took "
              f"{_kubenyx_time.monotonic() - _kubenyx_restore_t0:.2f}s"
          )

          # ── health gate: wait-for-condition only (restore-safe) ──────────
          kubenyx_wait_apiserver(${cluster.serverVar})
        ''
        + lib.concatMapStrings (n: ''
          kubenyx_wait_node(${cluster.serverVar}, "${n}", ready=${if externalCni then "False" else "True"})
        '') memberNames
        + ''
          kubenyx_wait_workloads_admittable(${cluster.serverVar})
          machines_qemu[0].log(
              "kubenyx: restore-to-healthy took "
              f"{_kubenyx_time.monotonic() - _kubenyx_restore_t0:.2f}s"
          )

        ''
        + testScript;
    };
}
